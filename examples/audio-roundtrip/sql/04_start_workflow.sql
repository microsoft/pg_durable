-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Audio Round Trip — start the workflow
--
-- Prerequisites:
--   1. Run 01_schema.sql     (create tables)
--   2. Run 02_set_vars.sql   (configure Azure OpenAI endpoint/key/deployments)
--   3. Run 03_seed_phrases.sql (insert phrases)
--
-- The workflow walks pending phrases one at a time and stops when none remain.
--
-- The point of this example is the single line marked BINARY HANDOFF below:
-- the MP3 produced by the speech call is handed directly to the transcription
-- upload. The audio never passes through a SQL node, so it is never copied into
-- a query string and never widened by SQL quoting.

SELECT df.start(

    df.loop(
        (
            -- Claim the next pending phrase.
            ($$SELECT id, phrase
                 FROM demo.audio_roundtrip
                WHERE status = 'pending'
                ORDER BY id
                LIMIT 1$$ |=> 'item')

            -- df.loop is do-while, so the body runs once even with nothing
            -- pending. if_rows makes that first pass a no-op instead of an
            -- error on $item.phrase.
            ~> df.if_rows('item',
                (
                    -- ── Text to speech ──
                    -- Azure returns audio/mpeg. pg_durable classifies that as
                    -- binary and base64-encodes it into the envelope body,
                    -- reporting encoding = 'base64'.
                    (df.http(
                        '{speech_url}',
                        'POST',
                        $${"model": "{tts_deployment}", "input": "$item.phrase", "voice": "alloy", "response_format": "mp3"}$$,
                        '{"api-key": "{api_key}", "Content-Type": "application/json"}'::jsonb,
                        60
                    ) |=> 'speech')

                    ~> df.if(
                        $$SELECT $speech.ok$$,

                        -- ── Speech to text ──
                        (
                            (df.http_multipart(
                                '{transcribe_url}',
                                'POST',
                                jsonb_build_array(
                                    jsonb_build_object(
                                        'name',         'file',
                                        'filename',     'speech.mp3',
                                        'content_type', 'audio/mpeg',
                                        -- BINARY HANDOFF: the base64 body of the
                                        -- speech response becomes the part payload
                                        -- verbatim. Whole-value reference only —
                                        -- splicing text around it is rejected.
                                        'data_b64',     '$speech.body'
                                    ),
                                    jsonb_build_object(
                                        'name',     'model',
                                        -- Every part is carried as base64, including
                                        -- short form fields like this one.
                                        'data_b64', encode(
                                            convert_to(df.getvar('whisper_deployment'), 'UTF8'),
                                            'base64')
                                    ),
                                    -- An optional vocabulary hint for Whisper.
                                    -- Included to show that a form can carry
                                    -- several text fields alongside the binary
                                    -- one, not just file + model.
                                    --
                                    -- It also exercises the decoder: this text
                                    -- is 75 bytes, and encode(..., 'base64')
                                    -- wraps anything over 57 bytes across
                                    -- multiple lines. Those newlines are
                                    -- stripped before decoding, so a wrapped
                                    -- part is accepted as-is.
                                    jsonb_build_object(
                                        'name',     'prompt',
                                        'data_b64', encode(convert_to(
                                            'A short recording about pg durable, durable workflows, and binary payloads.',
                                            'UTF8'), 'base64')
                                    )
                                ),
                                -- No Content-Type here: multipart owns the boundary.
                                '{"api-key": "{api_key}"}'::jsonb,
                                60
                            ) |=> 'transcript')

                            ~> $$UPDATE demo.audio_roundtrip SET
                                    status = CASE WHEN $transcript.ok
                                                  THEN 'transcribed' ELSE 'failed' END,
                                    speech_status     = $speech.status,
                                    speech_encoding   = $speech.encoding,
                                    transcribe_status = $transcript.status,
                                    transcript = CASE WHEN $transcript.ok
                                        THEN ($transcript.body)::jsonb->>'text' END,
                                    matched = CASE WHEN $transcript.ok
                                        THEN demo.audio_normalize(($transcript.body)::jsonb->>'text')
                                             = demo.audio_normalize(phrase) END,
                                    error = CASE WHEN $transcript.ok
                                        THEN NULL ELSE left(($transcript.body), 500) END,
                                    updated_at = now()
                                  WHERE id = $item.id$$
                        ),

                        -- ── Speech call failed ──
                        -- A 4xx (including 429 rate limiting) is returned as a
                        -- completed activity with ok = false, so it has to be
                        -- handled here or the run would look successful.
                        $$UPDATE demo.audio_roundtrip SET
                            status          = 'failed',
                            speech_status   = $speech.status,
                            speech_encoding = $speech.encoding,
                            error           = left(($speech.body), 500),
                            updated_at      = now()
                          WHERE id = $item.id$$
                    )

                    -- Whisper is capped at 3 requests per minute on a Standard
                    -- deployment. This is a durable timer, not a held connection:
                    -- the worker is free during the wait and the delay survives a
                    -- restart.
                    ~> df.sleep(20)
                ),

                $$SELECT 'no pending phrases' AS note$$
            )
        ),

        $$SELECT count(*) > 0 FROM demo.audio_roundtrip WHERE status = 'pending'$$
    ),

    'audio-roundtrip'
) AS instance_id;
