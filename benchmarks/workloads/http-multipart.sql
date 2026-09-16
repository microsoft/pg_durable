SELECT df.start(
    df.http_multipart(':http_url', 'POST',
        jsonb_build_array(jsonb_build_object(
            'name', 'payload', 'filename', 'payload.txt', 'content_type', 'text/plain',
            'data_b64', replace(encode(convert_to(repeat('x', :request_bytes), 'UTF8'), 'base64'), chr(10), '')
        )), NULL, :timeout_seconds),
    ':run_label'
) AS instance_id
\gset