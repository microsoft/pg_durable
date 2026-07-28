-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Audio Round Trip — reset for another run
--
-- Clears results and puts every phrase back to pending. Does not touch
-- df.vars, so 02_set_vars.sql does not need re-running.

UPDATE demo.audio_roundtrip SET
    status            = 'pending',
    transcript        = NULL,
    matched           = NULL,
    speech_status     = NULL,
    speech_encoding   = NULL,
    transcribe_status = NULL,
    error             = NULL,
    updated_at        = NULL;

SELECT id, phrase, status FROM demo.audio_roundtrip ORDER BY id;
