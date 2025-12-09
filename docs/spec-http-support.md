# Spec: HTTP Support for pg_durable

## Overview

Add `df.http()` as a new node type that makes HTTP requests as a durable activity. This automatically enables Azure Functions, webhooks, external APIs, and any HTTP service.

## DSL

### `df.http()` - Core HTTP Function

```sql
df.http(
    url TEXT,                              -- Required: endpoint URL
    method TEXT DEFAULT 'POST',            -- GET, POST, PUT, DELETE, PATCH
    body TEXT DEFAULT NULL,                -- Request body (typically JSON)
    headers JSONB DEFAULT '{}',            -- Custom headers
    timeout_seconds INT DEFAULT 30         -- Request timeout
) RETURNS TEXT                             -- Response body
```

**Examples:**

```sql
-- Simple GET
SELECT df.start(df.http('https://api.example.com/data', 'GET'));

-- POST with JSON body
SELECT df.start(
    df.http(
        'https://api.example.com/process',
        'POST',
        '{"input": "data"}',
        '{"Authorization": "Bearer token123"}'
    )
);

-- In a pipeline with variable substitution
SELECT df.start(
    'SELECT id, content FROM documents WHERE id = 1' |=> 'doc'
    ~> df.http(
        'https://ai-api.example.com/embed',
        'POST',
        '{"text": "$doc.content"}'  -- Variables substituted at runtime
    ) |=> 'embedding'
    ~> 'UPDATE documents SET embedding = $embedding WHERE id = 1'
);
```

### `df.azure()` - Azure Functions Convenience Wrapper

```sql
df.azure(
    function_app TEXT,                     -- App name (e.g., 'my-ai-functions')
    function_name TEXT,                    -- Function name (e.g., 'generate-embedding')
    body TEXT DEFAULT NULL                 -- JSON payload
) RETURNS TEXT
```

This is syntactic sugar that:
1. Constructs URL: `https://{function_app}.azurewebsites.net/api/{function_name}`
2. Looks up function key from `df.secrets` table
3. Adds `x-functions-key` and `Content-Type: application/json` headers
4. Calls `df.http()` with 60s timeout

**Examples:**

```sql
-- Direct Azure Function call
SELECT df.start(
    df.azure('my-ai-app', 'generate-embedding', '{"text": "hello world"}')
);

-- In a pipeline
SELECT df.start(
    'SELECT content FROM articles WHERE id = 1' |=> 'article'
    ~> df.azure('ai-functions', 'summarize', '{"text": "$article.content"}') |=> 'summary'
    ~> 'UPDATE articles SET summary = $summary WHERE id = 1'
);
```

---

## Implementation

### 1. Secrets Table

```sql
-- Add to extension_sql! in lib.rs
CREATE TABLE IF NOT EXISTS df.secrets (
    name TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Restrict access
REVOKE ALL ON df.secrets FROM PUBLIC;
COMMENT ON TABLE df.secrets IS 'Stores API keys and secrets for df.http() and df.azure()';
```

### 2. DSL Functions (`src/dsl.rs`)

```rust
/// Creates an HTTP request node
#[pg_extern(schema = "df")]
pub fn http(
    url: &str,
    method: default!(&str, "'POST'"),
    body: default!(Option<&str>, "NULL"),
    headers: default!(Option<pgrx::JsonB>, "NULL"),
    timeout_seconds: default!(i32, "30"),
) -> String {
    // Validate method
    let method_upper = method.to_uppercase();
    if !["GET", "POST", "PUT", "DELETE", "PATCH"].contains(&method_upper.as_str()) {
        pgrx::error!("Invalid HTTP method: {}. Must be GET, POST, PUT, DELETE, or PATCH", method);
    }

    let config = serde_json::json!({
        "url": url,
        "method": method_upper,
        "body": body,
        "headers": headers.as_ref().map(|h| &h.0),
        "timeout_seconds": timeout_seconds
    });

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "HTTP".to_string(),
        left_node: None,
        right_node: None,
        query: Some(config.to_string()),
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
}

/// Azure Functions convenience wrapper
#[pg_extern(schema = "df")]
pub fn azure(
    function_app: &str,
    function_name: &str,
    body: default!(Option<&str>, "NULL"),
) -> String {
    let url = format!(
        "https://{}.azurewebsites.net/api/{}",
        function_app, function_name
    );

    // Look up function key from secrets table
    let key: Option<String> = Spi::get_one(&format!(
        "SELECT value FROM df.secrets WHERE name = '{}_key'",
        function_app.replace('\'', "''")
    ))
    .ok()
    .flatten();

    let mut headers = serde_json::Map::new();
    headers.insert(
        "Content-Type".to_string(),
        serde_json::Value::String("application/json".to_string()),
    );
    if let Some(k) = key {
        headers.insert(
            "x-functions-key".to_string(),
            serde_json::Value::String(k),
        );
    }

    // Delegate to http()
    http(
        &url,
        "POST",
        body,
        Some(pgrx::JsonB(serde_json::Value::Object(headers))),
        60,
    )
}
```

### 3. HTTP Config Type (`src/types.rs`)

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpConfig {
    pub url: String,
    pub method: String,
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub headers: Option<serde_json::Value>,
    #[serde(default = "default_timeout")]
    pub timeout_seconds: u64,
}

fn default_timeout() -> u64 {
    30
}
```

### 4. Activity Registration (`src/runtime.rs`)

Add to `ActivityRegistry::builder()`:

```rust
.register("ExecuteHTTP", move |ctx: ActivityContext, config_json: String| {
    async move {
        let config: HttpConfig = serde_json::from_str(&config_json)
            .map_err(|e| format!("Invalid HTTP config: {}", e))?;

        ctx.trace_info(format!("HTTP {} {}", config.method, config.url));

        // Build client with timeout
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(config.timeout_seconds))
            .build()
            .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

        // Build request
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
        let response = request.send().await
            .map_err(|e| format!("HTTP request failed: {}", e))?;

        let status = response.status();
        let status_code = status.as_u16();
        let response_body = response.text().await
            .map_err(|e| format!("Failed to read response body: {}", e))?;

        // Check for success (2xx)
        if !status.is_success() {
            return Err(format!(
                "HTTP {} {} returned {}: {}",
                config.method, config.url, status_code, response_body
            ));
        }

        ctx.trace_info(format!("HTTP {} completed with status {}", config.method, status_code));
        Ok(response_body)
    }
})
```

### 5. Node Execution (`src/runtime.rs`)

Add to `execute_node_inner()` match statement:

```rust
"http" => {
    let config_str = node
        .query
        .as_ref()
        .ok_or_else(|| format!("HTTP node {} has no config", node_id))?;

    // Parse config to substitute variables in body
    let mut config: serde_json::Value = serde_json::from_str(config_str)
        .map_err(|e| format!("Invalid HTTP config: {}", e))?;

    // Substitute variables in body if present
    if let Some(body) = config.get("body").and_then(|b| b.as_str()) {
        let substituted_body = substitute_variables(body, results);
        config["body"] = serde_json::Value::String(substituted_body);
    }

    // Substitute variables in URL if present (for dynamic endpoints)
    if let Some(url) = config.get("url").and_then(|u| u.as_str()) {
        let substituted_url = substitute_variables(url, results);
        config["url"] = serde_json::Value::String(substituted_url);
    }

    let final_config = config.to_string();
    ctx.trace_info(format!("Executing HTTP request to {}", config["url"]));

    let result = ctx
        .schedule_activity("ExecuteHTTP", final_config)
        .into_activity()
        .await?;

    // Store result if named
    if let Some(name) = &node.result_name {
        ctx.trace_info(format!("Storing HTTP result as ${}", name));
        results.insert(name.clone(), result.clone());
    }

    Ok(result)
}
```

### 6. Cargo.toml Addition

```toml
[dependencies]
reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls"] }
```

### 7. Explain Support (`src/explain.rs`)

Add HTTP node visualization:

```rust
// In format_node_tree()
"HTTP" => {
    let config: serde_json::Value = node.query
        .as_ref()
        .and_then(|q| serde_json::from_str(q).ok())
        .unwrap_or(serde_json::json!({}));
    
    let method = config["method"].as_str().unwrap_or("POST");
    let url = config["url"].as_str().unwrap_or("?");
    
    // Truncate long URLs
    let display_url = if url.len() > 50 {
        format!("{}...", &url[..47])
    } else {
        url.to_string()
    };
    
    format!("HTTP {} {}", method, display_url)
}
```

---

## Usage Examples

### Basic HTTP Calls

```sql
-- GET request
SELECT df.start(
    df.http('https://api.example.com/users/123', 'GET') |=> 'user'
    ~> 'INSERT INTO users_cache (data) VALUES ($user::jsonb)'
);

-- POST with auth header
SELECT df.start(
    df.http(
        'https://api.stripe.com/v1/charges',
        'POST',
        '{"amount": 1000, "currency": "usd"}',
        '{"Authorization": "Bearer sk_test_xxx"}'
    )
);
```

### Azure Functions

```sql
-- Store function key
INSERT INTO df.secrets (name, value) VALUES ('my-ai-app_key', 'your-key-here');

-- Call Azure Function
SELECT df.start(
    df.azure('my-ai-app', 'generate-embedding', '{"text": "hello"}') |=> 'result'
    ~> 'SELECT $result'
);
```

### AI Pipeline

```sql
SELECT df.start(
    -- Get document
    'SELECT id, content FROM documents WHERE needs_summary LIMIT 1' |=> 'doc'
    
    -- Call Azure Function for summarization
    ~> df.azure('ai-functions', 'summarize', 
        '{"text": "$doc.content", "max_length": 100}') |=> 'summary'
    
    -- Call Azure Function for embedding
    ~> df.azure('ai-functions', 'embed',
        '{"text": "$summary"}') |=> 'embedding'
    
    -- Store results
    ~> 'UPDATE documents SET 
            summary = $summary::jsonb->>''summary'',
            embedding = ($embedding::jsonb->>''vector'')::vector
        WHERE id = ($doc::jsonb->>''id'')::int',
    
    'summarize-and-embed'
);
```

### Parallel API Calls

```sql
SELECT df.start(
    'SELECT content FROM article WHERE id = 1' |=> 'text'
    
    ~> df.join3(
        df.azure('ai', 'sentiment', '{"text": "$text"}'),
        df.azure('ai', 'entities', '{"text": "$text"}'),
        df.azure('ai', 'keywords', '{"text": "$text"}')
    ) |=> 'results'
    
    ~> 'UPDATE article SET analysis = $results::jsonb WHERE id = 1'
);
```

### Webhook Call

```sql
SELECT df.start(
    'SELECT order_id, status FROM orders WHERE id = $1' |=> 'order'
    ~> df.http(
        'https://partner.example.com/webhook/order-update',
        'POST',
        '{"order_id": "$order.order_id", "status": "$order.status"}',
        '{"X-Webhook-Secret": "shared-secret-123"}'
    )
);
```

---

## Error Handling

### Response Structure

HTTP always returns a JSON object with full response info:

```json
{
  "status": 200,
  "body": "{\"result\": \"success\"}",
  "headers": {
    "content-type": "application/json",
    "x-request-id": "abc123"
  },
  "ok": true,
  "duration_ms": 245
}
```

### Behavior by Status Code

| HTTP Status | `ok` | Activity Fails? | Notes |
|-------------|------|-----------------|-------|
| 2xx | `true` | No | Success |
| 4xx | `false` | **No** | Client error - returned for user to handle |
| 5xx | `false` | **Yes** (default) | Server error - retry makes sense |
| Timeout | - | **Yes** | Network-level failure |
| Connection refused | - | **Yes** | Network-level failure |

### Why 4xx Doesn't Fail

4xx errors are often valid business responses:
- `404 Not Found` - Resource doesn't exist (valid info)
- `409 Conflict` - Already processed (idempotency)
- `422 Unprocessable` - Validation error (bad input)

The user should handle these in workflow logic, not retry blindly.

### Why 5xx Does Fail

5xx errors are transient server issues - retrying makes sense:
- `500 Internal Server Error` - Server bug, might work on retry
- `502 Bad Gateway` - Upstream issue, might recover
- `503 Service Unavailable` - Overloaded, retry later
- `429 Too Many Requests` - Rate limited, retry with backoff

### Configuration Options

```sql
df.http(
    url TEXT,
    method TEXT DEFAULT 'POST',
    body TEXT DEFAULT NULL,
    headers JSONB DEFAULT '{}',
    timeout_seconds INT DEFAULT 30,
    fail_on_5xx BOOLEAN DEFAULT TRUE  -- Set FALSE to handle 5xx in workflow
) RETURNS TEXT  -- JSON response object
```

### Usage Patterns

**Pattern 1: Simple (fail on server errors, auto-retry)**

```sql
SELECT df.start(
    df.http('https://api.example.com/data') |=> 'response'
    ~> 'SELECT ($response::jsonb->>''body'')::jsonb'
);
-- If 5xx: activity fails, Duroxide retries
-- If 4xx: returns response, user can check status
-- If 2xx: returns response
```

**Pattern 2: Check status code explicitly**

```sql
SELECT df.start(
    df.http('https://api.example.com/users/123') |=> 'response'
    ~> df.if(
        'SELECT ($response::jsonb->>''ok'')::boolean',
        -- Success: use the data
        'SELECT ($response::jsonb->>''body'')::jsonb',
        -- Error: handle based on status
        df.if(
            'SELECT ($response::jsonb->>''status'')::int = 404',
            'SELECT ''{"error": "user not found"}''::jsonb',  -- Expected case
            'SELECT ''{"error": "unexpected error"}''::jsonb' -- Log/alert
        )
    )
);
```

**Pattern 3: Custom retry with backoff (for rate limiting)**

```sql
SELECT df.start(
    df.http('https://api.example.com/data', fail_on_5xx => FALSE) |=> 'r1'
    ~> df.if(
        'SELECT ($r1::jsonb->>''status'')::int = 429',
        -- Rate limited: wait and retry
        df.sleep(60) 
        ~> df.http('https://api.example.com/data') |=> 'r2'
        ~> 'SELECT $r2',
        'SELECT $r1'  -- Not rate limited, use response
    )
);
```

**Pattern 4: Webhook with expected 4xx**

```sql
-- Webhook that returns 409 if already processed (idempotent)
SELECT df.start(
    df.http('https://partner.com/webhook', 'POST', $payload) |=> 'response'
    ~> df.if(
        'SELECT ($response::jsonb->>''status'')::int IN (200, 409)',
        'SELECT ''delivered''',  -- 200 = new, 409 = already sent, both OK
        'SELECT ''failed: '' || ($response::jsonb->>''body'')'
    )
);
```

### Updated Activity Implementation

```rust
.register("ExecuteHTTP", move |ctx: ActivityContext, config_json: String| {
    async move {
        let config: HttpConfig = serde_json::from_str(&config_json)
            .map_err(|e| format!("Invalid HTTP config: {}", e))?;

        let start = std::time::Instant::now();
        ctx.trace_info(format!("HTTP {} {}", config.method, config.url));

        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(config.timeout_seconds))
            .build()
            .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

        let mut request = match config.method.as_str() {
            "GET" => client.get(&config.url),
            "POST" => client.post(&config.url),
            "PUT" => client.put(&config.url),
            "DELETE" => client.delete(&config.url),
            "PATCH" => client.patch(&config.url),
            _ => return Err(format!("Unsupported method: {}", config.method)),
        };

        if let Some(headers) = &config.headers {
            if let Some(obj) = headers.as_object() {
                for (key, value) in obj {
                    if let Some(v) = value.as_str() {
                        request = request.header(key, v);
                    }
                }
            }
        }

        if let Some(body) = &config.body {
            request = request.body(body.clone());
        }

        // Execute request
        let response = request.send().await
            .map_err(|e| {
                if e.is_timeout() {
                    format!("HTTP timeout after {}s", config.timeout_seconds)
                } else if e.is_connect() {
                    format!("HTTP connection failed: {}", e)
                } else {
                    format!("HTTP request failed: {}", e)
                }
            })?;

        let status = response.status();
        let status_code = status.as_u16();
        
        // Collect response headers
        let response_headers: serde_json::Map<String, serde_json::Value> = response
            .headers()
            .iter()
            .filter_map(|(k, v)| {
                v.to_str().ok().map(|s| (k.to_string(), serde_json::Value::String(s.to_string())))
            })
            .collect();

        let response_body = response.text().await
            .map_err(|e| format!("Failed to read response body: {}", e))?;

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

        // Fail on 5xx if configured (default true)
        if status.is_server_error() && config.fail_on_5xx.unwrap_or(true) {
            return Err(format!(
                "HTTP {} {} returned {}: {}",
                config.method, config.url, status_code, response_body
            ));
        }

        Ok(result.to_string())
    }
})
```

### Summary

| Error Type | Default Behavior | Rationale |
|------------|------------------|-----------|
| Network errors | **Fail + Retry** | Transient, retry helps |
| Timeout | **Fail + Retry** | Might succeed on retry |
| 5xx Server Error | **Fail + Retry** | Server issue, retry helps |
| 4xx Client Error | **Return response** | Business logic, user handles |
| 2xx Success | **Return response** | Normal flow |

This gives you:
- **Automatic retries** for transient failures (network, 5xx)
- **Full control** for business errors (4xx)
- **Rich response data** (status, body, headers, timing) for debugging

---

## Testing

### Unit Tests

```rust
#[pg_test]
fn test_http_creates_valid_node() {
    let json = crate::dsl::http("https://example.com", "GET", None, None, 30);
    let fut = Durofut::from_json(&json);
    assert_eq!(fut.node_type, "HTTP");
}

#[pg_test]
fn test_http_config_parsing() {
    let json = crate::dsl::http(
        "https://example.com/api",
        "POST",
        Some(r#"{"key": "value"}"#),
        Some(pgrx::JsonB(serde_json::json!({"Auth": "Bearer x"}))),
        60
    );
    let fut = Durofut::from_json(&json);
    let config: HttpConfig = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
    assert_eq!(config.url, "https://example.com/api");
    assert_eq!(config.method, "POST");
    assert_eq!(config.timeout_seconds, 60);
}

#[pg_test]
fn test_azure_constructs_url() {
    let json = crate::dsl::azure("my-app", "my-func", Some(r#"{"x": 1}"#));
    let fut = Durofut::from_json(&json);
    let config: HttpConfig = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
    assert!(config.url.contains("my-app.azurewebsites.net/api/my-func"));
}

#[pg_test]
fn test_http_invalid_method() {
    // Should error
    let result = std::panic::catch_unwind(|| {
        crate::dsl::http("https://example.com", "INVALID", None, None, 30)
    });
    assert!(result.is_err());
}
```

### E2E Test (requires mock server or real endpoint)

```sql
-- tests/e2e/sql/XX_http.sql

-- Test basic HTTP GET (use httpbin.org for testing)
CREATE TEMP TABLE _http_test (instance_id TEXT);

INSERT INTO _http_test SELECT df.start(
    df.http('https://httpbin.org/get', 'GET') |=> 'response'
    ~> 'SELECT ($response::jsonb->>''url'') as url',
    'test-http-get'
);

-- Wait and verify
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _http_test;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed') OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'HTTP test failed with status %', status;
    END IF;
    
    RAISE NOTICE 'HTTP test passed';
END $$;

DROP TABLE _http_test;
```

---

## Checklist

- [ ] Add `df.secrets` table to `extension_sql!`
- [ ] Add `HttpConfig` to `src/types.rs`
- [ ] Add `df.http()` to `src/dsl.rs`
- [ ] Add `df.azure()` to `src/dsl.rs`
- [ ] Add `reqwest` to `Cargo.toml`
- [ ] Register `ExecuteHTTP` activity in `src/runtime.rs`
- [ ] Add `"http"` case to `execute_node_inner()` in `src/runtime.rs`
- [ ] Add HTTP node formatting to `src/explain.rs`
- [ ] Add unit tests
- [ ] Add E2E test
- [ ] Update `USER_GUIDE.md` with HTTP examples

