use std::collections::BTreeMap;

use pgrx::prelude::*;
use reqwest::header::{HeaderName, HeaderValue};
use url::Url;

pub const FDW_NAME: &str = "pg_durable_fdw";

pub enum AuthScheme {
    None,
    Bearer,
    Header(HeaderName),
    Query,
}

pub struct EndpointConfig {
    pub base_url: Url,
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
        Ok(Self {
            base_url,
            auth_scheme,
        })
    }
}

fn validate_mapping_options(options: &[String]) -> Result<(), String> {
    let options = parse_options(options)?;
    for (name, value) in options {
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
            _ => return Err("Unsupported endpoint user mapping option; allowed: token, header_value, query_string".into()),
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

pub async fn resolve_endpoint(
    submitted_by: &str,
    database: Option<&str>,
    server: &str,
) -> Result<ResolvedEndpoint, String> {
    let mut connection = crate::types::connect_as_user(submitted_by, database)
        .await
        .map_err(|_| "Endpoint catalog connection failed")?;
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
            "Endpoint support is not installed; update the pg_durable extension schema".into(),
        );
    }

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
    .fetch_optional(&mut connection)
    .await
    .map_err(|_| "Endpoint server lookup failed")?;
    let (server_oid, correct_wrapper, permitted, options) =
        endpoint.ok_or("Endpoint server does not exist")?;
    if !correct_wrapper {
        return Err("Endpoint server must use pg_durable_fdw".into());
    }
    if !permitted {
        return Err("Permission denied: endpoint server USAGE is required".into());
    }
    let config = EndpointConfig::from_options(options.as_deref().unwrap_or_default())?;
    let auth = if matches!(config.auth_scheme, AuthScheme::None) {
        EndpointAuth::None
    } else {
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
        .fetch_optional(&mut connection)
        .await
        .map_err(|_| "Endpoint user mapping lookup failed")?;
        let mapping = mapping.ok_or(
            "Endpoint user mapping for the submitting role is required; PUBLIC mappings are unsupported",
        )?;
        let mapping = mapping.ok_or("Endpoint credential options are missing or inaccessible")?;
        resolve_auth(config.auth_scheme, &mapping)?
    };
    Ok(ResolvedEndpoint {
        base_url: config.base_url,
        auth,
    })
}

#[cfg(test)]
mod unit_tests {
    use super::*;

    fn options(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn endpoint_valid_options() {
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
                        OPTIONS (base_url 'https://api.github.com', auth_scheme 'none');
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

                sqlx::raw_sql("ALTER USER MAPPING FOR CURRENT_USER SERVER endpoint_test OPTIONS (SET token 'ROTATED_TOKEN')")
                    .execute(&mut alice).await.unwrap();
                let resolved = resolve_endpoint("endpoint Alice", Some(&database), "endpoint_test").await.unwrap();
                assert!(matches!(resolved.auth, EndpointAuth::Bearer(value) if value == "Bearer ROTATED_TOKEN"));

                sqlx::raw_sql("REVOKE USAGE ON FOREIGN SERVER endpoint_test FROM \"endpoint Alice\"")
                    .execute(&mut connection).await.unwrap();
                let error = resolve_endpoint("endpoint Alice", Some(&database), "endpoint_test").await.err().unwrap();
                assert!(error.contains("USAGE"));
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
                let resolved = resolve_endpoint("endpoint Alice", Some(&database), "endpoint_none").await.unwrap();
                assert!(matches!(resolved.auth, EndpointAuth::None));
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
