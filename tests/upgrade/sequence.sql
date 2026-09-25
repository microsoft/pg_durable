CREATE TABLE replay_sequences (
    name text PRIMARY KEY,
    instance_id text UNIQUE NOT NULL,
    owner_role text NOT NULL,
    created_phase text NOT NULL,
    allowed_step integer NOT NULL
);
CREATE TABLE replay_sequence_marks (
    label text NOT NULL,
    step integer NOT NULL,
    executed_by text NOT NULL,
    value integer NOT NULL,
    PRIMARY KEY (label, step)
);
GRANT SELECT ON replay_sequences TO replay_never_user, replay_managed_user;
GRANT SELECT, INSERT ON replay_sequence_marks TO replay_never_user, replay_managed_user;

CREATE FUNCTION replay_sequence_step(label text, step integer) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    previous_value integer;
    deadline timestamptz := clock_timestamp() + interval '5 minutes';
BEGIN
    WHILE NOT EXISTS (
        SELECT 1 FROM public.replay_sequences AS sequences
        WHERE sequences.name = label AND sequences.allowed_step >= step
    ) LOOP
        IF clock_timestamp() >= deadline THEN
            RAISE EXCEPTION 'sequence gate timed out: %, %', label, step;
        END IF;
        PERFORM pg_sleep(0.05);
    END LOOP;
    SELECT sum(marks.value) INTO previous_value FROM public.replay_sequence_marks AS marks
    WHERE marks.label = replay_sequence_step.label AND marks.step = replay_sequence_step.step - 1;
    IF step > 1 AND previous_value IS NULL THEN
        RAISE EXCEPTION 'out of order: %, %', label, step;
    END IF;
    INSERT INTO public.replay_sequence_marks VALUES (label, step, current_user, coalesce(previous_value, 0) + step);
    RETURN coalesce(previous_value, 0) + step;
END $$;