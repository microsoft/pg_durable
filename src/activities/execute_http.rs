//! ExecuteHTTP activity - makes HTTP requests

use duroxide::ActivityContext;
use std::time::Duration;

use crate::types::HttpConfig;

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::execute-http";

/// Execute an HTTP request and return the response as JSON
pub async fn execute(ctx: ActivityContext, config_json: String) -> Result<String, String> {
    let config: HttpConfig =
        serde_json::from_str(&config_json).map_err(|e| format!("Invalid HTTP config: {e}"))?;

    let start = std::time::Instant::now();
    ctx.trace_info(format!("HTTP {} {}", config.method, config.url));

    // Build client with timeout
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(config.timeout_seconds))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {e}"))?;

    // Build request based on method
    let mut request = match config.method.as_str() {
        "GET" => client.get(&config.url),
        "POST" => client.post(&config.url),
        "PUT" => client.put(&config.url),
        "DELETE" => client.delete(&config.url),
        "PATCH" => client.patch(&config.url),
        _ => return Err(format!("Unsupported HTTP method: {}", config.method)),
    };

    // Add headers
    if let Some(headers) = &config.headers {
        if let Some(obj) = headers.as_object() {
            for (key, value) in obj {
                if let Some(v) = value.as_str() {
                    request = request.header(key, v);
                }
            }
        }
    }

    // Add body (for POST/PUT/PATCH)
    if let Some(body) = &config.body {
        request = request.body(body.clone());
    }

    // Execute request
    let response = request.send().await.map_err(|e| {
        // Try to extract status code from error if available
        let status_info = e
            .status()
            .map(|s| format!(" (HTTP {})", s.as_u16()))
            .unwrap_or_default();

        if e.is_timeout() {
            format!(
                "HTTP timeout after {}s{}: {}",
                config.timeout_seconds, status_info, config.url
            )
        } else if e.is_connect() {
            format!(
                "HTTP connection failed{}: {} - {}",
                status_info, config.url, e
            )
        } else if e.is_status() {
            // Error due to HTTP status code
            format!("HTTP request failed{}: {} - {}", status_info, config.url, e)
        } else {
            format!("HTTP request failed{}: {} - {}", status_info, config.url, e)
        }
    })?;

    let status = response.status();
    let status_code = status.as_u16();

    // Collect response headers
    let response_headers: serde_json::Map<String, serde_json::Value> = response
        .headers()
        .iter()
        .filter_map(|(k, v)| {
            v.to_str()
                .ok()
                .map(|s| (k.to_string(), serde_json::Value::String(s.to_string())))
        })
        .collect();

    let response_body = response
        .text()
        .await
        .map_err(|e| format!("Failed to read response body: {e}"))?;

    let duration_ms = start.elapsed().as_millis() as u64;
    let is_ok = status.is_success();

    // Build response object
    let result = serde_json::json!({
        "status": status_code,
        "body": response_body,
        "headers": response_headers,
        "ok": is_ok,
        "duration_ms": duration_ms
    });

    ctx.trace_info(format!(
        "HTTP {} completed: status={}, ok={}, duration={}ms",
        config.method, status_code, is_ok, duration_ms
    ));

    // Fail on 5xx server errors (transient, should retry)
    if status.is_server_error() {
        return Err(format!(
            "HTTP {} {} returned {}: {}",
            config.method, config.url, status_code, response_body
        ));
    }

    // Return response for all other cases (including 4xx)
    // 4xx are client errors - user should handle in workflow logic
    Ok(result.to_string())
}
