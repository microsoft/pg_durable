-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Audio Round Trip — monitor progress
--
-- Re-run while the workflow is going. Each phrase takes roughly 20 seconds
-- because of the pacing sleep, so a three-phrase run takes about a minute.

SELECT
    id,
    left(phrase, 40) AS phrase,
    status,
    speech_status,
    speech_encoding,
    transcribe_status,
    left(coalesce(transcript, ''), 40) AS transcript,
    matched
FROM demo.audio_roundtrip
ORDER BY id;

-- Instance-level view.
SELECT
    id AS instance_id,
    label,
    status,
    created_at
FROM df.instances
WHERE label = 'audio-roundtrip'
ORDER BY created_at DESC
LIMIT 5;
