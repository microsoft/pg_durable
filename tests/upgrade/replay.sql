SET search_path = public, df;
CREATE TABLE IF NOT EXISTS replay_cases (
    name text PRIMARY KEY,
    kind text NOT NULL,
    created_phase text NOT NULL,
    instance_id text NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS replay_marks (label text NOT NULL, value text NOT NULL);

INSERT INTO replay_cases VALUES (:'cohort' || '-live', 'live', :'cohort', df.start(
    df.loop(
        'INSERT INTO public.replay_marks VALUES (''{sys_label}'', ''iteration'') RETURNING value'
        ~> df.sleep(1)
    ),
    :'cohort' || '-live'
));

INSERT INTO replay_cases VALUES (:'cohort' || '-finite', 'finite', :'cohort', df.start(
    'INSERT INTO public.replay_marks VALUES (''{sys_label}'', ''done'') RETURNING value',
    :'cohort' || '-finite'
));