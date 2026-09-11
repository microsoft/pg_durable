use std::collections::BTreeMap;

use pgrx::prelude::*;
use reqwest::header::{HeaderName, HeaderValue, AUTHORIZATION};
use serde::{Deserialize, Serialize};
use sqlx::Connection;
use tokio::sync::{Semaphore, SemaphorePermit};
use url::Url;

pub const FDW_NAME: &str = "pg_durable_fdw";

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EndpointReference {
    #[serde(rename = "type")]
    kind: String,
    pub server: String,
    pub path: String,
}

fn validate_endpoint_path(path: &str) -> Result<(), String> {
    if !path.starts_with('/')
        || path.starts_with("//")
        || path.contains(['\\', '#'])
        || path
            .chars()
            .any(|character| character.is_control() || character.is_whitespace())
    {
        return Err("Endpoint path must start with one slash and contain no backslash, fragment or whitespace".into());
    }
    for segment in path.split('?').next().unwrap_or_default().split('/') {
        let decoded = percent_encoding::percent_decode_str(segment).collect::<Vec<u8>>();
        if decoded == b"."
            || decoded == b".."
            || decoded.contains(&b'/')
            || decoded.contains(&b'\\')
        {
            return Err(
                "Endpoint path cannot contain traversal segments or encoded separators".into(),
            );
        }
    }
    Ok(())
}

impl EndpointReference {
    pub fn parse(value: &str) -> Result<Option<Self>, String> {
        if !value.trim_start().starts_with('{') {
            return Ok(None);
        }
        let parsed: serde_json::Value = match serde_json::from_str(value) {
            Ok(parsed) => parsed,
            Err(_) => return Ok(None),
        };
        if parsed.get("type").and_then(serde_json::Value::as_str) != Some("pg_durable.endpoint") {
            return Ok(None);
        }
        let reference: Self =
            serde_json::from_value(parsed).map_err(|_| "Invalid endpoint reference")?;
        reference.validate()?;
        Ok(Some(reference))
    }

    fn validate(&self) -> Result<(), String> {
        if self.server.is_empty() || self.server.chars().any(char::is_control) {
            return Err(
                "Endpoint server name must be nonempty and contain no control characters".into(),
            );
        }
        validate_endpoint_path(&self.path)
    }
}

#[pg_extern(schema = "df", immutable, parallel_safe)]
pub fn endpoint(server: &str, path: &str) -> String {
    let reference = EndpointReference {
        kind: "pg_durable.endpoint".into(),
        server: server.into(),
        path: path.into(),
    };
    reference
        .validate()
        .unwrap_or_else(|error| pgrx::error!("{}", error));
    serde_json::to_string(&reference).expect("Endpoint reference serialization failed")
}

pub fn configure_destination(
    config: &mut serde_json::Value,
    destination: &str,
) -> Result<(), String> {
    if let Some(reference) = EndpointReference::parse(destination)? {
        config["url"] = serde_json::Value::String(reference.path);
        config["endpoint"] = serde_json::Value::String(reference.server);
    }
    Ok(())
}

pub fn set_execution_context(
    config: &mut serde_json::Value,
    submitted_by: &str,
    database: Option<&str>,
) {
    config["submitted_by"] = serde_json::Value::String(submitted_by.into());
    if config.get("endpoint").is_some()
        || config.get("secret_bindings").is_some()
        || config.get("form_fields").is_some()
    {
        config["database"] = database.map_or(serde_json::Value::Null, |database| {
            serde_json::Value::String(database.into())
        });
    }
}

fn compose_endpoint_url(base: &Url, path: &str) -> Result<Url, String> {
    validate_endpoint_path(path)?;
    let prefix = base.as_str().strip_suffix('/').unwrap_or(base.as_str());
    let composed =
        Url::parse(&format!("{prefix}{path}")).map_err(|_| "Invalid endpoint request URL")?;
    let base_path = base.path().strip_suffix('/').unwrap_or(base.path());
    if composed.origin() != base.origin() || !composed.path().starts_with(&format!("{base_path}/"))
    {
        return Err("Endpoint path cannot escape its base URL".into());
    }
    Ok(composed)
}

pub struct EndpointRequest {
    pub url: Url,
    pub credential_header: Option<(HeaderName, HeaderValue)>,
}

fn prepare_endpoint_request(
    endpoint: ResolvedEndpoint,
    path: &str,
    headers: Option<&serde_json::Value>,
) -> Result<EndpointRequest, String> {
    let mut url = compose_endpoint_url(&endpoint.base_url, path)?;
    let credential_name = match &endpoint.auth {
        EndpointAuth::Bearer(_) => Some(&AUTHORIZATION),
        EndpointAuth::Header { name, .. } => Some(name),
        _ => None,
    };
    if let Some(headers) = headers.and_then(serde_json::Value::as_object) {
        for name in headers.keys() {
            if name.eq_ignore_ascii_case("host")
                || credential_name
                    .is_some_and(|credential| name.eq_ignore_ascii_case(credential.as_str()))
            {
                return Err(
                    "Request headers cannot override endpoint routing or authentication".into(),
                );
            }
        }
    }
    let credential_header = match endpoint.auth {
        EndpointAuth::None => None,
        EndpointAuth::Bearer(value) => Some((AUTHORIZATION, value)),
        EndpointAuth::Header { name, value } => Some((name, value)),
        EndpointAuth::Query(query) => {
            let credential_url = Url::parse(&format!("https://endpoint.invalid/?{query}"))
                .map_err(|_| "Invalid endpoint credential query")?;
            let names = credential_url
                .query_pairs()
                .map(|(name, _)| name.into_owned())
                .collect::<std::collections::BTreeSet<_>>();
            if url
                .query_pairs()
                .any(|(name, _)| names.contains(name.as_ref()))
            {
                return Err("Request query cannot override endpoint credential parameters".into());
            }
            let combined = match url.query().filter(|query| !query.is_empty()) {
                Some(existing) => format!("{existing}&{query}"),
                None => query,
            };
            url.set_query(Some(&combined));
            None
        }
    };
    Ok(EndpointRequest {
        url,
        credential_header,
    })
}

pub async fn prepare_request(
    catalog: &mut EndpointCatalog<'_>,
    server: Option<&str>,
    url: &str,
    headers: Option<&serde_json::Value>,
) -> Result<EndpointRequest, String> {
    match server {
        Some(server) => {
            validate_endpoint_path(url)?;
            let endpoint = catalog.resolve_endpoint(server).await?;
            prepare_endpoint_request(endpoint, url, headers)
        }
        None => Ok(EndpointRequest {
            url: crate::ssrf::parse_request_url(url)?,
            credential_header: None,
        }),
    }
}

#[derive(Clone)]
pub enum AuthScheme {
    None,
    Bearer,
    Header(HeaderName),
    Query,
}

#[derive(Clone)]
pub struct EndpointConfig {
    pub base_url: Option<Url>,
    pub auth_scheme: AuthScheme,
}

fn parse_options(options: &[String]) -> Result<BTreeMap<&str, &str>, String> {
    let mut parsed = BTreeMap::new();
    for option in options {
        let (name, value) = option
            .split_once('=')
            .ok_or("Invalid endpoint option: expected name=value")?;
        if parsed.insert(name, value).is_some() {
            return Err("Duplicate endpoint option".into());
        }
    }
    Ok(parsed)
}

fn required<'a>(options: &BTreeMap<&str, &'a str>, name: &str) -> Result<&'a str, String> {
    options
        .get(name)
        .copied()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("Endpoint option '{name}' is required and must not be empty"))
}

impl EndpointConfig {
    pub fn from_options(options: &[String]) -> Result<Self, String> {
        let options = parse_options(options)?;
        if options
            .keys()
            .any(|name| !matches!(*name, "base_url" | "auth_scheme" | "header_name"))
        {
            return Err(
                "Unsupported endpoint server option; allowed: base_url, auth_scheme, header_name"
                    .into(),
            );
        }
        let base_url = if options.contains_key("base_url") {
            let raw_url = required(&options, "base_url")?;
            if raw_url
                .chars()
                .any(|character| character.is_whitespace() || character.is_control())
                || raw_url.contains(['{', '}', '\\'])
            {
                return Err("Endpoint base_url must be a literal HTTPS URL".into());
            }
            let base_url = Url::parse(raw_url).map_err(|_| "Invalid endpoint base_url")?;
            if base_url.scheme() != "https"
                || base_url.host_str().is_none()
                || !base_url.username().is_empty()
                || base_url.password().is_some()
                || base_url.query().is_some()
                || base_url.fragment().is_some()
            {
                return Err(
                    "Endpoint base_url must be HTTPS without userinfo, query or fragment".into(),
                );
            }
            Some(base_url)
        } else {
            None
        };
        let auth_scheme = match required(&options, "auth_scheme")? {
            "none" => AuthScheme::None,
            "bearer" => AuthScheme::Bearer,
            "query" => AuthScheme::Query,
            "header" => {
                let name = HeaderName::from_bytes(required(&options, "header_name")?.as_bytes())
                    .map_err(|_| "Invalid endpoint header_name")?;
                if matches!(
                    name.as_str(),
                    "host"
                        | "content-type"
                        | "content-length"
                        | "transfer-encoding"
                        | "connection"
                        | "proxy-authorization"
                        | "proxy-authenticate"
                        | "te"
                        | "trailer"
                        | "upgrade"
                        | "keep-alive"
                ) {
                    return Err(
                        "Endpoint header_name cannot control HTTP routing or framing".into(),
                    );
                }
                AuthScheme::Header(name)
            }
            "managed-identity" => {
                return Err("Managed identity is not supported in this version".into())
            }
            _ => {
                return Err(
                    "Unsupported endpoint auth_scheme; allowed: none, bearer, header, query".into(),
                )
            }
        };
        if !matches!(auth_scheme, AuthScheme::Header(_)) && options.contains_key("header_name") {
            return Err("Endpoint header_name requires auth_scheme 'header'".into());
        }
        if base_url.is_none() && !matches!(auth_scheme, AuthScheme::None) {
            return Err("Endpoint base_url is required unless auth_scheme is 'none'".into());
        }
        Ok(Self {
            base_url,
            auth_scheme,
        })
    }
}

fn validate_mapping_options(options: &[String]) -> Result<(), String> {
    let options = parse_options(options)?;
    for (name, value) in options {
        if let Some(key) = name.strip_prefix(crate::secrets::SECRET_OPTION_PREFIX) {
            crate::secrets::validate_secret_key(key)?;
            continue;
        }
        if value.is_empty() {
            return Err("Endpoint credential options must not be empty".into());
        }
        match name {
            "token" | "header_value" => {
                HeaderValue::from_str(value).map_err(|_| "Invalid endpoint credential header value")?;
                if name == "token" && (!value.is_ascii() || value.chars().any(char::is_whitespace)) {
                    return Err("Endpoint bearer token must be ASCII without whitespace".into());
                }
            }
            "query_string" => {
                let query = value.strip_prefix('?').unwrap_or(value);
                if query.is_empty() || query.chars().any(|character| character.is_whitespace() || character.is_control()) || query.contains(['#', '{', '}']) {
                    return Err("Endpoint query_string must be a nonempty encoded query without a fragment".into());
                }
                let parsed = Url::parse(&format!("https://endpoint.invalid/?{query}"))
                    .map_err(|_| "Invalid endpoint query_string")?;
                if parsed.query() != Some(query) {
                    return Err("Endpoint query_string must already be URL-encoded".into());
                }
            }
            _ => return Err("Unsupported endpoint user mapping option; allowed: token, header_value, query_string, secret.<key>".into()),
        }
    }
    Ok(())
}

#[pg_extern(schema = "df")]
pub fn endpoint_option_validator(options: Vec<String>, catalog: pg_sys::Oid) {
    let result = if catalog == pg_sys::ForeignServerRelationId {
        EndpointConfig::from_options(&options).map(|_| ())
    } else if catalog == pg_sys::UserMappingRelationId {
        validate_mapping_options(&options)
    } else if catalog == pg_sys::ForeignDataWrapperRelationId {
        if options.is_empty() {
            Ok(())
        } else {
            Err("pg_durable_fdw does not accept wrapper options".into())
        }
    } else {
        Err("pg_durable_fdw does not support foreign tables or column options".into())
    };
    if let Err(error) = result {
        pgrx::error!("{}", error);
    }
}

pgrx::extension_sql!(
    r#"
CREATE FOREIGN DATA WRAPPER pg_durable_fdw
    NO HANDLER VALIDATOR df.endpoint_option_validator;
REVOKE ALL ON FOREIGN DATA WRAPPER pg_durable_fdw FROM PUBLIC;
"#,
    name = "create_endpoint_fdw",
    requires = [endpoint_option_validator]
);

pub enum EndpointAuth {
    None,
    Bearer(HeaderValue),
    Header {
        name: HeaderName,
        value: HeaderValue,
    },
    Query(String),
}

pub struct ResolvedEndpoint {
    pub base_url: Url,
    pub auth: EndpointAuth,
}

fn resolve_auth(config: AuthScheme, mapping: &[String]) -> Result<EndpointAuth, String> {
    validate_mapping_options(mapping)?;
    let mapping = parse_options(mapping)?;
    match config {
        AuthScheme::None => Ok(EndpointAuth::None),
        AuthScheme::Bearer => {
            let mut value =
                HeaderValue::from_str(&format!("Bearer {}", required(&mapping, "token")?))
                    .map_err(|_| "Invalid endpoint bearer token")?;
            value.set_sensitive(true);
            Ok(EndpointAuth::Bearer(value))
        }
        AuthScheme::Header(name) => {
            let mut value = HeaderValue::from_str(required(&mapping, "header_value")?)
                .map_err(|_| "Invalid endpoint credential header value")?;
            value.set_sensitive(true);
            Ok(EndpointAuth::Header { name, value })
        }
        AuthScheme::Query => {
            let value = required(&mapping, "query_string")?;
            Ok(EndpointAuth::Query(
                value.strip_prefix('?').unwrap_or(value).to_owned(),
            ))
        }
    }
}

struct CatalogServer {
    oid: i64,
    config: EndpointConfig,
    mapping: Option<Vec<String>>,
}

pub struct EndpointCatalog<'a> {
    submitted_by: &'a str,
    database: Option<&'a str>,
    semaphore: &'a Semaphore,
    connection: Option<sqlx::PgConnection>,
    permit: Option<SemaphorePermit<'a>>,
    servers: BTreeMap<String, CatalogServer>,
}

impl<'a> EndpointCatalog<'a> {
    pub fn new(submitted_by: &'a str, semaphore: &'a Semaphore) -> Self {
        Self {
            submitted_by,
            database: None,
            semaphore,
            connection: None,
            permit: None,
            servers: BTreeMap::new(),
        }
    }

    async fn connection(&mut self) -> Result<&mut sqlx::PgConnection, String> {
        if self.connection.is_none() {
            let permit = crate::types::acquire_execution_permit(
                self.semaphore,
                crate::types::get_execution_acquire_timeout(),
                crate::types::get_max_user_connections(),
            )
            .await?;
            let mut connection = crate::types::connect_as_user(self.submitted_by, self.database)
                .await
                .map_err(|error| format!("Endpoint catalog connection failed: {error}"))?;
            sqlx::query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
                .execute(&mut connection)
                .await
                .map_err(|_| "Endpoint catalog snapshot failed")?;
            let identity_matches: bool = sqlx::query_scalar(
                "SELECT CURRENT_USER::pg_catalog.text OPERATOR(pg_catalog.=) $1
                    AND SESSION_USER::pg_catalog.text OPERATOR(pg_catalog.=) $1",
            )
            .bind(self.submitted_by)
            .fetch_one(&mut connection)
            .await
            .map_err(|_| "Endpoint catalog identity check failed")?;
            if !identity_matches {
                return Err(format!(
                    "Endpoint catalog identity differs from submitting role {:?}",
                    self.submitted_by
                ));
            }
            let installed: bool = sqlx::query_scalar(
                "SELECT EXISTS (
                    SELECT 1 FROM pg_catalog.pg_foreign_data_wrapper AS wrapper
                    JOIN pg_catalog.pg_depend AS dependency
                      ON dependency.classid = 'pg_catalog.pg_foreign_data_wrapper'::pg_catalog.regclass
                     AND dependency.objid = wrapper.oid
                     AND dependency.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
                     AND dependency.deptype = 'e'
                    JOIN pg_catalog.pg_extension AS extension ON extension.oid = dependency.refobjid
                    WHERE wrapper.fdwname = $1 AND extension.extname = 'pg_durable'
                )",
            )
            .bind(FDW_NAME)
            .fetch_one(&mut connection)
            .await
            .map_err(|_| "Endpoint wrapper lookup failed")?;
            if !installed {
                return Err(
                    "Endpoint support is not installed; update the pg_durable extension schema"
                        .into(),
                );
            }
            self.connection = Some(connection);
            self.permit = Some(permit);
        }
        Ok(self.connection.as_mut().unwrap())
    }

    async fn load_server(&mut self, server: &str) -> Result<&CatalogServer, String> {
        if !self.servers.contains_key(server) {
            let connection = self
                .connection()
                .await
                .map_err(|error| format!("Endpoint server {server:?}: {error}"))?;
            let endpoint: Option<(i64, bool, bool, Option<Vec<String>>)> = sqlx::query_as(
                "SELECT server.oid::pg_catalog.int8,
                        wrapper.fdwname = $2,
                        pg_catalog.has_server_privilege(server.oid, 'USAGE'),
                        server.srvoptions
                 FROM pg_catalog.pg_foreign_server AS server
                 JOIN pg_catalog.pg_foreign_data_wrapper AS wrapper ON wrapper.oid = server.srvfdw
                 WHERE server.srvname = $1",
            )
            .bind(server)
            .bind(FDW_NAME)
            .fetch_optional(connection)
            .await
            .map_err(|_| "Endpoint server lookup failed")?;
            let (oid, correct_wrapper, permitted, options) =
                endpoint.ok_or("Endpoint server does not exist")?;
            if !correct_wrapper {
                return Err("Endpoint server must use pg_durable_fdw".into());
            }
            if !permitted {
                return Err("Permission denied: endpoint server USAGE is required".into());
            }
            let config = EndpointConfig::from_options(options.as_deref().unwrap_or_default())?;
            self.servers.insert(
                server.to_owned(),
                CatalogServer {
                    oid,
                    config,
                    mapping: None,
                },
            );
        }
        Ok(self.servers.get(server).unwrap())
    }

    async fn load_mapping(&mut self, server: &str) -> Result<&[String], String> {
        let entry = self.load_server(server).await?;
        let oid = entry.oid;
        if entry.mapping.is_none() {
            let mapping = load_user_mapping(self.connection().await?, oid).await?;
            self.servers.get_mut(server).unwrap().mapping = Some(mapping);
        }
        Ok(self
            .servers
            .get(server)
            .unwrap()
            .mapping
            .as_deref()
            .unwrap())
    }

    pub async fn resolve_named_secrets(
        &mut self,
        server: &str,
    ) -> Result<BTreeMap<String, String>, String> {
        let mapping = self.load_mapping(server).await?;
        let options = parse_options(mapping)?;
        Ok(options
            .into_iter()
            .filter_map(|(name, value)| {
                name.strip_prefix(crate::secrets::SECRET_OPTION_PREFIX)
                    .map(|key| (key.to_owned(), value.to_owned()))
            })
            .collect())
    }

    pub async fn resolve_endpoint(&mut self, server: &str) -> Result<ResolvedEndpoint, String> {
        let config = self.load_server(server).await?.config.clone();
        let base_url = config.base_url.ok_or_else(|| {
            format!(
                "Endpoint server {server:?} has no base_url; it can only be used for named secrets"
            )
        })?;
        let auth = if matches!(config.auth_scheme, AuthScheme::None) {
            EndpointAuth::None
        } else {
            resolve_auth(config.auth_scheme, self.load_mapping(server).await?)?
        };
        Ok(ResolvedEndpoint { base_url, auth })
    }

    pub async fn close(mut self) -> Result<(), String> {
        if let Some(connection) = self.connection.take() {
            connection
                .close()
                .await
                .map_err(|_| "Endpoint catalog connection close failed")?;
        }
        drop(self.permit.take());
        Ok(())
    }
}

async fn load_user_mapping(
    connection: &mut sqlx::PgConnection,
    server_oid: i64,
) -> Result<Vec<String>, String> {
    let mapping: Option<Option<Vec<String>>> = sqlx::query_scalar(
        "SELECT mapping.umoptions
             FROM pg_catalog.pg_user_mappings AS mapping
             WHERE mapping.srvid::pg_catalog.int8 = $1
               AND mapping.umuser = (
                   SELECT role.oid FROM pg_catalog.pg_roles AS role
                   WHERE role.rolname = CURRENT_USER
               )",
    )
    .bind(server_oid)
    .fetch_optional(&mut *connection)
    .await
    .map_err(|_| "Endpoint user mapping lookup failed")?;
    let mapping = mapping.ok_or(
            "Endpoint user mapping for the submitting role is required; PUBLIC mappings are unsupported",
        )?;
    let mapping = mapping.ok_or("Endpoint credential options are missing or inaccessible")?;
    validate_mapping_options(&mapping)?;
    Ok(mapping)
}

#[cfg(test)]
mod unit_tests {
    use super::*;

    #[test]
    fn endpoint_named_secret_options_are_opaque() {
        let values = options(&[
            "token=ENDPOINT_TOKEN",
            "secret.api_key=abc==def",
            "secret.empty=",
            "secret.json={\"nested\":123}",
            "secret.token=separate-token",
            "secret.Mixed.Key=literal ${secret:other.key}\nvalue",
        ]);
        validate_mapping_options(&values).unwrap();
        let parsed = parse_options(&values).unwrap();
        assert_eq!(parsed["secret.api_key"], "abc==def");
        assert_eq!(parsed["secret.empty"], "");
        assert_eq!(parsed["secret.json"], r#"{"nested":123}"#);
        for invalid in [
            "secret.=PRIVATE_VALUE",
            "secret.bad\nname=PRIVATE_VALUE",
            "secrets=PRIVATE_VALUE",
            "resource=PRIVATE_VALUE",
        ] {
            let error = validate_mapping_options(&options(&[invalid])).unwrap_err();
            assert!(!error.contains("PRIVATE_VALUE"));
        }
    }

    #[test]
    fn endpoint_execution_context_preserves_legacy_inputs() {
        for input in [
            r#"{"url":"https://api.github.com/{path}","method":"GET","body":"${secret:literal.value}","headers":{"Z":"{last}","A":"$first"},"timeout_seconds":30}"#,
            r#"{"url":"https://api.github.com/upload","method":"POST","parts":[{"name":"file","data_b64":"$payload.body"}],"headers":null,"timeout_seconds":30}"#,
        ] {
            let mut expected: serde_json::Value = serde_json::from_str(input).unwrap();
            expected["submitted_by"] = serde_json::Value::String("caller".into());
            let mut actual: serde_json::Value = serde_json::from_str(input).unwrap();
            set_execution_context(&mut actual, "caller", Some("other_database"));
            assert_eq!(actual.to_string(), expected.to_string());
            assert!(actual.get("database").is_none());
        }
        let mut config = serde_json::json!({"endpoint":"fixed_{server}","url":"/{path}","database":"forged","submitted_by":"forged"});
        set_execution_context(&mut config, "caller", Some("trusted_database"));
        assert_eq!(config["database"], "trusted_database");
        assert_eq!(config["submitted_by"], "caller");
        assert_eq!(config["endpoint"], "fixed_{server}");
        set_execution_context(&mut config, "caller", None);
        assert!(config["database"].is_null());
    }

    #[test]
    fn endpoint_reference_round_trip_and_raw_compatibility() {
        let reference = serde_json::to_string(&EndpointReference {
            kind: "pg_durable.endpoint".into(),
            server: "server.with,\"punctuation".into(),
            path: "/items/{item}?version=1".into(),
        })
        .unwrap();
        let mut config = serde_json::json!({"url": reference, "method": "GET"});
        configure_destination(&mut config, &reference).unwrap();
        assert_eq!(config["endpoint"], "server.with,\"punctuation");
        assert_eq!(config["url"], "/items/{item}?version=1");
        let mut legacy = serde_json::json!({"url": "{host}/data", "body": null});
        let original = legacy.to_string();
        configure_destination(&mut legacy, "{host}/data").unwrap();
        assert_eq!(legacy.to_string(), original);
        assert!(EndpointReference::parse(
            r#"{"type":"pg_durable.endpoint","server":"api","path":"/","extra":true}"#
        )
        .is_err());
    }

    #[test]
    fn endpoint_path_cannot_change_authority_or_escape_prefix() {
        let base = Url::parse("https://api.github.com/prefix/").unwrap();
        assert_eq!(
            compose_endpoint_url(&base, "/items?q=1").unwrap().as_str(),
            "https://api.github.com/prefix/items?q=1"
        );
        for path in [
            "https://evil.test/x",
            "//evil.test/x",
            "/\\evil.test/x",
            "/../escape",
            "/%2e%2e/escape",
            "/.%2E/escape",
            "/%2Fescape",
            "/%5cescape",
            "/data#fragment",
            "/data\n",
        ] {
            assert!(compose_endpoint_url(&base, path).is_err(), "{path}");
        }
    }

    #[test]
    fn endpoint_authentication_cannot_be_overridden() {
        let bearer = || ResolvedEndpoint {
            base_url: Url::parse("https://api.github.com/").unwrap(),
            auth: EndpointAuth::Bearer(HeaderValue::from_static("Bearer PRIVATE_TOKEN")),
        };
        for headers in [
            serde_json::json!({"hOsT":"evil.test"}),
            serde_json::json!({"authorization":"other"}),
        ] {
            assert!(prepare_endpoint_request(bearer(), "/", Some(&headers)).is_err());
        }
        let request = prepare_endpoint_request(bearer(), "/", None).unwrap();
        let (name, value) = request.credential_header.unwrap();
        let built = reqwest::Client::builder()
            .no_proxy()
            .build()
            .unwrap()
            .get(request.url)
            .header(name, value)
            .build()
            .unwrap();
        assert_eq!(built.headers()[AUTHORIZATION], "Bearer PRIVATE_TOKEN");
        let query = || ResolvedEndpoint {
            base_url: Url::parse("https://api.github.com/").unwrap(),
            auth: EndpointAuth::Query("sig=PRIVATE%2BVALUE&sv=1".into()),
        };
        assert!(prepare_endpoint_request(query(), "/?%73ig=override", None).is_err());
        let request = prepare_endpoint_request(query(), "/?page=2", None).unwrap();
        assert_eq!(request.url.query(), Some("page=2&sig=PRIVATE%2BVALUE&sv=1"));
        assert!(!crate::redact::redact_url(request.url.as_str()).contains("PRIVATE"));
    }

    fn options(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn endpoint_valid_options() {
        let secrets_only = EndpointConfig::from_options(&options(&["auth_scheme=none"])).unwrap();
        assert!(secrets_only.base_url.is_none());
        assert!(matches!(secrets_only.auth_scheme, AuthScheme::None));
        for scheme in ["none", "bearer", "query"] {
            assert!(EndpointConfig::from_options(&options(&[
                "base_url=https://api.github.com/v1",
                &format!("auth_scheme={scheme}")
            ]))
            .is_ok());
        }
        assert!(EndpointConfig::from_options(&options(&[
            "base_url=https://api.github.com",
            "auth_scheme=header",
            "header_name=x-api-key"
        ]))
        .is_ok());
        assert!(validate_mapping_options(&options(&["token=secret=="])).is_ok());
        assert!(
            validate_mapping_options(&options(&["query_string=?sig=abc%2Fdef%3D&sv=1"])).is_ok()
        );
    }

    #[test]
    fn endpoint_rejects_invalid_server_options() {
        for invalid in [
            vec![],
            vec!["auth_scheme=bearer"],
            vec!["auth_scheme=query"],
            vec!["auth_scheme=header", "header_name=x-api-key"],
            vec!["auth_scheme=none", "base_url="],
            vec!["auth_scheme=none", "base_url=not-a-url"],
            vec!["auth_scheme=none", "header_name=x-api-key"],
            vec!["base_url=https://api.github.com"],
            vec!["base_url=http://api.github.com", "auth_scheme=none"],
            vec![
                "base_url=https://user:secret@api.github.com",
                "auth_scheme=none",
            ],
            vec![
                "base_url=https://api.github.com/?secret=value",
                "auth_scheme=none",
            ],
            vec![
                "base_url=https://api.github.com/#secret",
                "auth_scheme=none",
            ],
            vec!["base_url=https://{host}", "auth_scheme=none"],
            vec![
                "base_url=https://api.github.com",
                "auth_scheme=managed-identity",
            ],
            vec![
                "base_url=https://api.github.com",
                "auth_scheme=none",
                "resource=https://vault.azure.net",
            ],
            vec![
                "base_url=https://api.github.com",
                "auth_scheme=none",
                "header_name=x-api-key",
            ],
            vec![
                "base_url=https://api.github.com",
                "auth_scheme=header",
                "header_name=Host",
            ],
            vec!["base_url=https://api.github.com", "auth_scheme=header"],
            vec![
                "base_url=https://api.github.com",
                "auth_scheme=none",
                "auth_scheme=bearer",
            ],
        ] {
            assert!(
                EndpointConfig::from_options(&options(&invalid)).is_err(),
                "{invalid:?}"
            );
        }
    }

    #[test]
    fn endpoint_invalid_credentials_do_not_leak() {
        for invalid in [
            "token=TOP_SECRET\r\nInjected: true",
            "header_value=TOP_SECRET\n",
            "query_string=TOP_SECRET#fragment",
            "query_string=TOP_SECRET value",
            "unknown=TOP_SECRET",
            "token=",
            "query_string=?",
        ] {
            let error = validate_mapping_options(&options(&[invalid])).unwrap_err();
            assert!(!error.contains("TOP_SECRET"));
        }
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use super::*;

    async fn resolve_endpoint(
        submitted_by: &str,
        database: Option<&str>,
        server: &str,
    ) -> Result<ResolvedEndpoint, String> {
        let semaphore = Semaphore::new(1);
        let mut catalog = EndpointCatalog::new(submitted_by, &semaphore);
        catalog.database = database;
        let endpoint = catalog.resolve_endpoint(server).await?;
        catalog.close().await?;
        Ok(endpoint)
    }

    async fn resolve_named_secrets(
        submitted_by: &str,
        database: Option<&str>,
        server: &str,
    ) -> Result<BTreeMap<String, String>, String> {
        let semaphore = Semaphore::new(1);
        let mut catalog = EndpointCatalog::new(submitted_by, &semaphore);
        catalog.database = database;
        let values = catalog.resolve_named_secrets(server).await?;
        catalog.close().await?;
        Ok(values)
    }

    #[pg_test]
    fn endpoint_catalog_snapshot_and_admission() {
        use std::future::Future;
        use std::task::Poll;

        let admin = Spi::get_one::<String>("SELECT CURRENT_USER::text")
            .unwrap()
            .unwrap();
        let database = Spi::get_one::<String>("SELECT current_database()::text")
            .unwrap()
            .unwrap();
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
            let mut connection = crate::types::connect_as_user(&admin, Some(&database)).await.unwrap();
            sqlx::raw_sql(r#"
                CREATE ROLE endpoint_snapshot_user LOGIN;
                CREATE SERVER endpoint_snapshot FOREIGN DATA WRAPPER pg_durable_fdw
                    OPTIONS (base_url 'https://old.azurewebsites.net', auth_scheme 'bearer');
                CREATE SERVER endpoint_snapshot_other FOREIGN DATA WRAPPER pg_durable_fdw
                    OPTIONS (auth_scheme 'none');
                GRANT USAGE ON FOREIGN SERVER endpoint_snapshot, endpoint_snapshot_other TO endpoint_snapshot_user;
                CREATE USER MAPPING FOR endpoint_snapshot_user SERVER endpoint_snapshot
                    OPTIONS (token 'OLD_TOKEN', "secret.generation" 'OLD_NAMED');
                CREATE USER MAPPING FOR endpoint_snapshot_user SERVER endpoint_snapshot_other
                    OPTIONS ("secret.generation" 'OLD_OTHER');
            "#).execute(&mut connection).await.unwrap();

            let semaphore = Semaphore::new(1);
            let occupied = crate::types::acquire_execution_permit(
                &semaphore, std::time::Duration::from_secs(30), 1,
            ).await.unwrap();
            let mut catalog = EndpointCatalog::new("endpoint_snapshot_user", &semaphore);
            catalog.database = Some(&database);
            {
                let waiting = catalog.load_server("endpoint_snapshot");
                tokio::pin!(waiting);
                std::future::poll_fn(|context| {
                    assert!(waiting.as_mut().poll(context).is_pending());
                    Poll::Ready(())
                }).await;
                let connected: i64 = sqlx::query_scalar(
                    "SELECT count(*) FROM pg_catalog.pg_stat_activity WHERE usename = 'endpoint_snapshot_user'",
                ).fetch_one(&mut connection).await.unwrap();
                assert_eq!(connected, 0);
                drop(occupied);
                assert_eq!(waiting.await.unwrap().config.base_url.as_ref().unwrap().as_str(), "https://old.azurewebsites.net/");
            }
            assert_eq!(semaphore.available_permits(), 0);
            let settings: (String, String) = sqlx::query_as(
                "SELECT current_setting('transaction_isolation'), current_setting('transaction_read_only')",
            ).fetch_one(catalog.connection().await.unwrap()).await.unwrap();
            assert_eq!(settings, ("repeatable read".into(), "on".into()));
            sqlx::raw_sql(r#"
                BEGIN;
                ALTER SERVER endpoint_snapshot OPTIONS (SET base_url 'https://new.azurewebsites.net');
                ALTER USER MAPPING FOR endpoint_snapshot_user SERVER endpoint_snapshot
                    OPTIONS (SET token 'NEW_TOKEN', SET "secret.generation" 'NEW_NAMED');
                ALTER USER MAPPING FOR endpoint_snapshot_user SERVER endpoint_snapshot_other
                    OPTIONS (SET "secret.generation" 'NEW_OTHER');
                COMMIT;
            "#).execute(&mut connection).await.unwrap();

            let endpoint = catalog.resolve_endpoint("endpoint_snapshot").await.unwrap();
            assert_eq!(endpoint.base_url.as_str(), "https://old.azurewebsites.net/");
            assert!(matches!(endpoint.auth, EndpointAuth::Bearer(value) if value == "Bearer OLD_TOKEN"));
            assert_eq!(catalog.resolve_named_secrets("endpoint_snapshot").await.unwrap()["generation"], "OLD_NAMED");
            assert_eq!(catalog.resolve_named_secrets("endpoint_snapshot_other").await.unwrap()["generation"], "OLD_OTHER");
            let connected: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM pg_catalog.pg_stat_activity WHERE usename = 'endpoint_snapshot_user'",
            ).fetch_one(&mut connection).await.unwrap();
            assert_eq!(connected, 1);
            for multipart in [false, true] {
                let mut binding_options = serde_json::json!({
                    "secret_bindings": {
                        "headers": {"X-Generation": {"server": "endpoint_snapshot", "key": "generation"}},
                        "query": {"generation": {"server": "endpoint_snapshot_other", "key": "generation"}}
                    }
                });
                if !multipart {
                    binding_options["secret_bindings"]["form"] = serde_json::json!({
                        "generation": {"server": "endpoint_snapshot", "key": "generation"}
                    });
                }
                let options: crate::secrets::SecretOptions = serde_json::from_value(binding_options).unwrap();
                options.validate(false, "POST", multipart, None).unwrap();
                let mut request = prepare_request(&mut catalog, Some("endpoint_snapshot"), "/items", None).await.unwrap();
                let resolved = options.resolve(&mut catalog, &mut request, None).await.unwrap();
                assert_eq!(request.url.host_str(), Some("old.azurewebsites.net"));
                assert_eq!(request.credential_header.as_ref().unwrap().1, "Bearer OLD_TOKEN");
                assert_eq!(resolved.headers["x-generation"], "OLD_NAMED");
                assert_eq!(request.url.query(), Some("generation=OLD_OTHER"));
                assert_eq!(resolved.form_body.as_deref(), if multipart { None } else { Some("generation=OLD_NAMED") });
            }
            catalog.close().await.unwrap();
            assert_eq!(semaphore.available_permits(), 1);

            let mut next = EndpointCatalog::new("endpoint_snapshot_user", &semaphore);
            next.database = Some(&database);
            let endpoint = next.resolve_endpoint("endpoint_snapshot").await.unwrap();
            assert_eq!(endpoint.base_url.as_str(), "https://new.azurewebsites.net/");
            assert!(matches!(endpoint.auth, EndpointAuth::Bearer(value) if value == "Bearer NEW_TOKEN"));
            assert_eq!(next.resolve_named_secrets("endpoint_snapshot").await.unwrap()["generation"], "NEW_NAMED");
            assert_eq!(next.resolve_named_secrets("endpoint_snapshot_other").await.unwrap()["generation"], "NEW_OTHER");
            drop(next);
            assert_eq!(semaphore.available_permits(), 1);

            let occupied = semaphore.acquire().await.unwrap();
            let mut unused = EndpointCatalog::new("endpoint_snapshot_user", &semaphore);
            let mut request = prepare_request(&mut unused, None, "https://api.github.com/", None).await.unwrap();
            let options: crate::secrets::SecretOptions = serde_json::from_value(
                serde_json::json!({"form_fields":{"literal":"$result"}}),
            ).unwrap();
            let resolved = options.resolve(&mut unused, &mut request, None).await.unwrap();
            assert_eq!(resolved.form_body.as_deref(), Some("literal=%24result"));
            assert!(unused.connection.is_none());
            unused.close().await.unwrap();
            drop(occupied);

            {
                let mut failed = EndpointCatalog::new("endpoint_snapshot_user", &semaphore);
                failed.database = Some(&database);
                assert!(failed.resolve_endpoint("endpoint_snapshot_missing").await.is_err());
            }
            assert_eq!(semaphore.available_permits(), 1);
            sqlx::raw_sql(r#"
                DROP SERVER endpoint_snapshot, endpoint_snapshot_other CASCADE;
                DROP ROLE endpoint_snapshot_user;
            "#).execute(&mut connection).await.unwrap();
        });
    }

    #[pg_test]
    fn endpoint_helper_is_lookup_free() {
        let reference = endpoint("missing_server", "/items/{item}");
        let decoded: serde_json::Value = serde_json::from_str(&reference).unwrap();
        assert_eq!(decoded["type"], "pg_durable.endpoint");
        assert_eq!(decoded["server"], "missing_server");
        assert_eq!(decoded["path"], "/items/{item}");
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains",
        feature = "http-allow-all"
    ))]
    #[pg_test]
    fn endpoint_constructors_preserve_body_and_node_types() {
        let destination = endpoint("missing_server", "/items/{item}");
        let http = crate::dsl::http(
            &destination,
            "POST",
            Some("${secret:literal.value}"),
            None,
            30,
        );
        let multipart = crate::dsl::http_multipart(
            &destination,
            "POST",
            Some(pgrx::JsonB(
                serde_json::json!([{"name":"file","data_b64":"aGVsbG8="}]),
            )),
            None,
            30,
        );
        for (json, node_type) in [(http, "HTTP"), (multipart, "HTTP_MULTIPART")] {
            let node = crate::types::Durofut::from_json(&json);
            assert_eq!(node.node_type, node_type);
            let config: serde_json::Value =
                serde_json::from_str(node.query.as_ref().unwrap()).unwrap();
            assert_eq!(config["endpoint"], "missing_server");
            assert_eq!(config["url"], "/items/{item}");
            if node_type == "HTTP" {
                assert_eq!(config["body"], "${secret:literal.value}");
            }
        }
    }

    #[pg_test]
    fn endpoint_catalog_permissions() {
        let admin = Spi::get_one::<String>("SELECT CURRENT_USER::text")
            .unwrap()
            .unwrap();
        let database = Spi::get_one::<String>("SELECT pg_catalog.current_database()::text")
            .unwrap()
            .unwrap();
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let mut connection = crate::types::connect_as_user(&admin, Some(&database))
                    .await
                    .unwrap();
                sqlx::raw_sql(
                    r#"
                    DROP ROLE IF EXISTS "endpoint Alice", endpoint_bob;
                    CREATE ROLE "endpoint Alice" LOGIN;
                    CREATE ROLE endpoint_bob LOGIN;
                    SELECT df.grant_usage('endpoint Alice');
                    SELECT df.grant_usage('endpoint_bob');
                    CREATE SERVER endpoint_test FOREIGN DATA WRAPPER pg_durable_fdw
                        OPTIONS (base_url 'https://api.github.com', auth_scheme 'bearer');
                    GRANT USAGE ON FOREIGN SERVER endpoint_test TO "endpoint Alice", endpoint_bob;
                    GRANT USAGE ON FOREIGN DATA WRAPPER pg_durable_fdw TO "endpoint Alice";
                    CREATE SERVER endpoint_none FOREIGN DATA WRAPPER pg_durable_fdw
                        OPTIONS (auth_scheme 'none');
                    GRANT USAGE ON FOREIGN SERVER endpoint_none TO "endpoint Alice";
                    CREATE FOREIGN DATA WRAPPER endpoint_other_fdw;
                    CREATE SERVER endpoint_other FOREIGN DATA WRAPPER endpoint_other_fdw;
                    GRANT USAGE ON FOREIGN SERVER endpoint_other TO "endpoint Alice";
                    "#,
                )
                .execute(&mut connection)
                .await
                .unwrap();
                let mut alice = crate::types::connect_as_user("endpoint Alice", Some(&database))
                    .await
                    .unwrap();
                let mut bob = crate::types::connect_as_user("endpoint_bob", Some(&database))
                    .await
                    .unwrap();

                let error = resolve_endpoint("endpoint Alice", Some("endpoint_missing_database"), "endpoint_test")
                    .await.err().unwrap();
                assert!(error.contains("Endpoint catalog connection failed"));
                assert!(error.contains("endpoint_test"));
                assert!(error.contains("endpoint_missing_database"));
                assert!(error.contains("endpoint Alice"));
                assert!(error.contains("does not exist"));

                for statement in [
                    "CREATE SERVER endpoint_invalid FOREIGN DATA WRAPPER pg_durable_fdw OPTIONS (base_url 'https://api.github.com', auth_scheme 'managed-identity')",
                    "CREATE SERVER endpoint_invalid FOREIGN DATA WRAPPER pg_durable_fdw OPTIONS (base_url 'https://api.github.com', auth_scheme 'none', scope 'TOP_SECRET')",
                    "CREATE SERVER endpoint_invalid FOREIGN DATA WRAPPER pg_durable_fdw OPTIONS (base_url 'https://api.github.com?key=TOP_SECRET', auth_scheme 'none')",
                    "CREATE USER MAPPING FOR CURRENT_USER SERVER endpoint_test OPTIONS (header_value E'TOP_SECRET\\r\\n')",
                    "CREATE USER MAPPING FOR CURRENT_USER SERVER endpoint_test OPTIONS (unknown 'TOP_SECRET')",
                ] {
                    let error = sqlx::raw_sql(statement).execute(&mut alice).await.unwrap_err();
                    assert!(!error.to_string().contains("TOP_SECRET"));
                }

                sqlx::raw_sql(
                    "CREATE USER MAPPING FOR CURRENT_USER SERVER endpoint_test OPTIONS (token 'ALICE_TOKEN==');
                     CREATE SERVER endpoint_owned FOREIGN DATA WRAPPER pg_durable_fdw OPTIONS (base_url 'https://api.github.com', auth_scheme 'none');
                     ALTER SERVER endpoint_owned OPTIONS (ADD header_name 'x-api-key', SET auth_scheme 'header');",
                )
                .execute(&mut alice)
                .await
                .unwrap();
                assert!(sqlx::raw_sql("ALTER SERVER endpoint_owned OPTIONS (DROP header_name)")
                    .execute(&mut alice).await.is_err());
                assert!(sqlx::raw_sql("ALTER SERVER endpoint_owned OPTIONS (DROP base_url)")
                    .execute(&mut alice).await.is_err());
                assert!(sqlx::raw_sql("CREATE FOREIGN TABLE endpoint_table (value text) SERVER endpoint_owned")
                    .execute(&mut alice).await.is_err());

                sqlx::raw_sql("CREATE USER MAPPING FOR CURRENT_USER SERVER endpoint_test OPTIONS (token 'BOB_TOKEN')")
                    .execute(&mut bob).await.unwrap();
                let visible: bool = sqlx::query_scalar(
                    "SELECT umoptions IS NOT NULL FROM pg_catalog.pg_user_mappings WHERE srvname = 'endpoint_test' AND usename = CURRENT_USER",
                ).fetch_one(&mut alice).await.unwrap();
                assert!(visible);
                let peer_visible: bool = sqlx::query_scalar(
                    "SELECT umoptions IS NOT NULL FROM pg_catalog.pg_user_mappings WHERE srvname = 'endpoint_test' AND usename = 'endpoint_bob'",
                ).fetch_one(&mut alice).await.unwrap();
                assert!(!peer_visible);

                let resolved = resolve_endpoint("endpoint Alice", Some(&database), "endpoint_test").await.unwrap();
                assert_eq!(resolved.base_url.as_str(), "https://api.github.com/");
                match resolved.auth {
                    EndpointAuth::Bearer(value) => {
                        assert_eq!(value, "Bearer ALICE_TOKEN==");
                        assert!(value.is_sensitive());
                    }
                    _ => panic!("Expected bearer authentication"),
                }
                let resolved = resolve_endpoint("endpoint_bob", Some(&database), "endpoint_test").await.unwrap();
                assert!(matches!(resolved.auth, EndpointAuth::Bearer(value) if value == "Bearer BOB_TOKEN"));

                sqlx::raw_sql(r#"ALTER ROLE "endpoint Alice" NOINHERIT;
                    GRANT endpoint_bob TO "endpoint Alice";
                    ALTER ROLE "endpoint Alice" SET role = 'endpoint_bob';"#)
                    .execute(&mut connection).await.unwrap();
                let mut changed_identity = crate::types::connect_as_user("endpoint Alice", Some(&database))
                    .await.unwrap();
                let effective_role: String = sqlx::query_scalar("SELECT CURRENT_USER::text")
                    .fetch_one(&mut changed_identity).await.unwrap();
                assert_eq!(effective_role, "endpoint_bob");
                drop(changed_identity);
                for error in [
                    resolve_endpoint("endpoint Alice", Some(&database), "endpoint_test").await.err().unwrap(),
                    resolve_named_secrets("endpoint Alice", Some(&database), "endpoint_test").await.err().unwrap(),
                ] {
                    assert!(error.contains("identity differs from submitting role"));
                    assert!(!error.contains("BOB_TOKEN"));
                }
                sqlx::raw_sql(r#"ALTER ROLE "endpoint Alice" RESET role;
                    REVOKE endpoint_bob FROM "endpoint Alice";
                    ALTER ROLE "endpoint Alice" INHERIT;"#)
                    .execute(&mut connection).await.unwrap();

                sqlx::raw_sql("ALTER USER MAPPING FOR CURRENT_USER SERVER endpoint_test OPTIONS (SET token 'ROTATED_TOKEN')")
                    .execute(&mut alice).await.unwrap();
                let resolved = resolve_endpoint("endpoint Alice", Some(&database), "endpoint_test").await.unwrap();
                assert!(matches!(resolved.auth, EndpointAuth::Bearer(value) if value == "Bearer ROTATED_TOKEN"));

                sqlx::raw_sql(r#"ALTER USER MAPPING FOR CURRENT_USER SERVER endpoint_test OPTIONS (ADD "secret.key" 'ALICE_SECRET', ADD "secret.empty" '', ADD "secret.token" 'NAMED_TOKEN')"#)
                    .execute(&mut alice).await.unwrap();
                sqlx::raw_sql(r#"ALTER USER MAPPING FOR CURRENT_USER SERVER endpoint_test OPTIONS (ADD "secret.key" 'BOB_SECRET')"#)
                    .execute(&mut bob).await.unwrap();
                let values = resolve_named_secrets("endpoint Alice", Some(&database), "endpoint_test").await.unwrap();
                assert_eq!(values["key"], "ALICE_SECRET");
                assert_eq!(values["empty"], "");
                assert_eq!(values["token"], "NAMED_TOKEN");
                assert_eq!(resolve_named_secrets("endpoint_bob", Some(&database), "endpoint_test").await.unwrap()["key"], "BOB_SECRET");
                sqlx::raw_sql(r#"ALTER USER MAPPING FOR CURRENT_USER SERVER endpoint_test OPTIONS (ADD "secret.Mixed.Key" 'abc=={"nested":true}')"#)
                    .execute(&mut alice).await.unwrap();
                let values = resolve_named_secrets("endpoint Alice", Some(&database), "endpoint_test").await.unwrap();
                assert_eq!(values["key"], "ALICE_SECRET");
                assert_eq!(values["Mixed.Key"], "abc=={\"nested\":true}");
                sqlx::raw_sql(r#"ALTER USER MAPPING FOR CURRENT_USER SERVER endpoint_test OPTIONS (SET "secret.key" 'ROTATED_SECRET', DROP "secret.Mixed.Key")"#)
                    .execute(&mut alice).await.unwrap();
                let values = resolve_named_secrets("endpoint Alice", Some(&database), "endpoint_test").await.unwrap();
                assert_eq!(values["key"], "ROTATED_SECRET");
                assert_eq!(values["empty"], "");
                assert_eq!(values["token"], "NAMED_TOKEN");
                assert!(!values.contains_key("Mixed.Key"));
                let resolved = resolve_endpoint("endpoint Alice", Some(&database), "endpoint_test").await.unwrap();
                assert!(matches!(resolved.auth, EndpointAuth::Bearer(value) if value == "Bearer ROTATED_TOKEN"));
                for statement in [
                    r#"ALTER USER MAPPING FOR CURRENT_USER SERVER endpoint_test OPTIONS (ADD "secret." 'DO_NOT_ECHO')"#,
                    r#"ALTER USER MAPPING FOR CURRENT_USER SERVER endpoint_test OPTIONS (ADD secrets '{"key":"DO_NOT_ECHO"}')"#,
                    r#"ALTER USER MAPPING FOR CURRENT_USER SERVER endpoint_test OPTIONS (ADD scope 'DO_NOT_ECHO')"#,
                    r#"ALTER SERVER endpoint_owned OPTIONS (ADD "secret.key" 'DO_NOT_ECHO')"#,
                ] {
                    let error = sqlx::raw_sql(statement).execute(&mut alice).await.unwrap_err();
                    assert!(!error.to_string().contains("DO_NOT_ECHO"));
                }

                sqlx::raw_sql("REVOKE USAGE ON FOREIGN SERVER endpoint_test FROM \"endpoint Alice\"")
                    .execute(&mut connection).await.unwrap();
                let error = resolve_endpoint("endpoint Alice", Some(&database), "endpoint_test").await.err().unwrap();
                assert!(error.contains("USAGE"));
                assert!(resolve_named_secrets("endpoint Alice", Some(&database), "endpoint_test").await.err().unwrap().contains("USAGE"));
                sqlx::raw_sql("GRANT USAGE ON FOREIGN SERVER endpoint_test TO \"endpoint Alice\"")
                    .execute(&mut connection).await.unwrap();
                sqlx::raw_sql("DROP USER MAPPING FOR CURRENT_USER SERVER endpoint_test")
                    .execute(&mut alice).await.unwrap();
                sqlx::raw_sql("CREATE USER MAPPING FOR PUBLIC SERVER endpoint_test OPTIONS (token 'PUBLIC_TOKEN')")
                    .execute(&mut connection).await.unwrap();
                let error = resolve_endpoint("endpoint Alice", Some(&database), "endpoint_test").await.err().unwrap();
                assert!(error.contains("PUBLIC mappings are unsupported"));

                sqlx::raw_sql("CREATE USER MAPPING FOR CURRENT_USER SERVER endpoint_test")
                    .execute(&mut alice).await.unwrap();
                let error = resolve_endpoint("endpoint Alice", Some(&database), "endpoint_test").await.err().unwrap();
                assert!(error.contains("missing or inaccessible"));

                sqlx::raw_sql("CREATE USER MAPPING FOR CURRENT_USER SERVER endpoint_owned OPTIONS (header_value 'HEADER_TOKEN')")
                    .execute(&mut alice).await.unwrap();
                let resolved = resolve_endpoint("endpoint Alice", Some(&database), "endpoint_owned").await.unwrap();
                assert!(matches!(resolved.auth, EndpointAuth::Header { name, value } if name == "x-api-key" && value == "HEADER_TOKEN" && value.is_sensitive()));
                sqlx::raw_sql(
                    "ALTER SERVER endpoint_owned OPTIONS (SET auth_scheme 'query', DROP header_name);
                     ALTER USER MAPPING FOR CURRENT_USER SERVER endpoint_owned OPTIONS (DROP header_value, ADD query_string '?sig=abc%2Fdef%3D&sv=1');",
                ).execute(&mut alice).await.unwrap();
                let resolved = resolve_endpoint("endpoint Alice", Some(&database), "endpoint_owned").await.unwrap();
                assert!(matches!(resolved.auth, EndpointAuth::Query(value) if value == "sig=abc%2Fdef%3D&sv=1"));
                sqlx::raw_sql("ALTER SERVER endpoint_owned OPTIONS (SET auth_scheme 'bearer')")
                    .execute(&mut alice).await.unwrap();
                assert!(resolve_endpoint("endpoint Alice", Some(&database), "endpoint_owned").await.err().unwrap().contains("'token' is required"));
                let error = resolve_endpoint("endpoint Alice", Some(&database), "endpoint_none").await.err().unwrap();
                assert!(error.contains("has no base_url"));
                assert!(error.contains("endpoint_none"));
                assert!(resolve_named_secrets("endpoint Alice", Some(&database), "endpoint_none").await.err().unwrap().contains("mapping for the submitting role is required"));
                sqlx::raw_sql(r#"CREATE USER MAPPING FOR CURRENT_USER SERVER endpoint_none OPTIONS ("secret.key" 'NONE_SECRET')"#)
                    .execute(&mut alice).await.unwrap();
                assert_eq!(resolve_named_secrets("endpoint Alice", Some(&database), "endpoint_none").await.unwrap()["key"], "NONE_SECRET");
                assert!(resolve_named_secrets("endpoint_bob", Some(&database), "endpoint_none").await.err().unwrap().contains("USAGE"));
                for statement in [
                    "ALTER SERVER endpoint_none OPTIONS (SET auth_scheme 'bearer')",
                    "ALTER SERVER endpoint_none OPTIONS (ADD base_url 'http://api.github.com')",
                    "ALTER SERVER endpoint_none OPTIONS (ADD base_url '')",
                ] {
                    assert!(sqlx::raw_sql(statement).execute(&mut connection).await.is_err());
                }
                sqlx::raw_sql("ALTER SERVER endpoint_none OPTIONS (ADD base_url 'https://api.github.com')")
                    .execute(&mut connection).await.unwrap();
                let resolved = resolve_endpoint("endpoint Alice", Some(&database), "endpoint_none").await.unwrap();
                assert_eq!(resolved.base_url.as_str(), "https://api.github.com/");
                assert!(matches!(resolved.auth, EndpointAuth::None));
                sqlx::raw_sql("ALTER SERVER endpoint_none OPTIONS (DROP base_url)")
                    .execute(&mut connection).await.unwrap();
                assert_eq!(resolve_named_secrets("endpoint Alice", Some(&database), "endpoint_none").await.unwrap()["key"], "NONE_SECRET");
                assert!(resolve_endpoint("endpoint Alice", Some(&database), "endpoint_missing").await.err().unwrap().contains("does not exist"));
                assert!(resolve_endpoint("endpoint Alice", Some(&database), "endpoint_other").await.err().unwrap().contains("must use pg_durable_fdw"));

                sqlx::raw_sql("ALTER EXTENSION pg_durable DROP FOREIGN DATA WRAPPER pg_durable_fdw")
                    .execute(&mut connection).await.unwrap();
                assert!(resolve_endpoint("endpoint Alice", Some(&database), "endpoint_none").await.err().unwrap().contains("update the pg_durable extension schema"));
                sqlx::raw_sql("ALTER EXTENSION pg_durable ADD FOREIGN DATA WRAPPER pg_durable_fdw")
                    .execute(&mut connection).await.unwrap();

                drop(alice);
                drop(bob);
                sqlx::raw_sql(
                    r#"
                    DROP SERVER endpoint_test, endpoint_none, endpoint_owned, endpoint_other CASCADE;
                    DROP FOREIGN DATA WRAPPER endpoint_other_fdw;
                    DROP OWNED BY "endpoint Alice", endpoint_bob;
                    DROP ROLE "endpoint Alice", endpoint_bob;
                    "#,
                ).execute(&mut connection).await.unwrap();
            });
    }
}
