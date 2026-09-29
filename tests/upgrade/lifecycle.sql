-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

CREATE ROLE upgrade_lifecycle_user LOGIN;
SELECT df.grant_usage('upgrade_lifecycle_user');

CREATE TABLE public.upgrade_lifecycle_cases (
    name text PRIMARY KEY,
    instance_id text NOT NULL UNIQUE,
    waiting boolean NOT NULL
);
CREATE TABLE public.upgrade_lifecycle_marks (
    label text NOT NULL,
    step integer NOT NULL,
    value integer NOT NULL,
    executed_by text NOT NULL DEFAULT current_user,
    PRIMARY KEY (label, step)
);
GRANT SELECT, INSERT ON public.upgrade_lifecycle_cases, public.upgrade_lifecycle_marks
    TO upgrade_lifecycle_user;

CREATE FUNCTION public.upgrade_lifecycle_start(label text, waiting boolean)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    graph text;
    instance text;
BEGIN
    graph := df.as(
        'INSERT INTO public.upgrade_lifecycle_marks (label, step, value)
         VALUES (''{sys_label}'', 1, {lifecycle_seed}) RETURNING value', 'seed');
    IF waiting THEN
        graph := df.seq(graph, df.wait_for_signal('resume'));
    END IF;
    graph := df.seq(graph,
        'INSERT INTO public.upgrade_lifecycle_marks (label, step, value)
         VALUES (''{sys_label}'', 2, $seed::integer + {lifecycle_increment}) RETURNING value');
    instance := df.start(graph, label);
    INSERT INTO public.upgrade_lifecycle_cases VALUES (label, instance, waiting);
    RETURN instance;
END $$;
