-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.5 -> 0.2.6
--
-- See docs/upgrade-testing.md for the upgrade-script and backward-compatibility
-- requirements (Scenario A / B1 / B2).
--
-- Preserve stack/resource errors while classifying plain SQL operands. A broad
-- WHEN OTHERS handler silently wrapped over-depth Durofut JSON as SQL.
CREATE OR REPLACE FUNCTION df.ensure_durofut(val text) RETURNS text AS $$
DECLARE
	node_type_val text;
BEGIN
	BEGIN
		node_type_val := (val::jsonb)->>'node_type';
		IF node_type_val IS NOT NULL THEN
			IF node_type_val NOT IN ('SQL', 'THEN', 'IF', 'JOIN', 'LOOP', 'BREAK', 'RACE', 'SLEEP', 'WAIT_SCHEDULE', 'HTTP', 'HTTP_MULTIPART', 'SIGNAL') THEN
				RAISE EXCEPTION 'Unknown node_type ''%''. Valid types: SQL, THEN, IF, JOIN, LOOP, BREAK, RACE, SLEEP, WAIT_SCHEDULE, HTTP, HTTP_MULTIPART, SIGNAL', node_type_val;
			END IF;
			RETURN val;
		END IF;
	EXCEPTION WHEN invalid_text_representation THEN
		NULL;
	WHEN raise_exception THEN
		RAISE;
	END;

	RETURN df.sql(val);
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, pg_temp;