-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Audio Round Trip — verify the result
--
-- Run after the workflow reports completed. Raises an exception if the round
-- trip did not actually work, so this is usable as a check and not just a
-- report.

\echo '--- Per-phrase result ---'

SELECT
    id,
    phrase,
    status,
    transcript,
    matched,
    speech_encoding
FROM demo.audio_roundtrip
ORDER BY id;

\echo '--- Assertions ---'

DO $$
DECLARE
    total INT;
    transcribed INT;
    matched_count INT;
    binary_count INT;
    bad_row RECORD;
BEGIN
    SELECT count(*) INTO total FROM demo.audio_roundtrip;

    IF total = 0 THEN
        RAISE EXCEPTION 'Nothing to verify — run 03_seed_phrases.sql and 04_start_workflow.sql first';
    END IF;

    SELECT count(*) FILTER (WHERE status = 'transcribed'),
           count(*) FILTER (WHERE matched),
           count(*) FILTER (WHERE speech_encoding = 'base64')
      INTO transcribed, matched_count, binary_count
      FROM demo.audio_roundtrip;

    -- Every phrase should have completed the round trip.
    IF transcribed <> total THEN
        FOR bad_row IN
            SELECT id, status, speech_status, transcribe_status, error
              FROM demo.audio_roundtrip
             WHERE status <> 'transcribed'
             ORDER BY id
        LOOP
            RAISE WARNING 'phrase % is %, speech_status=%, transcribe_status=%, error=%',
                bad_row.id, bad_row.status, bad_row.speech_status,
                bad_row.transcribe_status, bad_row.error;
        END LOOP;
        RAISE EXCEPTION 'VERIFY FAILED: % of % phrases transcribed', transcribed, total;
    END IF;

    -- The audio must have travelled as binary. If this is 'text', the speech
    -- response was decoded as UTF-8 and the MP3 was silently corrupted — the
    -- exact failure this example exists to demonstrate is fixed.
    IF binary_count <> total THEN
        RAISE EXCEPTION 'VERIFY FAILED: % of % responses were captured as base64 (expected all)',
            binary_count, total;
    END IF;

    -- A non-empty transcript is the real proof that the MP3 survived the
    -- handoff. Corrupted bytes make Whisper reject the upload or return an
    -- empty string, so this is asserted rather than merely reported.
    IF EXISTS (
        SELECT 1 FROM demo.audio_roundtrip
         WHERE COALESCE(length(trim(transcript)), 0) = 0
    ) THEN
        FOR bad_row IN
            SELECT id, phrase, transcribe_status
              FROM demo.audio_roundtrip
             WHERE COALESCE(length(trim(transcript)), 0) = 0
             ORDER BY id
        LOOP
            RAISE WARNING 'phrase % produced no transcript (transcribe_status=%)',
                bad_row.id, bad_row.transcribe_status;
        END LOOP;
        RAISE EXCEPTION 'VERIFY FAILED: some phrases produced no transcript';
    END IF;

    -- Speech recognition is not deterministic. The same phrase has come back as
    -- both "HTTP steps" and "EP steps" across runs, so an imperfect match says
    -- something about the speech model, not about whether the payload survived
    -- the handoff. Report it; do not fail on it.
    IF matched_count <> total THEN
        FOR bad_row IN
            SELECT id, phrase, transcript
              FROM demo.audio_roundtrip
             WHERE matched IS DISTINCT FROM TRUE
             ORDER BY id
        LOOP
            RAISE WARNING 'phrase % transcribed loosely: sent "%", got "%"',
                bad_row.id, bad_row.phrase, bad_row.transcript;
        END LOOP;
        RAISE NOTICE 'VERIFY PASSED (with % of % exact matches): all % phrases made the binary round trip',
            matched_count, total, total;
    ELSE
        RAISE NOTICE 'VERIFY PASSED: % phrases spoken, transcribed and matched', total;
    END IF;
END $$;
