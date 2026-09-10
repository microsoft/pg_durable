use std::collections::{BTreeMap, BTreeSet};

use pgrx::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const SECRET_OPTION_PREFIX: &str = "secret.";

pub fn validate_secret_key(key: &str) -> Result<(), String> {
    if key.is_empty() || key.contains('=') || key.chars().any(char::is_control) {
        return Err("Secret keys must be nonempty without control characters or '='".into());
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SecretReference {
    pub server: String,
    pub key: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub prefix: String,
}

impl SecretReference {
    fn validate(&self) -> Result<(), String> {
        if self.server.is_empty() || self.server.chars().any(char::is_control) {
            return Err(
                "Secret references require a nonempty server name without control characters"
                    .into(),
            );
        }
        validate_secret_key(&self.key)
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SecretBindings {
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub headers: BTreeMap<String, SecretReference>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub query: BTreeMap<String, SecretReference>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub form: BTreeMap<String, SecretReference>,
}

pub(crate) fn credential_header_name(name: &str) -> Result<reqwest::header::HeaderName, String> {
    let name = reqwest::header::HeaderName::from_bytes(name.as_bytes())
        .map_err(|_| "Invalid credential header name")?;
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
        return Err("Credential headers cannot control HTTP routing or framing".into());
    }
    Ok(name)
}

impl SecretBindings {
    pub fn validate(&self) -> Result<(), String> {
        let mut headers = BTreeSet::new();
        for (name, reference) in &self.headers {
            reference.validate()?;
            let name = credential_header_name(name)?;
            if !headers.insert(name.as_str().to_owned()) {
                return Err("Duplicate secret header binding (case-insensitive)".into());
            }
            reqwest::header::HeaderValue::from_str(&reference.prefix)
                .map_err(|_| "Invalid secret header prefix")?;
        }
        for (name, reference) in self.query.iter().chain(&self.form) {
            reference.validate()?;
            if name.is_empty() || name.chars().any(char::is_control) {
                return Err(
                    "Secret field names must be nonempty without control characters".into(),
                );
            }
            if !reference.prefix.is_empty() {
                return Err("Secret prefixes are supported only in header bindings".into());
            }
        }
        Ok(())
    }
}

#[pg_extern(schema = "df", immutable, parallel_safe)]
pub fn secret(server: &str, key: &str) -> pgrx::JsonB {
    let reference = SecretReference {
        server: server.into(),
        key: key.into(),
        prefix: String::new(),
    };
    reference
        .validate()
        .unwrap_or_else(|error| pgrx::error!("{}", error));
    pgrx::JsonB(serde_json::to_value(reference).expect("Secret reference serialization failed"))
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SecretOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secret_bindings: Option<SecretBindings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub form_fields: Option<BTreeMap<String, String>>,
}

pub struct ResolvedBindings {
    pub headers: reqwest::header::HeaderMap,
    pub form_body: Option<String>,
}

impl SecretOptions {
    fn form_mode(&self) -> bool {
        self.form_fields.is_some()
            || self
                .secret_bindings
                .as_ref()
                .is_some_and(|bindings| !bindings.form.is_empty())
    }

    pub fn validate(
        &self,
        has_body: bool,
        method: &str,
        multipart: bool,
        headers: Option<&Value>,
    ) -> Result<(), String> {
        if let Some(bindings) = &self.secret_bindings {
            bindings.validate()?;
        }
        if self.form_mode() {
            if multipart || has_body {
                return Err(
                    "Form fields cannot be combined with a raw body or multipart request".into(),
                );
            }
            if !matches!(method, "POST" | "PUT" | "PATCH") {
                return Err("Form fields require POST, PUT or PATCH".into());
            }
            for name in self.form_fields.iter().flat_map(|fields| fields.keys()) {
                if name.is_empty() || name.chars().any(char::is_control) {
                    return Err(
                        "Form field names must be nonempty without control characters".into(),
                    );
                }
                if self
                    .secret_bindings
                    .as_ref()
                    .is_some_and(|bindings| bindings.form.contains_key(name))
                {
                    return Err(
                        "A form field cannot have both an ordinary value and a secret binding"
                            .into(),
                    );
                }
            }
            for (name, value) in headers.and_then(Value::as_object).into_iter().flatten() {
                if name.eq_ignore_ascii_case("content-length")
                    || name.eq_ignore_ascii_case("transfer-encoding")
                {
                    return Err("Form requests cannot override HTTP body framing".into());
                }
                if name.eq_ignore_ascii_case("content-type")
                    && !value.as_str().is_some_and(|value| {
                        value.eq_ignore_ascii_case("application/x-www-form-urlencoded")
                    })
                {
                    return Err(
                        "Form requests require application/x-www-form-urlencoded Content-Type"
                            .into(),
                    );
                }
            }
        }
        Ok(())
    }

    fn validate_destinations(
        &self,
        request: &crate::endpoints::EndpointRequest,
        headers: Option<&Value>,
    ) -> Result<(), String> {
        let Some(bindings) = &self.secret_bindings else {
            return Ok(());
        };
        bindings.validate()?;
        let active =
            !bindings.headers.is_empty() || !bindings.query.is_empty() || !bindings.form.is_empty();
        for name in headers
            .and_then(Value::as_object)
            .into_iter()
            .flat_map(|headers| headers.keys())
        {
            if (active && name.eq_ignore_ascii_case("host"))
                || bindings
                    .headers
                    .keys()
                    .any(|secret_name| name.eq_ignore_ascii_case(secret_name))
            {
                return Err(
                    "Secret bindings conflict with ordinary request headers or Host".into(),
                );
            }
        }
        if let Some((name, _)) = &request.credential_header {
            if bindings
                .headers
                .keys()
                .any(|secret_name| secret_name.eq_ignore_ascii_case(name.as_str()))
            {
                return Err("Secret binding cannot override endpoint authentication".into());
            }
        }
        if request
            .url
            .query_pairs()
            .any(|(name, _)| bindings.query.contains_key(name.as_ref()))
        {
            return Err("Secret binding conflicts with an existing query parameter".into());
        }
        Ok(())
    }

    pub async fn resolve(
        &self,
        submitted_by: &str,
        database: Option<&str>,
        request: &mut crate::endpoints::EndpointRequest,
        headers: Option<&Value>,
    ) -> Result<ResolvedBindings, String> {
        self.validate_destinations(request, headers)?;
        let mut catalog = BTreeMap::new();
        if let Some(bindings) = &self.secret_bindings {
            let servers = bindings
                .headers
                .values()
                .chain(bindings.query.values())
                .chain(bindings.form.values())
                .map(|reference| reference.server.as_str())
                .collect::<BTreeSet<_>>();
            for server in servers {
                catalog.insert(
                    server.to_owned(),
                    crate::endpoints::resolve_named_secrets(submitted_by, database, server).await?,
                );
            }
        }
        self.materialize(request, &catalog)
    }

    fn materialize(
        &self,
        request: &mut crate::endpoints::EndpointRequest,
        catalog: &BTreeMap<String, BTreeMap<String, String>>,
    ) -> Result<ResolvedBindings, String> {
        let lookup = |reference: &SecretReference| -> Result<&str, String> {
            catalog
                .get(&reference.server)
                .and_then(|values| values.get(&reference.key))
                .map(String::as_str)
                .ok_or_else(|| "Referenced secret key is missing".into())
        };
        let mut headers = reqwest::header::HeaderMap::new();
        let mut fields = self.form_fields.clone().unwrap_or_default();
        if let Some(bindings) = &self.secret_bindings {
            for (name, reference) in &bindings.headers {
                let name = credential_header_name(name)?;
                let mut value = reqwest::header::HeaderValue::from_str(&format!(
                    "{}{}",
                    reference.prefix,
                    lookup(reference)?
                ))
                .map_err(|_| "Resolved secret is not a valid HTTP header value")?;
                value.set_sensitive(true);
                headers.insert(name, value);
            }
            if !bindings.query.is_empty() {
                let mut serializer = url::form_urlencoded::Serializer::new(String::new());
                for (name, reference) in &bindings.query {
                    serializer.append_pair(name, lookup(reference)?);
                }
                let encoded = serializer.finish();
                let query = match request.url.query().filter(|query| !query.is_empty()) {
                    Some(existing) => format!("{existing}&{encoded}"),
                    None => encoded,
                };
                request.url.set_query(Some(&query));
            }
            for (name, reference) in &bindings.form {
                fields.insert(name.clone(), lookup(reference)?.to_owned());
            }
        }
        let form_body = if self.form_mode() {
            let mut serializer = url::form_urlencoded::Serializer::new(String::new());
            serializer.extend_pairs(&fields);
            Some(serializer.finish())
        } else {
            None
        };
        Ok(ResolvedBindings { headers, form_body })
    }
}

pub fn configure_bindings(
    request: &str,
    bindings: Value,
    form: Option<Value>,
) -> Result<String, String> {
    let bindings: SecretBindings = serde_json::from_value(bindings).map_err(|_| {
        "Invalid secret bindings: expected header/query/form maps of secret references"
    })?;
    bindings.validate()?;
    let mut node: Value =
        serde_json::from_str(request).map_err(|_| "Secret bindings require an HTTP node")?;
    let multipart = match node.get("node_type").and_then(Value::as_str) {
        Some("HTTP") => false,
        Some("HTTP_MULTIPART") => true,
        _ => return Err("Secret bindings require a single HTTP or HTTP_MULTIPART node".into()),
    };
    let mut config: Value = serde_json::from_str(
        node.get("query")
            .and_then(Value::as_str)
            .ok_or("HTTP node has no request configuration")?,
    )
    .map_err(|_| "Invalid HTTP request configuration")?;
    if !config.is_object() {
        return Err("Invalid HTTP request configuration".into());
    }
    let form_fields: Option<BTreeMap<String, String>> = form
        .map(serde_json::from_value)
        .transpose()
        .map_err(|_| "Form fields must be an object of string values")?;
    let options = SecretOptions {
        secret_bindings: Some(bindings),
        form_fields,
    };
    options.validate(
        config.get("body").is_some_and(|body| !body.is_null()),
        config.get("method").and_then(Value::as_str).unwrap_or(""),
        multipart,
        config.get("headers"),
    )?;
    config["secret_bindings"] =
        serde_json::to_value(options.secret_bindings).map_err(|_| "Invalid secret bindings")?;
    if let Some(fields) = options.form_fields {
        config["form_fields"] = serde_json::to_value(fields).map_err(|_| "Invalid form fields")?;
    }
    node["query"] = Value::String(config.to_string());
    Ok(node.to_string())
}

#[cfg(test)]
mod unit_tests {
    use super::*;
    use serde_json::json;

    fn request() -> String {
        json!({"node_type":"HTTP","query":json!({"url":"https://api.github.com/","method":"POST","body":null}).to_string()}).to_string()
    }

    #[test]
    fn secret_bindings_encode_without_rescanning_data() {
        let options: SecretOptions = serde_json::from_value(json!({
            "secret_bindings": {
                "headers":{"Authorization":{"server":"foo","key":"token","prefix":"Bearer "}},
                "query":{"api_key":{"server":"foo","key":"delimiters"}},
                "form":{"password":{"server":"foo","key":"delimiters"}}
            },
            "form_fields":{"payload":"${secret:foo.other} $result {var}", "empty":""}
        }))
        .unwrap();
        let mut request = crate::endpoints::EndpointRequest {
            url: url::Url::parse("https://api.github.com/?sig=existing%2Bvalue").unwrap(),
            credential_header: None,
        };
        options.validate(false, "POST", false, None).unwrap();
        options.validate_destinations(&request, None).unwrap();
        let catalog = BTreeMap::from([(
            "foo".into(),
            BTreeMap::from([
                ("token".into(), "${secret:foo.other}".into()),
                ("delimiters".into(), "a&b+c= %\"\n\u{00e9}".into()),
            ]),
        )]);
        let resolved = options.materialize(&mut request, &catalog).unwrap();
        assert_eq!(
            resolved.headers["authorization"],
            "Bearer ${secret:foo.other}"
        );
        assert!(resolved.headers["authorization"].is_sensitive());
        assert!(request
            .url
            .query()
            .unwrap()
            .starts_with("sig=existing%2Bvalue&"));
        let query: BTreeMap<_, _> = request.url.query_pairs().into_owned().collect();
        assert_eq!(query["api_key"], "a&b+c= %\"\n\u{00e9}");
        let form: BTreeMap<_, _> =
            url::form_urlencoded::parse(resolved.form_body.unwrap().as_bytes())
                .into_owned()
                .collect();
        assert_eq!(form["password"], query["api_key"]);
        assert_eq!(form["payload"], "${secret:foo.other} $result {var}");
        assert_eq!(form["empty"], "");
    }

    #[test]
    fn secret_bindings_reject_transport_conflicts() {
        let options: SecretOptions = serde_json::from_value(json!({"secret_bindings":{"headers":{"X-Key":{"server":"foo","key":"bar"}},"query":{"key":{"server":"foo","key":"bar"}}}})).unwrap();
        let mut request = crate::endpoints::EndpointRequest {
            url: url::Url::parse("https://api.github.com/?%6bey=ordinary").unwrap(),
            credential_header: None,
        };
        assert!(options.validate_destinations(&request, None).is_err());
        request.url.set_query(None);
        assert!(options
            .validate_destinations(&request, Some(&json!({"x-key":"ordinary"})))
            .is_err());
        assert!(options
            .validate_destinations(&request, Some(&json!({"Host":"other"})))
            .is_err());
        request.credential_header = Some((
            reqwest::header::HeaderName::from_static("x-key"),
            reqwest::header::HeaderValue::from_static("endpoint"),
        ));
        assert!(options.validate_destinations(&request, None).is_err());
        let form: SecretOptions = serde_json::from_value(json!({"form_fields":{}})).unwrap();
        assert!(form.validate(true, "POST", false, None).is_err());
        assert!(form.validate(false, "POST", true, None).is_err());
        assert!(form.validate(false, "GET", false, None).is_err());
        assert!(form
            .validate(
                false,
                "POST",
                false,
                Some(&json!({"Content-Type":"application/json"}))
            )
            .is_err());
        assert!(form
            .validate(false, "POST", false, Some(&json!({"Content-Length":"0"})))
            .is_err());
    }

    #[test]
    fn secret_bindings_errors_do_not_echo_values() {
        for key in ["", "PRIVATE_VALUE\n", "PRIVATE_VALUE=other"] {
            assert!(!validate_secret_key(key)
                .unwrap_err()
                .contains("PRIVATE_VALUE"));
        }
        let options: SecretOptions = serde_json::from_value(
            json!({"secret_bindings":{"headers":{"x-key":{"server":"foo","key":"bar"}}}}),
        )
        .unwrap();
        let mut request = crate::endpoints::EndpointRequest {
            url: url::Url::parse("https://api.github.com/").unwrap(),
            credential_header: None,
        };
        let catalog = BTreeMap::from([(
            "foo".into(),
            BTreeMap::from([("bar".into(), "PRIVATE_VALUE\r\n".into())]),
        )]);
        assert!(!options
            .materialize(&mut request, &catalog)
            .err()
            .unwrap()
            .contains("PRIVATE_VALUE"));
    }

    #[test]
    fn secret_bindings_preserve_literal_form_data() {
        let data = json!({"payload":"${secret:foo.bar} $result {var}","descriptor":"{\"server\":\"other\",\"key\":\"private\"}"});
        let configured = configure_bindings(
            &request(),
            json!({"form":{"client_secret":{"server":"foo","key":"bar"}}}),
            Some(data.clone()),
        )
        .unwrap();
        let node: Value = serde_json::from_str(&configured).unwrap();
        let config: Value = serde_json::from_str(node["query"].as_str().unwrap()).unwrap();
        assert_eq!(config["form_fields"], data);
        assert_eq!(
            config["secret_bindings"]["form"]["client_secret"]["key"],
            "bar"
        );
    }

    #[test]
    fn secret_bindings_reject_ambiguous_or_unsafe_shapes() {
        for bindings in [
            json!({"body":{}}),
            json!({"headers":{"Host":{"server":"foo","key":"bar"}}}),
            json!({"headers":{"X-Key":{"server":"foo","key":"bar"},"x-key":{"server":"foo","key":"bar"}}}),
            json!({"headers":{"X-Key":{"server":"foo","key":"bar","prefix":"bad\r\n"}}}),
            json!({"query":{"key":{"server":"foo","key":"bar","prefix":"prefix"}}}),
            json!({"form":{"key":"${secret:foo.bar}"}}),
            json!({"form":{"key":{"server":"foo","key":""}}}),
        ] {
            assert!(configure_bindings(&request(), bindings, None).is_err());
        }
        assert!(configure_bindings(
            &request(),
            json!({"form":{"key":{"server":"foo","key":"bar"}}}),
            Some(json!({"key":"data"}))
        )
        .is_err());
        assert!(configure_bindings(
            &request(),
            json!({}),
            Some(json!({"key":{"server":"foo","key":"bar"}}))
        )
        .is_err());
    }

    #[test]
    fn secret_binding_serialization_is_canonical() {
        let first: Value = serde_json::from_str(
            r#"{"query":{"second":{"server":"foo","key":"b"},"first":{"key":"a","server":"foo"}}}"#,
        )
        .unwrap();
        let second: Value = serde_json::from_str(
            r#"{"query":{"first":{"server":"foo","key":"a"},"second":{"key":"b","server":"foo"}}}"#,
        )
        .unwrap();
        assert_eq!(
            configure_bindings(&request(), first, None).unwrap(),
            configure_bindings(&request(), second, None).unwrap()
        );
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use super::*;

    #[pg_test]
    fn secret_reference_is_lookup_free() {
        assert_eq!(
            secret("missing.server", "key.\\\"").0,
            serde_json::json!({"server":"missing.server","key":"key.\\\""})
        );
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains",
        feature = "http-allow-all"
    ))]
    #[pg_test]
    fn secret_options_preserve_data_and_noop_bytes() {
        let request = crate::dsl::http("https://api.github.com", "POST", None, None, 30);
        assert_eq!(crate::dsl::with_http_options(&request, None), request);
        assert_eq!(
            crate::dsl::with_http_options(&request, Some(pgrx::JsonB(serde_json::json!({})))),
            request
        );
        let options = serde_json::json!({
            "secret_bindings":{"form":{"password":secret("missing", "key").0}},
            "form_fields":{"payload":"${secret:missing.key} $result {variable}"}
        });
        let configured = crate::dsl::with_http_options(&request, Some(pgrx::JsonB(options)));
        let node = crate::types::Durofut::from_json(&configured);
        let mut config: Value = serde_json::from_str(node.query.as_ref().unwrap()).unwrap();
        crate::endpoints::set_execution_context(&mut config, "caller", Some("trusted"));
        assert_eq!(config["database"], "trusted");
        assert_eq!(
            config["form_fields"]["payload"],
            "${secret:missing.key} $result {variable}"
        );
        let typed: crate::types::HttpConfig = serde_json::from_value(config).unwrap();
        assert_eq!(
            typed.secret_options.secret_bindings.unwrap().form["password"].key,
            "key"
        );
        let replaced = crate::dsl::with_http_options(
            &configured,
            Some(pgrx::JsonB(
                serde_json::json!({"form_fields":{"payload":"replacement"}}),
            )),
        );
        let replaced_node = crate::types::Durofut::from_json(&replaced);
        let replaced_config: Value =
            serde_json::from_str(replaced_node.query.as_ref().unwrap()).unwrap();
        assert_eq!(
            replaced_config["secret_bindings"]["form"]["password"]["key"],
            "key"
        );
        assert_eq!(replaced_config["form_fields"]["payload"], "replacement");
    }
}
