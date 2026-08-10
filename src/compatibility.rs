// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

use semver::Version;

const PROVIDER_COMPAT_FLOOR: Version = Version::new(0, 2, 2);

pub(crate) fn provider_compatibility_verdict(installed: &str) -> Result<(), String> {
    let installed_version = Version::parse(installed)
        .map_err(|_| format!("unrecognized pg_durable version format: {installed}"))?;

    if installed_version >= PROVIDER_COMPAT_FLOOR {
        return Ok(());
    }

    Err(format!(
        "installed schema is pg_durable {installed}, but this binary supports \
         {PROVIDER_COMPAT_FLOOR} and later only. Versions before \
         {PROVIDER_COMPAT_FLOOR} use the retired duroxide-pg-opt provider line and \
         are not upgradable with this package. Reinstall a pg_durable package at \
         0.2.5 or earlier to regain the pre-{PROVIDER_COMPAT_FLOOR} upgrade chain, \
         or follow the downstream process that owns the duroxide-pg-opt line. \
         Refusing to start so that provider migrations are not applied over \
         incompatible state."
    ))
}

#[cfg(test)]
mod tests {
    use super::provider_compatibility_verdict;

    #[test]
    fn rejects_versions_below_the_provider_compat_floor() {
        for version in ["0.1.1", "0.2.0", "0.2.1", "0.2.2-rc1"] {
            let err = provider_compatibility_verdict(version)
                .expect_err("pre-0.2.2 schema must be rejected");
            assert!(err.contains(version), "message should name the version");
            assert!(
                err.contains("0.2.2"),
                "message should name the required floor"
            );
            assert!(
                err.contains("duroxide-pg-opt"),
                "message should point at the downstream line"
            );
        }
    }

    #[test]
    fn admits_the_floor_and_later() {
        for version in [
            "0.2.2",
            "0.2.2+build.1",
            "0.2.4-rc1",
            "0.3.0-alpha.1",
            "1.0.0",
        ] {
            assert!(
                provider_compatibility_verdict(version).is_ok(),
                "{version} is in the provider compatibility line"
            );
        }
    }

    #[test]
    fn rejects_unparseable_versions() {
        for version in ["", "0", "0.2", "0.2.2.1", "garbage"] {
            assert!(provider_compatibility_verdict(version).is_err());
        }
    }
}
