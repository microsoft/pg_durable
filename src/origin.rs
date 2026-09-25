use pgrx::prelude::*;
use sqlx::{postgres::PgConnectOptions, Connection, PgConnection, PgPool, Postgres, Transaction};
use std::{
    str::FromStr,
    sync::{Arc, OnceLock},
    time::Duration,
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use uuid::Uuid;

use crate::types;

static ORIGIN_CONNECTION_SLOTS: OnceLock<Arc<Semaphore>> = OnceLock::new();
pub(crate) const REPLACED: &str = "Origin installation removed or replaced";

async fn check_identity(connection: &mut PgConnection, origin: &Origin) -> Result<(), sqlx::Error> {
    let valid: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM df._installation i
         JOIN pg_catalog.pg_depend d ON d.objid OPERATOR(pg_catalog.=) 'df._installation'::pg_catalog.regclass
             AND d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
             AND d.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_extension'::pg_catalog.regclass
             AND d.deptype OPERATOR(pg_catalog.=) 'e'
         JOIN pg_catalog.pg_extension e ON e.oid OPERATOR(pg_catalog.=) d.refobjid
             AND e.extname OPERATOR(pg_catalog.=) 'pg_durable'
         WHERE i.id OPERATOR(pg_catalog.=) $1 AND (SELECT oid FROM pg_catalog.pg_database
             WHERE datname OPERATOR(pg_catalog.=) pg_catalog.current_database())
                 OPERATOR(pg_catalog.=) $2::pg_catalog.int8::pg_catalog.oid)",
    )
    .bind(origin.installation_id)
    .bind(i64::from(origin.database_oid))
    .fetch_one(connection)
    .await?;
    if !valid {
        return Err(sqlx::Error::Protocol(REPLACED.into()));
    }

    Ok(())
}

pub(crate) async fn configure_metadata_transaction(
    connection: &mut PgConnection,
) -> Result<(), sqlx::Error> {
    sqlx::query("SET LOCAL lock_timeout = '1500ms'")
        .execute(&mut *connection)
        .await?;
    sqlx::query("SET LOCAL statement_timeout = '5s'")
        .execute(connection)
        .await?;
    Ok(())
}

/// Lock before reading the UUID: the identity SELECT needs a snapshot taken
/// after any DDL wait. The caller owns the transaction and its lifetime.
pub(crate) async fn lock_and_validate(
    connection: &mut PgConnection,
    origin: &Origin,
) -> Result<(), sqlx::Error> {
    sqlx::query("LOCK TABLE df._installation IN ACCESS SHARE MODE")
        .execute(&mut *connection)
        .await?;
    check_identity(connection, origin).await
}

pub(crate) async fn begin_metadata(
    pool: &PgPool,
    origin: Option<&Origin>,
) -> Result<Transaction<'static, Postgres>, sqlx::Error> {
    let mut tx = pool.begin().await?;
    if let Some(origin) = origin {
        sqlx::query("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
            .execute(&mut *tx)
            .await?;
        configure_metadata_transaction(&mut tx).await?;
        sqlx::query("LOCK TABLE df._installation, df.instances, df.nodes IN ACCESS SHARE MODE")
            .execute(&mut *tx)
            .await?;
        check_identity(&mut tx, origin).await?;
    }
    Ok(tx)
}

/// A short preflight on the actual user connection, never a transaction around
/// the business SQL. Commit releases all identity locks before dispatch.
pub(crate) async fn validate_execution_connection(
    connection: &mut PgConnection,
    origin: &Origin,
) -> Result<(), String> {
    let mut tx = connection
        .begin()
        .await
        .map_err(|error| error.to_string())?;
    let validation = async {
        sqlx::query("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
            .execute(&mut *tx)
            .await?;
        configure_metadata_transaction(&mut tx).await?;
        lock_and_validate(&mut tx, origin).await
    }
    .await;
    if let Err(error) = validation {
        let message = format!("Origin execution fence: {error}");
        tx.rollback()
            .await
            .map_err(|rollback| format!("{message}; rollback failed: {rollback}"))?;
        return Err(message);
    }
    tx.commit()
        .await
        .map_err(|error| format!("Origin execution fence commit failed: {error}"))
}

pub(crate) async fn acquire_connections(count: u32) -> Result<OwnedSemaphorePermit, String> {
    let slots = ORIGIN_CONNECTION_SLOTS
        .get_or_init(|| Arc::new(Semaphore::new(crate::MAX_ORIGIN_CONNECTIONS.get() as usize)));
    tokio::time::timeout(
        Duration::from_secs(30),
        slots.clone().acquire_many_owned(count),
    )
    .await
    .map_err(|_| "Origin connection admission timed out")?
    .map_err(|_| "Origin connection admission closed".to_string())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Origin {
    pub database_oid: u32,
    pub installation_id: Uuid,
}

impl Origin {
    pub fn engine_id(&self, local_id: &str) -> String {
        format!(
            "pgdf-{}-{}-{local_id}",
            self.database_oid,
            self.installation_id.simple()
        )
    }

    pub fn from_engine_id(engine_id: &str) -> Result<Option<Self>, String> {
        let root = engine_id.split("::").next().unwrap_or(engine_id);
        let Some(encoded) = root.strip_prefix("pgdf-") else {
            return Ok(None);
        };
        let fields: Vec<_> = encoded.split('-').collect();
        if fields.len() != 3
            || fields[2].len() != 8
            || !fields[2].bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err("Invalid pg_durable engine instance identity".to_string());
        }
        let database_oid = fields[0]
            .parse::<u32>()
            .map_err(|_| "Invalid origin database OID".to_string())?;
        let installation_id = Uuid::parse_str(fields[1])
            .map_err(|_| "Invalid origin installation identity".to_string())?;
        Ok(Some(Self {
            database_oid,
            installation_id,
        }))
    }
}

pub(crate) fn backend_engine_id(local_id: &str) -> Result<String, String> {
    Ok(engine_id_for_origin(backend_origin()?.as_ref(), local_id))
}

pub(crate) fn engine_id_for_origin(origin: Option<&Origin>, local_id: &str) -> String {
    origin.map_or_else(|| local_id.to_string(), |origin| origin.engine_id(local_id))
}

pub(crate) fn backend_origin() -> Result<Option<Origin>, String> {
    let database = Spi::get_one::<String>("SELECT pg_catalog.current_database()::text")
        .map_err(|error| error.to_string())?
        .ok_or("Caller database is unavailable")?;
    if database == types::get_database() {
        return Ok(None);
    }
    let installation_id = Spi::get_one::<String>("SELECT id::text FROM df._installation")
        .map_err(|error| format!("Origin installation unavailable: {error}"))?
        .ok_or("Origin installation identity is missing")?;
    let origin = Origin {
        database_oid: unsafe { pgrx::pg_sys::MyDatabaseId.to_u32() },
        installation_id: Uuid::parse_str(&installation_id).map_err(|error| error.to_string())?,
    };
    Ok(Some(origin))
}

#[pg_extern(schema = "df")]
pub fn validate_installation() -> bool {
    let database = Spi::get_one::<String>("SELECT pg_catalog.current_database()::text")
        .unwrap_or_else(|error| pgrx::error!("Cannot identify installation database: {error}"));
    if database.as_deref() == Some(types::get_database().as_str()) {
        return true;
    }
    let state = types::backend_control_state(&types::postgres_connection_string())
        .unwrap_or_else(|error| pgrx::error!("{error}"));
    if !state.ready {
        pgrx::error!("pg_durable control installation unavailable or not ready");
    }
    true
}

pub(crate) struct Router {
    control: Arc<PgPool>,
    connection_options: PgConnectOptions,
}

pub(crate) struct Route {
    pub pool: Arc<PgPool>,
    pub database: Option<String>,
    pub origin: Option<Origin>,
    permit: Option<OwnedSemaphorePermit>,
}

impl Route {
    pub async fn validate(&self) -> Result<(), String> {
        if let Some(origin) = self.origin.as_ref() {
            let mut tx = self
                .pool
                .begin()
                .await
                .map_err(|error| format!("Origin admission unavailable: {error}"))?;
            sqlx::query("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
                .execute(&mut *tx)
                .await
                .map_err(|error| error.to_string())?;
            configure_metadata_transaction(&mut tx)
                .await
                .map_err(|error| error.to_string())?;
            lock_and_validate(&mut tx, origin)
                .await
                .map_err(|error| format!("Origin admission unavailable: {error}"))?;
            tx.rollback()
                .await
                .map_err(|error| format!("Origin admission close failed: {error}"))?;
        }
        Ok(())
    }

    pub async fn close(mut self) {
        if self.permit.is_some() {
            self.pool.close().await;
            self.permit.take();
        }
    }
}

impl Drop for Route {
    fn drop(&mut self) {
        if let Some(permit) = self.permit.take() {
            let pool = self.pool.clone();
            tokio::spawn(async move {
                pool.close().await;
                drop(permit);
            });
        }
    }
}

impl Router {
    pub fn new(control: Arc<PgPool>) -> Self {
        Self {
            control,
            connection_options: PgConnectOptions::from_str(&types::postgres_connection_string())
                .expect("valid worker connection configuration")
                .application_name(types::WORKER_MANAGEMENT_APPLICATION_NAME),
        }
    }

    pub async fn route(&self, engine_id: &str) -> Result<Route, String> {
        let Some(origin) = Origin::from_engine_id(engine_id)? else {
            return Ok(Route {
                pool: self.control.clone(),
                database: None,
                origin: None,
                permit: None,
            });
        };
        crate::worker::register_origin(&self.control, &origin).await?;
        self.connect(&origin).await
    }

    pub async fn connect(&self, origin: &Origin) -> Result<Route, String> {
        let permit = acquire_connections(1).await?;
        let database: String = sqlx::query_scalar(
            "SELECT datname FROM pg_catalog.pg_database WHERE oid = $1::bigint::oid AND datallowconn",
        )
        .bind(i64::from(origin.database_oid))
        .fetch_optional(self.control.as_ref())
        .await
        .map_err(|error| format!("Origin database lookup failed: {error}"))?
        .ok_or("Origin database removed or connections disabled")?;
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(1)
            .acquire_timeout(Duration::from_secs(5))
            .connect_with(
                self.connection_options
                    .clone()
                    .database(&database)
                    .options([("lock_timeout", "1500ms"), ("statement_timeout", "5s")]),
            )
            .await
            .map_err(|error| format!("Origin database connection failed: {error}"))?;
        let route = Route {
            pool: Arc::new(pool),
            database: Some(database),
            origin: Some(origin.clone()),
            permit: Some(permit),
        };
        route.validate().await?;
        Ok(route)
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use super::*;

    #[pg_test]
    fn execution_fence_preserves_autocommit_and_connection_identity() {
        let admin = Spi::get_one::<String>("SELECT current_user::text")
            .unwrap()
            .unwrap();
        let database = Spi::get_one::<String>("SELECT current_database()::text")
            .unwrap()
            .unwrap();
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
            let mut connection = types::connect_as_user(&admin, Some(&database)).await.unwrap();
            let (oid, installation_id): (i64, Uuid) = sqlx::query_as(
                "SELECT d.oid::bigint, i.id FROM pg_catalog.pg_database d CROSS JOIN df._installation i
                 WHERE d.datname = pg_catalog.current_database()",
            ).fetch_one(&mut connection).await.unwrap();
            let origin = Origin { database_oid: u32::try_from(oid).unwrap(), installation_id };
            sqlx::raw_sql(
                "SET statement_timeout = '0'; SET lock_timeout = '0';
                 SET default_transaction_isolation = 'repeatable read';
                 CREATE TEMP TABLE origin_autocommit_probe(value integer)",
            ).execute(&mut connection).await.unwrap();
            let wrong_oid = Origin { database_oid: origin.database_oid + 1, ..origin.clone() };
            let wrong_installation = Origin { installation_id: Uuid::new_v4(), ..origin.clone() };
            for wrong in [wrong_oid, wrong_installation] {
                assert!(validate_execution_connection(&mut connection, &wrong).await.unwrap_err().contains(REPLACED));
                sqlx::query("VACUUM origin_autocommit_probe").execute(&mut connection).await.unwrap();
            }
            validate_execution_connection(&mut connection, &origin).await.unwrap();
            let held: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM pg_catalog.pg_locks WHERE pid = pg_catalog.pg_backend_pid()
                 AND relation = 'df._installation'::regclass AND granted",
            ).fetch_one(&mut connection).await.unwrap();
            assert_eq!(held, 0);
            let settings: (String, String, String) = sqlx::query_as(
                "SELECT current_setting('transaction_isolation'), current_setting('statement_timeout'),
                    current_setting('lock_timeout')",
            ).fetch_one(&mut connection).await.unwrap();
            assert_eq!(settings, ("repeatable read".into(), "0".into(), "0".into()));
            sqlx::query("VACUUM origin_autocommit_probe").execute(&mut connection).await.unwrap();
            connection.close().await.unwrap();
        });
    }
}

#[cfg(test)]
mod identity_tests {
    use super::*;

    #[test]
    fn batch_identity_mapping_preserves_legacy_and_satellite_ids() {
        let origin = Origin {
            database_oid: 42,
            installation_id: Uuid::from_u128(7),
        };
        for n in 0..1000 {
            let local_id = format!("{n:08x}");
            assert_eq!(engine_id_for_origin(None, &local_id), local_id);
            assert_eq!(
                engine_id_for_origin(Some(&origin), &local_id),
                format!("pgdf-42-00000000000000000000000000000007-{local_id}")
            );
        }
    }

    #[test]
    fn multi_database_identity_preserves_child_routing() {
        let origin = Origin {
            database_oid: 42,
            installation_id: Uuid::from_u128(7),
        };
        let engine_id = origin.engine_id("deadbeef");
        assert_eq!(Origin::from_engine_id(&engine_id), Ok(Some(origin.clone())));
        assert_eq!(
            Origin::from_engine_id(&format!("{engine_id}::2::cafebabe::3::12345678")),
            Ok(Some(origin))
        );
    }

    #[test]
    fn multi_database_identity_is_scoped_to_installation_and_database() {
        let origin = Origin {
            database_oid: 42,
            installation_id: Uuid::from_u128(7),
        };
        let other_database = Origin {
            database_oid: 43,
            ..origin.clone()
        };
        let recreated = Origin {
            installation_id: Uuid::from_u128(8),
            ..origin.clone()
        };
        assert_ne!(
            origin.engine_id("deadbeef"),
            other_database.engine_id("deadbeef")
        );
        assert_ne!(
            origin.engine_id("deadbeef"),
            recreated.engine_id("deadbeef")
        );
        assert_eq!(Origin::from_engine_id("deadbeef"), Ok(None));
        assert_eq!(Origin::from_engine_id("deadbeef::1::cafebabe"), Ok(None));
        assert!(Origin::from_engine_id("pgdf-bad").is_err());
    }
}
