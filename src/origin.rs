use pgrx::prelude::*;
use sqlx::{postgres::PgConnectOptions, PgPool, Postgres, Transaction};
use std::{
    str::FromStr,
    sync::{Arc, OnceLock},
    time::Duration,
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use uuid::Uuid;

use crate::types;

static ORIGIN_CONNECTION_SLOTS: OnceLock<Arc<Semaphore>> = OnceLock::new();

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
    let database = Spi::get_one::<String>("SELECT pg_catalog.current_database()::text")
        .map_err(|error| error.to_string())?
        .ok_or("Caller database is unavailable")?;
    if database == types::get_database() {
        return Ok(local_id.to_string());
    }
    let installation_id = Spi::get_one::<String>("SELECT id::text FROM df._installation")
        .map_err(|error| format!("Origin installation unavailable: {error}"))?
        .ok_or("Origin installation identity is missing")?;
    let origin = Origin {
        database_oid: unsafe { pgrx::pg_sys::MyDatabaseId.to_u32() },
        installation_id: Uuid::parse_str(&installation_id).map_err(|error| error.to_string())?,
    };
    Ok(origin.engine_id(local_id))
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
    guard: Option<Transaction<'static, Postgres>>,
    permit: Option<OwnedSemaphorePermit>,
}

impl Route {
    pub async fn close(mut self) {
        if let Some(guard) = self.guard.take() {
            let _ = guard.rollback().await;
        }
        if self.permit.is_some() {
            self.pool.close().await;
        }
    }
}

impl Drop for Route {
    fn drop(&mut self) {
        if let Some(permit) = self.permit.take() {
            let pool = self.pool.clone();
            let guard = self.guard.take();
            tokio::spawn(async move {
                if let Some(guard) = guard {
                    let _ = guard.rollback().await;
                }
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
                guard: None,
                permit: None,
            });
        };
        crate::worker::register_origin(&self.control, &origin).await?;
        self.connect(&origin).await
    }

    pub async fn connect(&self, origin: &Origin) -> Result<Route, String> {
        let permit = acquire_connections(2).await?;
        let database: String = sqlx::query_scalar(
            "SELECT datname FROM pg_catalog.pg_database WHERE oid = $1::bigint::oid AND datallowconn",
        )
        .bind(i64::from(origin.database_oid))
        .fetch_optional(self.control.as_ref())
        .await
        .map_err(|error| format!("Origin database lookup failed: {error}"))?
        .ok_or("Origin database removed or connections disabled")?;
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(2)
            .acquire_timeout(Duration::from_secs(5))
            .after_connect(|connection, _| {
                Box::pin(async move {
                    sqlx::query(
                        "SELECT pg_catalog.set_config('transaction_timeout', '0', false)
                         WHERE pg_catalog.current_setting('transaction_timeout', true) IS NOT NULL",
                    )
                    .execute(connection)
                    .await?;
                    Ok(())
                })
            })
            .connect_with(
                self.connection_options
                    .clone()
                    .database(&database)
                    .options([
                        ("lock_timeout", "1500ms"),
                        ("statement_timeout", "5s"),
                        ("idle_in_transaction_session_timeout", "0"),
                    ]),
            )
            .await
            .map_err(|error| format!("Origin database connection failed: {error}"))?;
        let mut route = Route {
            pool: Arc::new(pool),
            database: Some(database),
            guard: None,
            permit: Some(permit),
        };
        let mut guard = route
            .pool
            .begin()
            .await
            .map_err(|error| error.to_string())?;
        sqlx::query("LOCK TABLE df._installation, df.instances, df.nodes IN ACCESS SHARE MODE")
            .execute(&mut *guard)
            .await
            .map_err(|error| error.to_string())?;
        let valid: bool = sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM df._installation i
             JOIN pg_catalog.pg_class c ON c.oid = 'df._installation'::regclass
             JOIN pg_catalog.pg_depend d ON d.objid = c.oid
               AND d.classid = 'pg_catalog.pg_class'::regclass AND d.deptype = 'e'
             JOIN pg_catalog.pg_extension e ON e.oid = d.refobjid AND e.extname = 'pg_durable'
             WHERE i.id = $1 AND (SELECT oid FROM pg_catalog.pg_database
                 WHERE datname = pg_catalog.current_database()) = $2::bigint::oid)",
        )
        .bind(origin.installation_id)
        .bind(i64::from(origin.database_oid))
        .fetch_one(&mut *guard)
        .await
        .map_err(|error| error.to_string())?;
        if !valid {
            return Err("Origin installation removed or replaced".to_string());
        }
        route.guard = Some(guard);
        Ok(route)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
