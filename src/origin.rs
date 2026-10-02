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

#[derive(Debug)]
pub(crate) enum RoutingError {
    Retryable(String),
    Permanent(String),
}

impl RoutingError {
    fn database(operation: &str, error: sqlx::Error) -> Self {
        let message = format!("{operation}: {error}");
        if crate::activities::load_function_graph::is_retryable_database_error(&error) {
            Self::Retryable(message)
        } else {
            Self::Permanent(message)
        }
    }
}

impl From<RoutingError> for String {
    fn from(error: RoutingError) -> Self {
        match error {
            RoutingError::Retryable(message) | RoutingError::Permanent(message) => message,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MetadataScope {
    Installation,
    Graph,
}

impl MetadataScope {
    fn names(self) -> &'static [&'static str] {
        match self {
            Self::Installation => &["_installation"],
            Self::Graph => &["_installation", "instances", "nodes"],
        }
    }

    fn lock_sql(self) -> &'static str {
        match self {
            Self::Installation => "LOCK TABLE ONLY df._installation IN ACCESS SHARE MODE",
            Self::Graph => "LOCK TABLE ONLY df._installation, ONLY df.instances, ONLY df.nodes IN ACCESS SHARE MODE",
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct MetadataIdentity {
    scope: MetadataScope,
    // Extension, namespace, trusted owner, relation, name.
    objects: Vec<(i64, i64, i64, i64, String)>,
}

/// Catalog-only: never prepare a query against a satellite object until its
/// kind, membership and ownership have been independently attested.
pub(crate) async fn attest_metadata(
    connection: &mut PgConnection,
    origin: &Origin,
    scope: MetadataScope,
) -> Result<MetadataIdentity, sqlx::Error> {
    let objects: Vec<(i64, i64, i64, i64, String)> = sqlx::query_as(
        "SELECT e.oid::pg_catalog.int8, n.oid::pg_catalog.int8,
                e.extowner::pg_catalog.int8, c.oid::pg_catalog.int8, c.relname::pg_catalog.text
         FROM pg_catalog.pg_extension AS e
         JOIN pg_catalog.pg_depend AS d
           ON d.refobjid OPERATOR(pg_catalog.=) e.oid
          AND d.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_extension'::pg_catalog.regclass
          AND d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
          AND d.deptype OPERATOR(pg_catalog.=) 'e'
          AND d.objsubid OPERATOR(pg_catalog.=) 0 AND d.refobjsubid OPERATOR(pg_catalog.=) 0
         JOIN pg_catalog.pg_class AS c ON c.oid OPERATOR(pg_catalog.=) d.objid
         JOIN pg_catalog.pg_namespace AS n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
         WHERE e.extname OPERATOR(pg_catalog.=) 'pg_durable'
           AND n.nspname OPERATOR(pg_catalog.=) 'df'
           AND c.relname::pg_catalog.text OPERATOR(pg_catalog.=) ANY($1::pg_catalog.text[])
           AND c.relkind OPERATOR(pg_catalog.=) 'r'
           AND c.relpersistence OPERATOR(pg_catalog.=) 'p'
           AND c.relowner OPERATOR(pg_catalog.=) e.extowner
           AND n.nspowner OPERATOR(pg_catalog.=) e.extowner
           AND (c.relname OPERATOR(pg_catalog.<>) '_installation' OR EXISTS (
               SELECT 1 FROM pg_catalog.pg_attribute AS a
               WHERE a.attrelid OPERATOR(pg_catalog.=) c.oid
                 AND a.attname OPERATOR(pg_catalog.=) 'id' AND NOT a.attisdropped
                 AND a.atttypid OPERATOR(pg_catalog.=) 'pg_catalog.uuid'::pg_catalog.regtype))
           AND (SELECT oid FROM pg_catalog.pg_database
                WHERE datname OPERATOR(pg_catalog.=) pg_catalog.current_database())
               OPERATOR(pg_catalog.=) $2::pg_catalog.int8::pg_catalog.oid
         ORDER BY c.relname::pg_catalog.text COLLATE pg_catalog.\"C\"",
    )
    .bind(scope.names())
    .bind(i64::from(origin.database_oid))
    .fetch_all(connection)
    .await?;
    if objects.len() != scope.names().len() {
        return Err(sqlx::Error::Protocol(REPLACED.into()));
    }
    Ok(MetadataIdentity { scope, objects })
}

/// LOCK does not evaluate view expressions, but a name can change while it
/// waits. Re-attest the exact OIDs in a separate statement before any data read.
/// In repeatable-read transactions this must be the first snapshot-taking
/// statement; obtain `before` outside that transaction.
pub(crate) async fn lock_attested_metadata(
    connection: &mut PgConnection,
    origin: &Origin,
    before: &MetadataIdentity,
) -> Result<(), sqlx::Error> {
    sqlx::query(before.scope.lock_sql())
        .execute(&mut *connection)
        .await?;
    let after = attest_metadata(connection, origin, before.scope).await?;
    if before != &after {
        return Err(sqlx::Error::Protocol(REPLACED.into()));
    }
    Ok(())
}

pub(crate) async fn installation_matches(
    connection: &mut PgConnection,
    origin: &Origin,
) -> Result<bool, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM ONLY df._installation AS i
         WHERE i.id OPERATOR(pg_catalog.=) $1::pg_catalog.uuid)",
    )
    .bind(origin.installation_id)
    .fetch_one(connection)
    .await
}

pub(crate) async fn check_identity(
    connection: &mut PgConnection,
    origin: &Origin,
) -> Result<(), sqlx::Error> {
    if !installation_matches(connection, origin).await? {
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

/// The caller owns a READ COMMITTED transaction and its lifetime.
pub(crate) async fn lock_and_validate(
    connection: &mut PgConnection,
    origin: &Origin,
) -> Result<(), sqlx::Error> {
    let before = attest_metadata(connection, origin, MetadataScope::Installation).await?;
    lock_attested_metadata(connection, origin, &before).await?;
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
        let before = attest_metadata(&mut tx, origin, MetadataScope::Graph).await?;
        lock_attested_metadata(&mut tx, origin, &before).await?;
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
        self.validate_typed().await.map_err(String::from)
    }

    async fn validate_typed(&self) -> Result<(), RoutingError> {
        if let Some(origin) = self.origin.as_ref() {
            let mut tx =
                self.pool.begin().await.map_err(|error| {
                    RoutingError::database("Origin admission unavailable", error)
                })?;
            sqlx::query("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
                .execute(&mut *tx)
                .await
                .map_err(|error| RoutingError::database("Origin admission isolation", error))?;
            configure_metadata_transaction(&mut tx)
                .await
                .map_err(|error| RoutingError::database("Origin admission timeouts", error))?;
            lock_and_validate(&mut tx, origin)
                .await
                .map_err(|error| RoutingError::database("Origin admission unavailable", error))?;
            tx.rollback()
                .await
                .map_err(|error| RoutingError::database("Origin admission close failed", error))?;
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
        self.route_typed(engine_id).await.map_err(String::from)
    }

    pub async fn route_typed(&self, engine_id: &str) -> Result<Route, RoutingError> {
        let Some(origin) = Origin::from_engine_id(engine_id).map_err(RoutingError::Permanent)?
        else {
            return Ok(Route {
                pool: self.control.clone(),
                database: None,
                origin: None,
                permit: None,
            });
        };
        crate::worker::register_origin(&self.control, &origin)
            .await
            .map_err(|error| RoutingError::database("Register origin", error))?;
        self.connect_typed(&origin).await
    }

    pub async fn connect(&self, origin: &Origin) -> Result<Route, String> {
        self.connect_typed(origin).await.map_err(String::from)
    }

    async fn connect_typed(&self, origin: &Origin) -> Result<Route, RoutingError> {
        let permit = acquire_connections(1)
            .await
            .map_err(RoutingError::Retryable)?;
        let (database, allowed): (String, bool) = sqlx::query_as(
            "SELECT datname, datallowconn FROM pg_catalog.pg_database
             WHERE oid OPERATOR(pg_catalog.=) $1::pg_catalog.int8::pg_catalog.oid",
        )
        .bind(i64::from(origin.database_oid))
        .fetch_optional(self.control.as_ref())
        .await
        .map_err(|error| RoutingError::database("Origin database lookup failed", error))?
        .ok_or_else(|| RoutingError::Permanent("Origin database removed".into()))?;
        if !allowed {
            return Err(RoutingError::Retryable(
                "Origin database connections disabled".into(),
            ));
        }
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(1)
            .acquire_timeout(Duration::from_secs(5))
            .connect_with(
                self.connection_options
                    .clone()
                    .database(&database)
                    .options([
                        ("search_path", "pg_catalog,pg_temp"),
                        ("lock_timeout", "1500ms"),
                        ("statement_timeout", "5s"),
                    ]),
            )
            .await
            .map_err(|error| RoutingError::database("Origin database connection failed", error))?;
        let route = Route {
            pool: Arc::new(pool),
            database: Some(database),
            origin: Some(origin.clone()),
            permit: Some(permit),
        };
        route.validate_typed().await?;
        Ok(route)
    }
}

#[cfg(any(test, feature = "pg_test"))]
pub(crate) async fn metadata_test_connection(admin: &str, database: &str) -> PgConnection {
    let mut connection = types::connect_as_user(admin, Some(database)).await.unwrap();
    // These tests temporarily alter the same installation catalogs. pgrx runs
    // test functions concurrently, so serialize their DDL, not production work.
    sqlx::query("SELECT pg_catalog.pg_advisory_lock(401, 12)")
        .execute(&mut connection)
        .await
        .unwrap();
    connection
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use super::*;

    async fn current_origin(connection: &mut PgConnection) -> Origin {
        let (database_oid, installation_id): (i64, Uuid) = sqlx::query_as(
            "SELECT d.oid::bigint, i.id FROM pg_catalog.pg_database d CROSS JOIN df._installation i
             WHERE d.datname = pg_catalog.current_database()",
        )
        .fetch_one(connection)
        .await
        .unwrap();
        Origin {
            database_oid: u32::try_from(database_oid).unwrap(),
            installation_id,
        }
    }

    #[pg_test]
    fn metadata_attestation_rejects_counterfeits() {
        let admin = Spi::get_one::<String>("SELECT current_user::text")
            .unwrap()
            .unwrap();
        let database = Spi::get_one::<String>("SELECT current_database()::text")
            .unwrap()
            .unwrap();
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
            let mut connection = metadata_test_connection(&admin, &database).await;
            let origin = current_origin(&mut connection).await;
            let mut tx = connection.begin().await.unwrap();
            sqlx::raw_sql(
                "CREATE ROLE origin_untrusted_test;
                 CREATE FUNCTION public.origin_security_canary() RETURNS uuid
                 LANGUAGE plpgsql IMMUTABLE SECURITY INVOKER AS $fn$
                 BEGIN RAISE EXCEPTION 'ORIGIN_SECURITY_CANARY'; END $fn$",
            ).execute(&mut *tx).await.unwrap();
            let genuine = attest_metadata(&mut tx, &origin, MetadataScope::Graph).await.unwrap();
            for relation in ["_installation", "instances", "nodes"] {
                sqlx::query("SAVEPOINT counterfeit").execute(&mut *tx).await.unwrap();
                sqlx::raw_sql(&format!(
                    "ALTER TABLE df.{relation} RENAME TO original_metadata;
                     CREATE VIEW df.{relation} AS SELECT public.origin_security_canary() AS id"
                )).execute(&mut *tx).await.unwrap();
                // Prove the canary would execute if a data query were prepared.
                sqlx::query("SAVEPOINT positive_control").execute(&mut *tx).await.unwrap();
                let error = sqlx::query(&format!("SELECT id FROM df.{relation}"))
                    .fetch_all(&mut *tx).await.unwrap_err();
                assert!(error.to_string().contains("ORIGIN_SECURITY_CANARY"));
                sqlx::query("ROLLBACK TO positive_control").execute(&mut *tx).await.unwrap();
                let error = attest_metadata(&mut tx, &origin, MetadataScope::Graph).await.unwrap_err();
                assert!(matches!(error, sqlx::Error::Protocol(ref message) if message == REPLACED));
                // Also exercise the post-lock path with a prior genuine attestation.
                let error = lock_attested_metadata(&mut tx, &origin, &genuine).await.unwrap_err();
                assert!(matches!(error, sqlx::Error::Protocol(ref message) if message == REPLACED));
                sqlx::query(&format!("ALTER EXTENSION pg_durable ADD VIEW df.{relation}"))
                    .execute(&mut *tx).await.unwrap();
                let error = attest_metadata(&mut tx, &origin, MetadataScope::Graph).await.unwrap_err();
                assert!(matches!(error, sqlx::Error::Protocol(ref message) if message == REPLACED));
                sqlx::query("ROLLBACK TO counterfeit").execute(&mut *tx).await.unwrap();
            }
            for alteration in [
                "ALTER TABLE df._installation OWNER TO origin_untrusted_test",
                "ALTER SCHEMA df OWNER TO origin_untrusted_test",
                "ALTER EXTENSION pg_durable DROP TABLE df._installation",
                "ALTER TABLE df._installation RENAME COLUMN id TO old_id; ALTER TABLE df._installation ADD COLUMN id text",
                "ALTER TABLE df._installation SET UNLOGGED",
            ] {
                sqlx::query("SAVEPOINT altered").execute(&mut *tx).await.unwrap();
                sqlx::raw_sql(alteration).execute(&mut *tx).await.unwrap();
                assert!(attest_metadata(&mut tx, &origin, MetadataScope::Installation).await.is_err(), "{alteration}");
                sqlx::query("ROLLBACK TO altered").execute(&mut *tx).await.unwrap();
            }
            // ONLY prevents inherited rows from supplying a different UUID.
            sqlx::raw_sql(
                "CREATE TABLE public.origin_identity_child () INHERITS (df._installation);
                 INSERT INTO public.origin_identity_child(singleton, id)
                 VALUES (true, '00000000-0000-0000-0000-000000000001')",
            ).execute(&mut *tx).await.unwrap();
            let false_origin = Origin { installation_id: Uuid::from_u128(1), ..origin.clone() };
            assert!(!installation_matches(&mut tx, &false_origin).await.unwrap());
            tx.rollback().await.unwrap();
            connection.close().await.unwrap();
        });
    }

    #[pg_test]
    fn metadata_post_lock_snapshot_detects_replacement_after_wait() {
        let admin = Spi::get_one::<String>("SELECT current_user::text")
            .unwrap()
            .unwrap();
        let database = Spi::get_one::<String>("SELECT current_database()::text")
            .unwrap()
            .unwrap();
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
            let mut admin_connection = metadata_test_connection(&admin, &database).await;
            let mut reader = types::connect_as_user(&admin, Some(&database)).await.unwrap();
            let origin = current_origin(&mut admin_connection).await;
            let reader_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
                .fetch_one(&mut reader).await.unwrap();
            sqlx::raw_sql(
                "CREATE FUNCTION public.origin_wait_canary() RETURNS uuid
                 LANGUAGE plpgsql IMMUTABLE SECURITY INVOKER AS $fn$
                 BEGIN RAISE EXCEPTION 'ORIGIN_WAIT_CANARY'; END $fn$",
            ).execute(&mut admin_connection).await.unwrap();
            for isolation in ["READ COMMITTED", "REPEATABLE READ"] {
                for replacement in ["VIEW", "TABLE"] {
                let before = attest_metadata(&mut reader, &origin, MetadataScope::Installation).await.unwrap();
                let mut ddl = admin_connection.begin().await.unwrap();
                sqlx::query("ALTER TABLE df._installation RENAME TO original_identity")
                    .execute(&mut *ddl).await.unwrap();
                if replacement == "VIEW" {
                    sqlx::query("CREATE VIEW df._installation AS SELECT public.origin_wait_canary() AS id")
                        .execute(&mut *ddl).await.unwrap();
                } else {
                    sqlx::query("CREATE TABLE df._installation(id uuid)").execute(&mut *ddl).await.unwrap();
                    sqlx::query("INSERT INTO df._installation VALUES ($1)")
                        .bind(origin.installation_id).execute(&mut *ddl).await.unwrap();
                    sqlx::query("ALTER EXTENSION pg_durable ADD TABLE df._installation")
                        .execute(&mut *ddl).await.unwrap();
                }
                sqlx::query(&format!("BEGIN ISOLATION LEVEL {isolation} READ ONLY"))
                    .execute(&mut reader).await.unwrap();
                {
                let waiting = lock_attested_metadata(&mut reader, &origin, &before);
                tokio::pin!(waiting);
                let deadline = tokio::time::sleep(Duration::from_secs(5));
                tokio::pin!(deadline);
                loop {
                    tokio::select! {
                        result = &mut waiting => panic!("lock did not wait: {result:?}"),
                        _ = &mut deadline => panic!("reader lock wait not observed"),
                        _ = tokio::time::sleep(Duration::from_millis(10)) => {
                            let blocked: bool = sqlx::query_scalar(
                                "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_locks
                                 WHERE pid = $1 AND locktype = 'relation' AND NOT granted)",
                            ).bind(reader_pid).fetch_one(&mut *ddl).await.unwrap();
                            if blocked { break; }
                        }
                    }
                }
                ddl.commit().await.unwrap();
                let error = waiting.await.unwrap_err();
                assert!(matches!(error, sqlx::Error::Protocol(ref message) if message == REPLACED), "{error}");
                }
                sqlx::query("ROLLBACK").execute(&mut reader).await.unwrap();
                if replacement == "TABLE" {
                    sqlx::query("ALTER EXTENSION pg_durable DROP TABLE df._installation")
                        .execute(&mut admin_connection).await.unwrap();
                }
                sqlx::raw_sql(&format!(
                    "DROP {replacement} df._installation;
                     ALTER TABLE df.original_identity RENAME TO _installation",
                )).execute(&mut admin_connection).await.unwrap();
                }
            }
            sqlx::query("DROP FUNCTION public.origin_wait_canary()").execute(&mut admin_connection).await.unwrap();
            reader.close().await.unwrap();
            admin_connection.close().await.unwrap();
        });
    }

    #[pg_test]
    fn execution_fence_preserves_autocommit_and_connection_identity() {
        let admin = Spi::get_one::<String>("SELECT current_user::text")
            .unwrap()
            .unwrap();
        let database = Spi::get_one::<String>("SELECT current_database()::text")
            .unwrap()
            .unwrap();
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
            let mut connection = metadata_test_connection(&admin, &database).await;
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
    fn routing_errors_preserve_admission_classification() {
        assert!(matches!(
            RoutingError::database("lookup", sqlx::Error::PoolTimedOut),
            RoutingError::Retryable(_)
        ));
        assert!(matches!(
            RoutingError::database("identity", sqlx::Error::Protocol(REPLACED.into())),
            RoutingError::Permanent(_)
        ));
    }

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
