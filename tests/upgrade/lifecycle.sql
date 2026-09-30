-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

CREATE ROLE upgrade_lifecycle_user LOGIN;
SELECT df.grant_usage('upgrade_lifecycle_user');

CREATE TABLE public.upgrade_lifecycle_cases (
    name text PRIMARY KEY,
    instance_id text NOT NULL UNIQUE,
    shape text NOT NULL,
    waiting boolean NOT NULL
);
-- One row per marker execution. The (label, path, occurrence) key detects
-- missing, duplicate, or reordered side effects when old histories replay.
CREATE TABLE public.upgrade_lifecycle_marks (
    label text NOT NULL,
    path text NOT NULL,
    occurrence integer NOT NULL,
    value integer,
    executed_by text NOT NULL DEFAULT current_user,
    PRIMARY KEY (label, path, occurrence)
);
GRANT SELECT, INSERT ON public.upgrade_lifecycle_cases, public.upgrade_lifecycle_marks
    TO upgrade_lifecycle_user;

-- Records one marker row for (label, path), assigning the next occurrence for
-- that pair, and returns the supplied value. Executes only when the worker
-- reaches the corresponding SQL node, never during graph construction or replay.
CREATE FUNCTION public.upgrade_lifecycle_mark(p_label text, p_path text,
                                              p_value integer DEFAULT NULL)
RETURNS integer
LANGUAGE sql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
    INSERT INTO public.upgrade_lifecycle_marks (label, path, occurrence, value)
    SELECT p_label, p_path,
           coalesce(max(occurrence), 0) + 1, p_value
    FROM public.upgrade_lifecycle_marks
    WHERE label = p_label AND path = p_path
    RETURNING value;
$$;
GRANT EXECUTE ON FUNCTION public.upgrade_lifecycle_mark(text, text, integer)
    TO upgrade_lifecycle_user;

-- Construction-time helper: renders a marker SQL node at a structural path,
-- optionally recording an integer expression. The expression is inserted raw so
-- DSL substitution tokens (e.g. {lifecycle_seed}, $seed) survive to runtime.
CREATE FUNCTION public.upgrade_lifecycle_mark_sql(p_label text, p_path text,
                                                  p_value_expr text DEFAULT NULL)
RETURNS text LANGUAGE sql AS $$
    SELECT CASE WHEN p_value_expr IS NULL
        THEN format('SELECT public.upgrade_lifecycle_mark(%L, %L) AS value', p_label, p_path)
        ELSE format('SELECT public.upgrade_lifecycle_mark(%L, %L, %s) AS value',
                    p_label, p_path, p_value_expr)
    END;
$$;

-- Construction-time helper: renders a boolean condition SQL that compares the
-- number of recorded markers at a path against a predicate fragment.
CREATE FUNCTION public.upgrade_lifecycle_count_sql(p_label text, p_path text, p_pred text)
RETURNS text LANGUAGE sql AS $$
    SELECT format('SELECT COUNT(*) %s FROM public.upgrade_lifecycle_marks'
                  ' WHERE label = %L AND path = %L', p_pred, p_label, p_path);
$$;

-- Builds a durable graph for one behavior family and starts an instance.
--
-- Every waiting shape suspends on the 'resume' signal at a meaningful point
-- inside its structure, so resuming forces the new binary to replay the
-- pre-suspension history. The seq shape additionally captures a variable before
-- suspension and must reuse it afterward, even though the live variable changed.
CREATE FUNCTION public.upgrade_lifecycle_start(label text, shape text, waiting boolean)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    gate text := df.wait_for_signal('resume');
    graph text;
    instance text;
BEGIN
    CASE shape
        WHEN 'seq' THEN
            -- seed -> [wait] -> continuation reusing the captured seed.
            graph := df.as(
                public.upgrade_lifecycle_mark_sql(label, 'r.0', '{lifecycle_seed}'), 'seed');
            IF waiting THEN
                graph := df.seq(graph, gate);
            END IF;
            graph := df.seq(graph, public.upgrade_lifecycle_mark_sql(
                label, 'r.1', '$seed::integer + {lifecycle_increment}'));

        WHEN 'if-then' THEN
            -- Then branch suspends mid-branch; the else branch must stay unrun.
            graph := df.if('SELECT true',
                df.seq(df.seq(public.upgrade_lifecycle_mark_sql(label, 'r.t.0'), gate),
                       public.upgrade_lifecycle_mark_sql(label, 'r.t.1')),
                public.upgrade_lifecycle_mark_sql(label, 'r.e'));

        WHEN 'if-else' THEN
            -- Else branch suspends mid-branch; the then branch must stay unrun.
            graph := df.if('SELECT false',
                public.upgrade_lifecycle_mark_sql(label, 'r.t'),
                df.seq(df.seq(public.upgrade_lifecycle_mark_sql(label, 'r.e.0'), gate),
                       public.upgrade_lifecycle_mark_sql(label, 'r.e.1')));

        WHEN 'loop' THEN
            -- Suspend during the first iteration; later iterations run on resume.
            -- The body marks r.b, waits only on the first pass, then marks the
            -- counter r.c. The condition loops while r.c has an odd count.
            graph := df.loop(
                df.seq(
                    df.seq(public.upgrade_lifecycle_mark_sql(label, 'r.b'),
                        df.if(public.upgrade_lifecycle_count_sql(label, 'r.c', '= 0'),
                              gate, 'SELECT 1')),
                    public.upgrade_lifecycle_mark_sql(label, 'r.c')),
                public.upgrade_lifecycle_count_sql(label, 'r.c', '% 2 <> 0'));

        WHEN 'break' THEN
            -- Suspend on the first iteration, then loop until the break fires on
            -- the third marker. The pre-suspension marker must not be replayed.
            graph := df.loop(
                df.seq(
                    df.seq(public.upgrade_lifecycle_mark_sql(label, 'r.0'),
                        df.if(public.upgrade_lifecycle_count_sql(label, 'r.0', '= 1'),
                              gate, 'SELECT 1')),
                    df.if(public.upgrade_lifecycle_count_sql(label, 'r.0', '% 3 = 0'),
                          df.break(), 'SELECT 1')),
                'SELECT true');

        WHEN 'join' THEN
            -- One branch completes immediately; the other suspends. Resuming must
            -- not re-run the already-completed branch.
            graph := df.join(
                df.seq(df.seq(public.upgrade_lifecycle_mark_sql(label, 'r.0'), gate),
                       public.upgrade_lifecycle_mark_sql(label, 'r.1')),
                public.upgrade_lifecycle_mark_sql(label, 'r.b'));

        WHEN 'race' THEN
            -- The winner suspends on the signal while the loser holds a long
            -- timer. Resuming the winner cancels the loser, which never marks.
            graph := df.race(
                df.seq(df.seq(public.upgrade_lifecycle_mark_sql(label, 'r.w'), gate),
                       public.upgrade_lifecycle_mark_sql(label, 'r.w2')),
                df.seq(df.sleep(3600), public.upgrade_lifecycle_mark_sql(label, 'r.l')));

        ELSE
            RAISE EXCEPTION 'Unknown lifecycle shape: %', shape;
    END CASE;

    instance := df.start(graph, label);
    INSERT INTO public.upgrade_lifecycle_cases VALUES (label, instance, shape, waiting);
    RETURN instance;
END $$;
