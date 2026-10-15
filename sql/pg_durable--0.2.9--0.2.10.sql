CREATE FUNCTION df.managed_identity_admin()
RETURNS pg_catalog.void
LANGUAGE c STRICT
AS 'MODULE_PATHNAME', 'managed_identity_admin_wrapper';

REVOKE ALL ON FUNCTION df.managed_identity_admin() FROM PUBLIC;
COMMENT ON FUNCTION df.managed_identity_admin() IS
    'EXECUTE authorizes managed identity endpoint administration. Calling this function does not acquire tokens.';