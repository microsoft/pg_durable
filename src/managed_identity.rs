use std::collections::BTreeMap;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use reqwest::header::HeaderValue;
use serde::Deserialize;
use tokio::sync::Mutex;
use url::Url;
use uuid::Uuid;

pub const DEFAULT_TOKEN_ENDPOINT: &std::ffi::CStr =
    c"http://169.254.169.254/metadata/identity/oauth2/token";
const TOKEN_TIMEOUT: Duration = Duration::from_secs(10);
const REFRESH_MARGIN: Duration = Duration::from_secs(120);
const MAX_TOKEN_RESPONSE_BYTES: usize = 64 * 1024;
const MAX_CACHED_IDENTITIES: usize = 128;

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Identity {
    resource: &'static str,
    client_id: Option<Uuid>,
}

impl Identity {
    pub fn for_endpoint(url: &Url, client_id: Option<&str>) -> Result<Self, String> {
        if url.scheme() != "https" || url.port_or_known_default() != Some(443) {
            return Err("Managed identity destinations must use HTTPS on port 443".into());
        }
        let host = url
            .host_str()
            .ok_or("Managed identity destination has no hostname")?;
        let resource = if host == "management.azure.com" {
            "https://management.azure.com/"
        } else {
            [
                (".openai.azure.com", "https://cognitiveservices.azure.com"),
                (
                    ".cognitiveservices.azure.com",
                    "https://cognitiveservices.azure.com",
                ),
                (
                    ".services.ai.azure.com",
                    "https://cognitiveservices.azure.com",
                ),
                (".blob.core.windows.net", "https://storage.azure.com/"),
                (".blob.storage.azure.net", "https://storage.azure.com/"),
                (".dfs.core.windows.net", "https://storage.azure.com/"),
                (".queue.core.windows.net", "https://storage.azure.com/"),
                (".table.core.windows.net", "https://storage.azure.com/"),
                (".file.core.windows.net", "https://storage.azure.com/"),
                (".vault.azure.net", "https://vault.azure.net"),
            ]
            .into_iter()
            .find(|(suffix, _)| host.len() > suffix.len() && host.ends_with(suffix))
            .map(|(_, resource)| resource)
            .ok_or("Managed identity is not supported for this destination hostname")?
        };
        let client_id = client_id
            .map(|value| {
                Uuid::parse_str(value).map_err(|_| "Managed identity client_id must be a UUID")
            })
            .transpose()?;
        Ok(Self {
            resource,
            client_id,
        })
    }
}

pub fn validate_token_endpoint(value: &str) -> Result<Url, String> {
    let endpoint = Url::parse(value).map_err(|_| "Invalid managed identity token endpoint")?;
    let local_http = endpoint.scheme() == "http"
        && matches!(endpoint.host(), Some(url::Host::Ipv4(address)) if address.is_loopback() || address.octets() == [169, 254, 169, 254])
        || endpoint.scheme() == "http"
            && matches!(endpoint.host(), Some(url::Host::Ipv6(address)) if address.is_loopback());
    if (!local_http && endpoint.scheme() != "https")
        || endpoint.host_str().is_none()
        || !endpoint.username().is_empty()
        || endpoint.password().is_some()
        || endpoint.query().is_some()
        || endpoint.fragment().is_some()
        || value
            .chars()
            .any(|character| character.is_control() || character.is_whitespace())
        || value.contains(['{', '}', '\\'])
    {
        return Err("Managed identity token endpoint must be HTTPS, or HTTP on a loopback or IMDS address, without userinfo, query or fragment".into());
    }
    Ok(endpoint)
}

#[pgrx::pg_guard]
pub(crate) unsafe extern "C-unwind" fn check_token_endpoint(
    newval: *mut *mut std::ffi::c_char,
    _extra: *mut *mut std::ffi::c_void,
    _source: pgrx::pg_sys::GucSource::Type,
) -> bool {
    let result = if unsafe { (*newval).is_null() } {
        Err("Managed identity token endpoint must not be NULL".into())
    } else {
        unsafe { std::ffi::CStr::from_ptr(*newval) }
            .to_str()
            .map_err(|_| "Managed identity token endpoint must be UTF-8".into())
            .and_then(validate_token_endpoint)
    };
    match result {
        Ok(_) => true,
        Err(error) => {
            if unsafe { pgrx::pg_sys::process_shared_preload_libraries_in_progress } {
                pgrx::error!(
                    "invalid value for parameter \"pg_durable.managed_identity_endpoint\": {error}"
                );
            }
            unsafe {
                pgrx::pg_sys::GUC_check_errdetail_string =
                    pgrx::PgMemoryContexts::ErrorContext.pstrdup(&error);
            }
            false
        }
    }
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Seconds {
    Number(u64),
    Text(String),
}

impl Seconds {
    fn value(self) -> Result<u64, String> {
        match self {
            Self::Number(value) => Ok(value),
            Self::Text(value) => value
                .parse()
                .map_err(|_| "Invalid managed identity token expiry".into()),
        }
    }
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    token_type: String,
    resource: String,
    expires_on: Option<Seconds>,
    expires_in: Option<Seconds>,
    not_before: Option<Seconds>,
    error: Option<serde_json::Value>,
}

struct CachedToken {
    authorization: HeaderValue,
    refresh_at: Instant,
    refresh_by: SystemTime,
}

impl CachedToken {
    fn parse(bytes: &[u8], identity: &Identity, requested_at: SystemTime) -> Result<Self, String> {
        let response: TokenResponse =
            serde_json::from_slice(bytes).map_err(|_| "Invalid managed identity token response")?;
        if response.error.is_some()
            || !response.token_type.eq_ignore_ascii_case("Bearer")
            || response.resource != identity.resource
            || response.access_token.is_empty()
            || !response
                .access_token
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"-._~+/=".contains(&byte))
        {
            return Err("Invalid managed identity token response".into());
        }
        let expires_on = match (response.expires_on, response.expires_in) {
            (Some(expiry), _) => UNIX_EPOCH.checked_add(Duration::from_secs(expiry.value()?)),
            (None, Some(lifetime)) => {
                requested_at.checked_add(Duration::from_secs(lifetime.value()?))
            }
            (None, None) => return Err("Managed identity token response has no expiry".into()),
        }
        .ok_or("Invalid managed identity token expiry")?;
        let now = SystemTime::now();
        if let Some(not_before) = response.not_before {
            let not_before = UNIX_EPOCH
                .checked_add(Duration::from_secs(not_before.value()?))
                .ok_or("Invalid managed identity token validity period")?;
            if not_before > now {
                return Err("Managed identity token is not yet valid".into());
            }
        }
        let refresh_by = expires_on
            .checked_sub(REFRESH_MARGIN)
            .ok_or("Invalid managed identity token expiry")?;
        let remaining = refresh_by
            .duration_since(now)
            .map_err(|_| "Managed identity token is expired or too close to expiry")?;
        let refresh_at = Instant::now()
            .checked_add(remaining)
            .ok_or("Invalid managed identity token expiry")?;
        let mut authorization = HeaderValue::from_str(&format!("Bearer {}", response.access_token))
            .map_err(|_| "Invalid managed identity access token")?;
        authorization.set_sensitive(true);
        Ok(Self {
            authorization,
            refresh_at,
            refresh_by,
        })
    }

    fn is_fresh(&self) -> bool {
        Instant::now() < self.refresh_at && SystemTime::now() < self.refresh_by
    }
}

pub struct TokenClient {
    endpoint: Url,
    client: OnceLock<Result<reqwest::Client, String>>,
    tokens: Mutex<BTreeMap<Identity, Arc<Mutex<Option<CachedToken>>>>>,
}

impl TokenClient {
    pub fn new(endpoint: &str) -> Result<Self, String> {
        let endpoint = validate_token_endpoint(endpoint)?;
        Ok(Self {
            endpoint,
            client: OnceLock::new(),
            tokens: Mutex::new(BTreeMap::new()),
        })
    }

    pub async fn authorization(&self, identity: &Identity) -> Result<HeaderValue, String> {
        tokio::time::timeout(TOKEN_TIMEOUT, self.cached_authorization(identity))
            .await
            .map_err(|_| "Managed identity token acquisition timed out")?
    }

    async fn cached_authorization(&self, identity: &Identity) -> Result<HeaderValue, String> {
        let entry = {
            let mut tokens = self.tokens.lock().await;
            if let Some(entry) = tokens.get(identity) {
                entry.clone()
            } else {
                if tokens.len() >= MAX_CACHED_IDENTITIES {
                    let removable = tokens
                        .iter()
                        .find(|(_, entry)| Arc::strong_count(entry) == 1)
                        .map(|(key, _)| key.clone())
                        .ok_or("Managed identity token cache is busy; retry the request")?;
                    tokens.remove(&removable);
                }
                let entry = Arc::new(Mutex::new(None));
                tokens.insert(identity.clone(), entry.clone());
                entry
            }
        };
        let mut token = entry.lock().await;
        if let Some(token) = token.as_ref().filter(|token| token.is_fresh()) {
            return Ok(token.authorization.clone());
        }
        *token = None;
        let fetched = self.fetch(identity).await?;
        let authorization = fetched.authorization.clone();
        *token = Some(fetched);
        Ok(authorization)
    }

    async fn fetch(&self, identity: &Identity) -> Result<CachedToken, String> {
        let client = self
            .client
            .get_or_init(|| {
                reqwest::Client::builder()
                    .no_proxy()
                    .redirect(reqwest::redirect::Policy::none())
                    .connect_timeout(Duration::from_secs(2))
                    .timeout(TOKEN_TIMEOUT)
                    .build()
                    .map_err(|_| "Failed to initialize managed identity token client".into())
            })
            .as_ref()
            .map_err(Clone::clone)?;
        let requested_at = SystemTime::now();
        let mut url = self.endpoint.clone();
        {
            let mut query = url.query_pairs_mut();
            query
                .append_pair("api-version", "2018-02-01")
                .append_pair("resource", identity.resource);
            if let Some(client_id) = identity.client_id {
                query.append_pair("client_id", &client_id.to_string());
            }
        }
        let mut response = client
            .get(url)
            .header("Metadata", "true")
            .send()
            .await
            .map_err(|_| "Managed identity token provider is unavailable")?;
        if response.status() != reqwest::StatusCode::OK {
            return Err(format!(
                "Managed identity token provider returned HTTP {}",
                response.status().as_u16()
            ));
        }
        if response
            .content_length()
            .is_some_and(|size| size > MAX_TOKEN_RESPONSE_BYTES as u64)
        {
            return Err("Managed identity token response exceeds the size limit".into());
        }
        let mut body = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "Failed to read managed identity token response")?
        {
            if chunk.len() > MAX_TOKEN_RESPONSE_BYTES - body.len() {
                return Err("Managed identity token response exceeds the size limit".into());
            }
            body.extend_from_slice(&chunk);
        }
        CachedToken::parse(&body, identity, requested_at)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::TcpListener;

    fn http_response(body: &str) -> String {
        format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len())
    }

    async fn mock_provider(
        responses: Vec<String>,
    ) -> (TokenClient, tokio::task::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!(
            "http://{}/metadata/identity/oauth2/token",
            listener.local_addr().unwrap()
        );
        let server = tokio::spawn(async move {
            let mut requests = Vec::new();
            for response in responses {
                let (stream, _) = tokio::time::timeout(Duration::from_secs(15), listener.accept())
                    .await
                    .unwrap()
                    .unwrap();
                let mut stream = BufReader::new(stream);
                let mut request = String::new();
                loop {
                    let mut line = String::new();
                    let count =
                        tokio::time::timeout(Duration::from_secs(5), stream.read_line(&mut line))
                            .await
                            .unwrap()
                            .unwrap();
                    if count == 0 || line == "\r\n" {
                        break;
                    }
                    request.push_str(&line);
                }
                requests.push(request);
                let _ = stream.get_mut().write_all(response.as_bytes()).await;
            }
            requests
        });
        (TokenClient::new(&endpoint).unwrap(), server)
    }

    fn identity() -> Identity {
        Identity::for_endpoint(
            &Url::parse("https://account.blob.core.windows.net").unwrap(),
            None,
        )
        .unwrap()
    }

    fn response() -> serde_json::Value {
        serde_json::json!({
            "access_token": "PRIVATE_TOKEN",
            "token_type": "Bearer",
            "resource": "https://storage.azure.com/",
            "expires_in": "3600"
        })
    }

    #[tokio::test]
    async fn managed_identity_cache_coalesces_concurrent_requests() {
        let (client, server) = mock_provider(vec![http_response(&response().to_string())]).await;
        let client = Arc::new(client);
        assert!(client.client.get().is_none());
        let mut tasks = Vec::new();
        for _ in 0..16 {
            let client = client.clone();
            tasks.push(tokio::spawn(async move {
                client.authorization(&identity()).await.unwrap()
            }));
        }
        for task in tasks {
            let header = task.await.unwrap();
            assert_eq!(header, "Bearer PRIVATE_TOKEN");
            assert!(header.is_sensitive());
        }
        let requests = server.await.unwrap();
        assert_eq!(requests.len(), 1);
        assert!(requests[0]
            .to_ascii_lowercase()
            .contains("metadata: true\r\n"));
        assert!(!requests[0].contains("PRIVATE_TOKEN"));
        let url = Url::parse(&format!(
            "http://localhost{}",
            requests[0].split_whitespace().nth(1).unwrap()
        ))
        .unwrap();
        let query: BTreeMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(query.len(), 2);
        assert_eq!(query["api-version"], "2018-02-01");
        assert_eq!(query["resource"], "https://storage.azure.com/");
        assert_eq!(
            client.authorization(&identity()).await.unwrap(),
            "Bearer PRIVATE_TOKEN"
        );
    }

    #[tokio::test]
    async fn managed_identity_cache_separates_clients_and_resources() {
        let storage = Url::parse("https://account.blob.core.windows.net").unwrap();
        let identities = [
            identity(),
            Identity::for_endpoint(&storage, Some("11111111-1111-1111-1111-111111111111")).unwrap(),
            Identity::for_endpoint(&storage, Some("22222222-2222-2222-2222-222222222222")).unwrap(),
            Identity::for_endpoint(
                &Url::parse("https://example.openai.azure.com").unwrap(),
                None,
            )
            .unwrap(),
        ];
        let responses = identities
            .iter()
            .enumerate()
            .map(|(index, identity)| {
                let mut response = response();
                response["resource"] = serde_json::json!(identity.resource);
                response["access_token"] = serde_json::json!(format!("PRIVATE_TOKEN_{index}"));
                http_response(&response.to_string())
            })
            .collect();
        let (client, server) = mock_provider(responses).await;
        for _ in 0..2 {
            for (index, identity) in identities.iter().enumerate() {
                assert_eq!(
                    client.authorization(identity).await.unwrap(),
                    format!("Bearer PRIVATE_TOKEN_{index}")
                );
            }
        }
        let requests = server.await.unwrap();
        assert_eq!(requests.len(), identities.len());
        for (request, identity) in requests.iter().zip(identities) {
            let url = Url::parse(&format!(
                "http://localhost{}",
                request.split_whitespace().nth(1).unwrap()
            ))
            .unwrap();
            let query: BTreeMap<_, _> = url.query_pairs().into_owned().collect();
            assert_eq!(query["resource"], identity.resource);
            assert_eq!(
                query.get("client_id"),
                identity
                    .client_id
                    .map(|client_id| client_id.to_string())
                    .as_ref()
            );
        }
    }

    #[tokio::test]
    async fn managed_identity_cache_refreshes_and_never_serves_stale_on_failure() {
        let responses = ["INITIAL", "REFRESHED", "REFRESHED_AGAIN"].map(|token| {
            let mut response = response();
            response["access_token"] = serde_json::json!(token);
            http_response(&response.to_string())
        });
        let (client, server) = mock_provider(responses.into_iter().chain([
            "HTTP/1.1 503 Unavailable\r\nContent-Length: 13\r\nConnection: close\r\n\r\nPRIVATE_TOKEN".into(),
        ]).collect()).await;
        assert_eq!(
            client.authorization(&identity()).await.unwrap(),
            "Bearer INITIAL"
        );
        let entry = client.tokens.lock().await.get(&identity()).unwrap().clone();
        entry.lock().await.as_mut().unwrap().refresh_at = Instant::now();
        assert_eq!(
            client.authorization(&identity()).await.unwrap(),
            "Bearer REFRESHED"
        );
        entry.lock().await.as_mut().unwrap().refresh_by = UNIX_EPOCH;
        assert_eq!(
            client.authorization(&identity()).await.unwrap(),
            "Bearer REFRESHED_AGAIN"
        );
        entry.lock().await.as_mut().unwrap().refresh_at = Instant::now();
        let error = client.authorization(&identity()).await.unwrap_err();
        assert!(error.contains("HTTP 503"));
        assert!(!error.contains("PRIVATE_TOKEN"));
        assert!(entry.lock().await.is_none());
        assert_eq!(server.await.unwrap().len(), 4);
    }

    #[tokio::test]
    async fn managed_identity_provider_failures_are_bounded_and_redacted() {
        let oversized = "x".repeat(MAX_TOKEN_RESPONSE_BYTES + 1);
        let responses = vec![
            ("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9/?token=PRIVATE_TOKEN\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into(), "HTTP 302"),
            ("HTTP/1.1 400 Bad Request\r\nContent-Length: 13\r\nConnection: close\r\n\r\nPRIVATE_TOKEN".into(), "HTTP 400"),
            (http_response("{\"error\":\"PRIVATE_TOKEN\",\"error_description\":\"PRIVATE_TOKEN\"}"), "Invalid managed identity token response"),
            (http_response("PRIVATE_TOKEN"), "Invalid managed identity token response"),
            (format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", MAX_TOKEN_RESPONSE_BYTES + 1), "size limit"),
            (format!("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:x}\r\n{oversized}\r\n0\r\n\r\n", oversized.len()), "size limit"),
            ("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nPRIVATE_TOKEN".into(), "Failed to read managed identity token response"),
        ];
        let (client, server) = mock_provider(
            responses
                .iter()
                .map(|(response, _)| response.clone())
                .collect(),
        )
        .await;
        for (_, expected) in responses {
            let error = client.authorization(&identity()).await.unwrap_err();
            assert!(error.contains(expected), "{error}");
            assert!(!error.contains("PRIVATE_TOKEN"));
        }
        assert_eq!(server.await.unwrap().len(), 7);
    }

    #[tokio::test]
    async fn managed_identity_cache_is_bounded_without_evicting_active_entries() {
        let (client, server) = mock_provider(vec![http_response(&response().to_string())]).await;
        for index in 0..MAX_CACHED_IDENTITIES {
            let mut identity = identity();
            identity.client_id = Some(Uuid::from_u128(index as u128 + 1));
            client
                .tokens
                .lock()
                .await
                .insert(identity, Arc::new(Mutex::new(None)));
        }
        let (active_identity, active) = {
            let entries = client.tokens.lock().await;
            let (identity, entry) = entries.first_key_value().unwrap();
            (identity.clone(), entry.clone())
        };
        client.authorization(&identity()).await.unwrap();
        assert_eq!(server.await.unwrap().len(), 1);
        let entries = client.tokens.lock().await;
        assert_eq!(entries.len(), MAX_CACHED_IDENTITIES);
        assert!(Arc::ptr_eq(entries.get(&active_identity).unwrap(), &active));
        let active_entries = entries.values().cloned().collect::<Vec<_>>();
        drop(entries);
        let mut another = identity();
        another.client_id = Some(Uuid::from_u128(MAX_CACHED_IDENTITIES as u128 + 1));
        assert!(client
            .authorization(&another)
            .await
            .unwrap_err()
            .contains("cache is busy"));
        drop(active_entries);
    }

    #[tokio::test]
    async fn managed_identity_timeout_releases_waiters() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let client =
            TokenClient::new(&format!("http://{}/token", listener.local_addr().unwrap())).unwrap();
        let server = tokio::spawn(async move {
            let (first, _) = listener.accept().await.unwrap();
            let (mut second, _) = listener.accept().await.unwrap();
            second
                .write_all(http_response(&response().to_string()).as_bytes())
                .await
                .unwrap();
            drop(first);
        });
        let error = client.authorization(&identity()).await.unwrap_err();
        assert!(error.contains("timed out"), "{error}");
        assert_eq!(
            client.authorization(&identity()).await.unwrap(),
            "Bearer PRIVATE_TOKEN"
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn managed_identity_is_not_contacted_for_other_authentication() {
        let client = TokenClient::new(DEFAULT_TOKEN_ENDPOINT.to_str().unwrap()).unwrap();
        let mut request = crate::endpoints::EndpointRequest {
            url: Url::parse("https://api.github.com/").unwrap(),
            credential_header: None,
            managed_identity: None,
        };
        request.authorize(&client).await.unwrap();
        assert!(client.client.get().is_none());
        assert!(client.tokens.lock().await.is_empty());
    }

    #[test]
    fn managed_identity_derives_resource_from_destination() {
        for (url, resource) in [
            (
                "https://example.openai.azure.com",
                "https://cognitiveservices.azure.com",
            ),
            (
                "https://example.cognitiveservices.azure.com",
                "https://cognitiveservices.azure.com",
            ),
            (
                "https://example.services.ai.azure.com",
                "https://cognitiveservices.azure.com",
            ),
            (
                "https://account.blob.core.windows.net",
                "https://storage.azure.com/",
            ),
            (
                "https://account.z01.blob.storage.azure.net",
                "https://storage.azure.com/",
            ),
            (
                "https://account.dfs.core.windows.net",
                "https://storage.azure.com/",
            ),
            (
                "https://account.queue.core.windows.net",
                "https://storage.azure.com/",
            ),
            (
                "https://account.table.core.windows.net",
                "https://storage.azure.com/",
            ),
            (
                "https://account.file.core.windows.net",
                "https://storage.azure.com/",
            ),
            ("https://example.vault.azure.net", "https://vault.azure.net"),
            (
                "https://management.azure.com",
                "https://management.azure.com/",
            ),
        ] {
            assert_eq!(
                Identity::for_endpoint(&Url::parse(url).unwrap(), None)
                    .unwrap()
                    .resource,
                resource
            );
        }
        for url in [
            "http://account.blob.core.windows.net",
            "https://account.blob.core.windows.net:8443",
            "https://account.blob.core.windows.net.evil.test",
            "https://notblob.core.windows.net",
            "https://blob.core.windows.net",
            "https://account.blob.core.windows.net.",
            "https://api.github.com",
            "https://example.azurewebsites.net",
            "https://169.254.169.254",
        ] {
            assert!(
                Identity::for_endpoint(&Url::parse(url).unwrap(), None).is_err(),
                "{url}"
            );
        }
    }

    #[test]
    fn managed_identity_validates_client_id() {
        let url = Url::parse("https://account.blob.core.windows.net").unwrap();
        let client_id = "12345678-1234-1234-1234-123456789abc";
        assert_eq!(
            Identity::for_endpoint(&url, Some(client_id))
                .unwrap()
                .client_id
                .unwrap()
                .to_string(),
            client_id
        );
        for invalid in ["", "PRIVATE_VALUE", "identifier\nresource"] {
            let error = Identity::for_endpoint(&url, Some(invalid)).unwrap_err();
            assert!(!error.contains("PRIVATE_VALUE"));
        }
    }

    #[test]
    fn managed_identity_validates_provider_configuration() {
        for valid in [
            DEFAULT_TOKEN_ENDPOINT.to_str().unwrap(),
            "http://127.0.0.1:8080/token",
            "http://[::1]:8080/token",
            "https://identity.example/token",
        ] {
            validate_token_endpoint(valid).unwrap();
        }
        for invalid in [
            "http://identity.example/token",
            "file:///token",
            "https://user:PRIVATE_VALUE@identity.example",
            "https://identity.example/?key=PRIVATE_VALUE",
            "https://identity.example/#PRIVATE_VALUE",
            "https://identity.example/\n",
        ] {
            let error = validate_token_endpoint(invalid).unwrap_err();
            assert!(!error.contains("PRIVATE_VALUE"));
        }
    }

    #[test]
    fn managed_identity_token_is_sensitive_and_expiring() {
        let token = CachedToken::parse(
            response().to_string().as_bytes(),
            &identity(),
            SystemTime::now(),
        )
        .unwrap();
        assert_eq!(token.authorization, "Bearer PRIVATE_TOKEN");
        assert!(token.authorization.is_sensitive());
        assert!(!format!("{:?}", token.authorization).contains("PRIVATE_TOKEN"));
        assert!(token.is_fresh());
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        for expiry in [
            serde_json::json!(now + 3600),
            serde_json::json!((now + 3600).to_string()),
        ] {
            let mut response = response();
            response["expires_on"] = expiry;
            assert!(CachedToken::parse(
                response.to_string().as_bytes(),
                &identity(),
                SystemTime::now()
            )
            .is_ok());
        }
    }

    #[test]
    fn managed_identity_rejects_invalid_tokens_without_echoing_them() {
        for (field, value) in [
            (
                "access_token",
                serde_json::json!("PRIVATE_TOKEN\r\nInjected: value"),
            ),
            ("access_token", serde_json::json!("")),
            ("token_type", serde_json::json!("PRIVATE_TOKEN")),
            ("resource", serde_json::json!("https://vault.azure.net")),
            ("expires_on", serde_json::json!("PRIVATE_TOKEN")),
            ("expires_on", serde_json::json!(0)),
            ("expires_on", serde_json::json!(-1)),
            ("expires_in", serde_json::json!(30)),
            ("expires_in", serde_json::Value::Null),
            ("not_before", serde_json::json!(u64::MAX)),
            ("error", serde_json::json!("PRIVATE_TOKEN")),
        ] {
            let mut response = response();
            response[field] = value;
            let error = CachedToken::parse(
                response.to_string().as_bytes(),
                &identity(),
                SystemTime::now(),
            )
            .err()
            .expect("invalid response must fail");
            assert!(!error.contains("PRIVATE_TOKEN"), "{error}");
        }
        assert!(CachedToken::parse(b"PRIVATE_TOKEN", &identity(), SystemTime::now()).is_err());
    }
}
