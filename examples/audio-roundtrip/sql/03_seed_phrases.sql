-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Seed the phrases that will be spoken and then transcribed back.
--
-- Kept short and few on purpose. Whisper on a Standard deployment is limited to
-- 3 requests per minute per subscription, and the workflow already paces itself
-- with df.sleep() — more phrases mostly means a longer wait, not a better demo.
--
-- Use plain prose. Speech models expand and reformat acronyms unpredictably:
-- an earlier version of this file said "between http steps" and got back both
-- "HTTP steps" and "EP steps" on different runs, which made the example look
-- broken when nothing was.

TRUNCATE TABLE demo.audio_roundtrip RESTART IDENTITY;

INSERT INTO demo.audio_roundtrip (phrase) VALUES
    ('pg durable makes workflows durable'),
    ('every step survives a restart'),
    ('binary payloads flow between steps');

SELECT id, phrase, status FROM demo.audio_roundtrip ORDER BY id;
