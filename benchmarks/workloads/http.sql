SELECT df.start(
    df.http(':http_url', 'POST', repeat('x', :request_bytes),
            '{"Content-Type":"text/plain"}'::jsonb, :timeout_seconds),
    ':run_label'
) AS instance_id
\gset