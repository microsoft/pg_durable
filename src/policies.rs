// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

use std::collections::{BTreeMap, BTreeSet};
use std::num::NonZeroU32;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use duroxide::runtime::ActivityAdmission;
use serde::{Deserialize, Serialize};

const HTTP_SCOPES_KEY: &str = "_pgd_http_scopes";

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkflowPolicy {
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present"
    )]
    pub(crate) http: Option<HttpConcurrencyPolicy>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HttpConcurrencyPolicy {
    pub(crate) max_concurrency: NonZeroU32,
}

pub(crate) fn present<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    object(deserializer).map(Some)
}

pub(crate) fn object<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    let value = serde_json::Map::<String, serde_json::Value>::deserialize(deserializer)?;
    T::deserialize(serde_json::Value::Object(value)).map_err(serde::de::Error::custom)
}

impl WorkflowPolicy {
    pub(crate) fn constrain(&mut self, other: Self) {
        if let Some(http) = other.http {
            match &mut self.http {
                Some(existing) => {
                    existing.max_concurrency = existing.max_concurrency.min(http.max_concurrency);
                }
                None => self.http = Some(http),
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct HttpScope {
    pub id: String,
    pub max_concurrency: NonZeroU32,
}

pub(crate) fn compile_http_query(query: &str, scopes: &[HttpScope]) -> Result<String, String> {
    let mut config: serde_json::Value =
        serde_json::from_str(query).map_err(|error| format!("Invalid HTTP config: {error}"))?;
    let object = config
        .as_object_mut()
        .ok_or("HTTP config must be an object")?;
    if object.contains_key(HTTP_SCOPES_KEY) {
        return Err(format!(
            "{HTTP_SCOPES_KEY} is reserved; use df.with_policy() to configure HTTP concurrency"
        ));
    }
    if scopes.is_empty() {
        return Ok(query.to_string());
    }
    object.insert(
        HTTP_SCOPES_KEY.to_string(),
        serde_json::to_value(scopes).map_err(|error| error.to_string())?,
    );
    Ok(config.to_string())
}

pub(crate) fn http_scopes(input: &str) -> Result<Vec<HttpScope>, String> {
    #[derive(Deserialize)]
    struct Config {
        #[serde(default)]
        _pgd_http_scopes: Vec<serde_json::Map<String, serde_json::Value>>,
    }
    let config: Config = serde_json::from_str(input)
        .map_err(|error| format!("Invalid HTTP admission config: {error}"))?;
    if config._pgd_http_scopes.len() > crate::types::MAX_GRAPH_DEPTH + 1 {
        return Err("Too many HTTP policy scopes".to_string());
    }
    let scopes: Vec<HttpScope> = config
        ._pgd_http_scopes
        .into_iter()
        .map(|scope| serde_json::from_value(serde_json::Value::Object(scope)))
        .collect::<Result<_, _>>()
        .map_err(|error| format!("Invalid HTTP policy scope: {error}"))?;
    let mut seen = BTreeSet::new();
    for scope in &scopes {
        if scope.id.is_empty()
            || scope.id.len() > 32
            || !scope.id.bytes().all(|byte| byte.is_ascii_alphanumeric())
        {
            return Err("Invalid HTTP policy scope ID".to_string());
        }
        if !seen.insert(&scope.id) {
            return Err(format!("Duplicate HTTP policy scope '{}'", scope.id));
        }
    }
    Ok(scopes)
}

type ScopeKey = (String, String);

struct ScopeCounter {
    limit: NonZeroU32,
    active: u32,
}

#[derive(Default)]
struct AdmissionState {
    active: usize,
    scopes: BTreeMap<ScopeKey, ScopeCounter>,
}

pub struct HttpAdmission {
    limit: usize,
    state: Mutex<AdmissionState>,
}

impl HttpAdmission {
    pub(crate) fn new(limit: usize) -> Self {
        assert!(limit > 0, "HTTP concurrency must be positive");
        Self {
            limit,
            state: Mutex::new(AdmissionState::default()),
        }
    }

    pub(crate) fn try_admit(
        self: &Arc<Self>,
        engine_instance: &str,
        input: &str,
    ) -> Result<ActivityAdmission, String> {
        let scopes = http_scopes(input)?;
        // Child and continue-as-new execution IDs must not create fresh budgets.
        let root = engine_instance
            .split("::")
            .next()
            .filter(|root| !root.is_empty())
            .ok_or("HTTP admission requires an engine instance ID")?;
        let keys: Vec<_> = scopes
            .iter()
            .map(|scope| (root.to_string(), scope.id.clone()))
            .collect();
        let mut state = self
            .state
            .lock()
            .map_err(|_| "HTTP admission state poisoned")?;
        let mut saturated = state.active >= self.limit;
        for (key, scope) in keys.iter().zip(&scopes) {
            if let Some(counter) = state.scopes.get(key) {
                if counter.limit != scope.max_concurrency {
                    return Err(format!("Conflicting HTTP limits for scope '{}'", scope.id));
                }
                saturated |= counter.active >= counter.limit.get();
            }
        }
        if saturated {
            return Ok(ActivityAdmission::Defer(Duration::from_millis(100)));
        }

        state.active += 1;
        for (key, scope) in keys.iter().zip(scopes) {
            state
                .scopes
                .entry(key.clone())
                .or_insert(ScopeCounter {
                    limit: scope.max_concurrency,
                    active: 0,
                })
                .active += 1;
        }
        Ok(ActivityAdmission::admit(HttpPermit {
            admission: self.clone(),
            keys,
        }))
    }
}

struct HttpPermit {
    admission: Arc<HttpAdmission>,
    keys: Vec<ScopeKey>,
}

impl Drop for HttpPermit {
    fn drop(&mut self) {
        let mut state = self
            .admission
            .state
            .lock()
            .expect("HTTP admission state poisoned");
        assert!(
            state.active > 0,
            "HTTP permit released without a reservation"
        );
        state.active -= 1;
        for key in &self.keys {
            let counter = state.scopes.get_mut(key).expect("HTTP scope disappeared");
            assert!(
                counter.active > 0,
                "HTTP scope released without a reservation"
            );
            counter.active -= 1;
            if counter.active == 0 {
                state.scopes.remove(key);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(scopes: &[(&str, u32)]) -> String {
        let scopes: Vec<_> = scopes
            .iter()
            .map(|(id, limit)| HttpScope {
                id: id.to_string(),
                max_concurrency: NonZeroU32::new(*limit).unwrap(),
            })
            .collect();
        serde_json::json!({HTTP_SCOPES_KEY: scopes}).to_string()
    }

    fn admitted(decision: Result<ActivityAdmission, String>) -> Box<dyn Send> {
        match decision.unwrap() {
            ActivityAdmission::Admit(guard) => guard,
            ActivityAdmission::Defer(_) => panic!("unexpected deferral"),
        }
    }

    #[test]
    fn policy_validation_and_same_scope_composition() {
        for invalid in [
            "null",
            "[]",
            r#"{"sql":{}}"#,
            r#"{"http":null}"#,
            r#"{"http":[1]}"#,
            r#"{"http":{}}"#,
            r#"{"http":{"max_concurrency":null}}"#,
            r#"{"http":{"max_concurrency":0}}"#,
            r#"{"http":{"max_concurrency":-1}}"#,
            r#"{"http":{"max_concurrency":1.5}}"#,
            r#"{"http":{"max_concurrency":"1"}}"#,
            r#"{"http":{"max_concurrency":1,"typo":2}}"#,
        ] {
            let value: serde_json::Value = serde_json::from_str(invalid).unwrap();
            assert!(object::<_, WorkflowPolicy>(value).is_err(), "{invalid}");
        }
        let mut policy: WorkflowPolicy =
            serde_json::from_str(r#"{"http":{"max_concurrency":2}}"#).unwrap();
        policy.constrain(serde_json::from_str(r#"{"http":{"max_concurrency":5}}"#).unwrap());
        assert_eq!(policy.http.as_ref().unwrap().max_concurrency.get(), 2);
        policy.constrain(serde_json::from_str(r#"{"http":{"max_concurrency":1}}"#).unwrap());
        assert_eq!(policy.http.unwrap().max_concurrency.get(), 1);
        assert!(serde_json::from_str::<WorkflowPolicy>("{}")
            .unwrap()
            .http
            .is_none());
    }

    #[test]
    fn policy_admission_reserves_all_limits_or_none() {
        let admission = Arc::new(HttpAdmission::new(3));
        let a = input(&[("outer", 2), ("a", 1)]);
        let b = input(&[("outer", 2), ("b", 1)]);
        let first = admitted(admission.try_admit("root::1::left", &a));
        assert!(matches!(
            admission
                .try_admit("root::9::right::3::nested", &a)
                .unwrap(),
            ActivityAdmission::Defer(_)
        ));
        let second = admitted(admission.try_admit("root::1::right", &b));
        assert!(matches!(
            admission
                .try_admit("root::2::third", &input(&[("outer", 2)]))
                .unwrap(),
            ActivityAdmission::Defer(_)
        ));
        let independent = admitted(admission.try_admit("other::1::left", &a));
        assert!(matches!(
            admission.try_admit("unscoped", "{}").unwrap(),
            ActivityAdmission::Defer(_)
        ));
        drop(first);
        let next_generation = admitted(admission.try_admit("root::2::left", &a));
        drop((second, independent, next_generation));
        let state = admission.state.lock().unwrap();
        assert_eq!(state.active, 0);
        assert!(
            state.scopes.is_empty(),
            "finished workflows must not leak scope counters"
        );
    }

    #[test]
    fn policy_admission_validates_internal_metadata() {
        let admission = Arc::new(HttpAdmission::new(2));
        for invalid in [
            r#"{"_pgd_http_scopes":null}"#,
            r#"{"_pgd_http_scopes":[["x",1]]}"#,
            r#"{"_pgd_http_scopes":[{"id":"x","max_concurrency":0}]}"#,
            r#"{"_pgd_http_scopes":[{"id":"","max_concurrency":1}]}"#,
            r#"{"_pgd_http_scopes":[{"id":"x","max_concurrency":1,"typo":1}]}"#,
        ] {
            assert!(admission.try_admit("root", invalid).is_err(), "{invalid}");
        }
        assert!(admission
            .try_admit("root", &input(&[("x", 1), ("x", 1)]))
            .is_err());
        let guard = admitted(admission.try_admit("root", &input(&[("x", 1)])));
        assert!(admission.try_admit("root", &input(&[("x", 2)])).is_err());
        drop(guard);
        assert_eq!(admission.state.lock().unwrap().active, 0);
    }

    #[test]
    fn policy_scopes_are_independent_between_origin_installations() {
        let admission = Arc::new(HttpAdmission::new(2));
        let scopes = input(&[("node", 1)]);
        let a = admitted(admission.try_admit("pgdf-1-installation-abcdef01::1::child", &scopes));
        let b = admitted(admission.try_admit("pgdf-2-installation-abcdef01::1::child", &scopes));
        drop((a, b));
        assert!(admission.state.lock().unwrap().scopes.is_empty());
    }

    fn scoped(mut node: crate::types::Durofut, limit: u32) -> crate::types::Durofut {
        node.policy = Some(WorkflowPolicy {
            http: Some(HttpConcurrencyPolicy {
                max_concurrency: NonZeroU32::new(limit).unwrap(),
            }),
        });
        node
    }

    fn http() -> crate::types::Durofut {
        crate::types::Durofut {
            node_type: "HTTP".to_string(),
            query: Some(
                r#" { "url" : "https://example.com", "method":"GET", "body":"$next {previous}" } "#
                    .to_string(),
            ),
            ..Default::default()
        }
    }

    fn flatten(node: &crate::types::Durofut) -> Vec<crate::types::MaterializedNode> {
        let mut id = 0;
        crate::types::flatten_graph(node, &mut || {
            id += 1;
            Ok(format!("{id:08x}"))
        })
        .unwrap()
        .1
    }

    #[test]
    fn policy_materialization_is_lexical_and_deterministic() {
        use crate::types::Durofut;
        let fragment = scoped(
            Durofut {
                node_type: "JOIN".to_string(),
                left_node: Some(http().into_raw()),
                right_node: Some(http().into_raw()),
                extra_nodes: vec![http().into_raw()],
                ..Default::default()
            },
            1,
        );
        let root = scoped(
            Durofut {
                node_type: "JOIN".to_string(),
                left_node: Some(fragment.clone().into_raw()),
                right_node: Some(fragment.into_raw()),
                extra_nodes: vec![scoped(
                    Durofut {
                        node_type: "LOOP".to_string(),
                        left_node: Some(http().into_raw()),
                        condition_node: Some(http().into_raw()),
                        ..Default::default()
                    },
                    3,
                )
                .into_raw()],
                ..Default::default()
            },
            2,
        );
        let nodes = flatten(&root);
        assert_eq!(
            nodes,
            flatten(&root),
            "materialization must preserve scope IDs and bytes"
        );
        let mut inner_scopes = BTreeSet::new();
        let mut http_count = 0;
        for node in nodes.iter().filter(|node| node.node_type == "HTTP") {
            http_count += 1;
            let scopes = http_scopes(node.query.as_deref().unwrap()).unwrap();
            assert_eq!(scopes.len(), 2);
            assert_eq!(scopes[0].id, nodes[0].id);
            assert_eq!(scopes[0].max_concurrency.get(), 2);
            inner_scopes.insert(scopes[1].id.clone());
            let config: serde_json::Value =
                serde_json::from_str(node.query.as_deref().unwrap()).unwrap();
            assert_eq!(config["body"], "$next {previous}");
        }
        assert_eq!(
            http_count, 8,
            "extra JOIN children and loop conditions inherit scopes"
        );
        assert_eq!(
            inner_scopes.len(),
            3,
            "reused fragments must get independent lexical scopes"
        );
    }

    #[test]
    fn policy_absence_preserves_http_bytes_and_rejects_forged_scopes() {
        let node = http();
        assert_eq!(flatten(&node)[0].query, node.query);
        assert!(!node.to_json().contains("policy"));
        let mut forged = node.clone();
        forged.query = Some(input(&[("forged", 1)]));
        let error =
            crate::types::flatten_graph(&forged, &mut || Ok("00000001".to_string())).unwrap_err();
        assert!(error.message.contains("reserved"));
        assert!(crate::types::Durofut::try_from_json(
            r#"{"node_type":"SQL","query":"SELECT 1","policy":{"http":null}}"#
        )
        .is_err());
    }
}
