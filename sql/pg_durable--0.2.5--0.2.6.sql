-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.5 -> 0.2.6
--
-- See docs/upgrade-testing.md for the upgrade-script and backward-compatibility
-- requirements (Scenario A / B1 / B2).
--
-- The conditional operators now carry their first two operands as text until
-- !> completes the expression. df.if() performs Durofut normalization for all
-- three operands, removing the duplicated PL/pgSQL validator.
CREATE OR REPLACE FUNCTION df.if_then_op(condition text, then_branch text) RETURNS text AS $$
DECLARE
	result_obj jsonb;
BEGIN
	result_obj := pg_catalog.jsonb_build_object(
		'_partial_if', true,
		'condition', condition,
		'then_branch', then_branch
	);
	RETURN result_obj::pg_catalog.text;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, pg_temp;

CREATE OR REPLACE FUNCTION df.if_else_op(partial_if text, else_branch text) RETURNS text AS $$
DECLARE
	partial jsonb;
	cond_text text;
	then_text text;
BEGIN
	partial := partial_if::pg_catalog.jsonb;

	IF partial OPERATOR(pg_catalog.->>) '_partial_if' IS NULL THEN
		RAISE EXCEPTION 'Invalid if-then-else: left side of !> must be a ?> expression';
	END IF;

	-- ->> accepts both the new text operands and object operands emitted by the
	-- old helper, preserving partial expressions created before ALTER EXTENSION.
	cond_text := partial OPERATOR(pg_catalog.->>) 'condition';
	then_text := partial OPERATOR(pg_catalog.->>) 'then_branch';

	RETURN df.if(cond_text, then_text, else_branch);
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, pg_temp;

-- RESTRICT is intentional: do not silently remove customer-owned objects that
-- depend on this undocumented helper.
DROP FUNCTION df.ensure_durofut(text) RESTRICT;

-- df.wait_for_condition(): registry of orchestration nodes currently blocked on
-- a predicate.  The background worker's NOTIFY listener joins incoming payloads
-- against notify_key to decide which waiters to wake early.
--
-- instance_id is the *duroxide* instance id, not the 8-char df instance id: a
-- node inside a loop body runs in a subtree child instance whose id is the
-- composite "{parent}::{execution}::{root_node}".
CREATE TABLE df.condition_waiters (
	instance_id TEXT NOT NULL,
	node_id TEXT NOT NULL,
	notify_key TEXT NOT NULL,
	created_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.now(),
	PRIMARY KEY (instance_id, node_id)
);

CREATE INDEX idx_condition_waiters_notify_key ON df.condition_waiters(notify_key);

-- Admit the WAIT_CONDITION node type into the schema constraints. These mirror
-- VALID_NODE_TYPES in src/types.rs (the Rust constant is the canonical source).
-- The constraints are NOT VALID, so re-adding them does not rewrite existing rows.
ALTER TABLE df.nodes DROP CONSTRAINT nodes_node_type_chk;
ALTER TABLE df.nodes
	ADD CONSTRAINT nodes_node_type_chk
	CHECK (node_type OPERATOR(pg_catalog.=) ANY (ARRAY['SQL', 'THEN', 'IF', 'JOIN', 'LOOP', 'BREAK', 'RACE', 'SLEEP', 'WAIT_SCHEDULE', 'WAIT_CONDITION', 'HTTP', 'HTTP_MULTIPART', 'SIGNAL'])) NOT VALID;

ALTER TABLE df.nodes DROP CONSTRAINT nodes_structure_chk;
ALTER TABLE df.nodes
	ADD CONSTRAINT nodes_structure_chk
	CHECK (
		CASE
			WHEN node_type OPERATOR(pg_catalog.=) ANY (ARRAY['SQL', 'SLEEP', 'WAIT_SCHEDULE', 'WAIT_CONDITION', 'BREAK', 'HTTP', 'HTTP_MULTIPART', 'SIGNAL'])
				THEN left_node IS NULL AND right_node IS NULL AND query IS NOT NULL
			WHEN node_type OPERATOR(pg_catalog.=) 'THEN'
				THEN left_node IS NOT NULL AND right_node IS NOT NULL AND query IS NULL
			WHEN node_type OPERATOR(pg_catalog.=) 'IF'
				THEN left_node IS NOT NULL AND right_node IS NOT NULL AND query IS NOT NULL
			WHEN node_type OPERATOR(pg_catalog.=) 'LOOP'
				THEN left_node IS NOT NULL AND right_node IS NULL
			WHEN node_type OPERATOR(pg_catalog.=) 'JOIN'
				THEN left_node IS NOT NULL AND right_node IS NOT NULL
			WHEN node_type OPERATOR(pg_catalog.=) 'RACE'
				THEN left_node IS NOT NULL AND right_node IS NOT NULL AND query IS NULL
			ELSE FALSE
		END
	) NOT VALID;

-- df.wait_for_condition(): copied verbatim from the pgrx-generated fresh-install
-- DDL so the upgraded and fresh schemas match. New function, nothing to drop.
CREATE  FUNCTION df."wait_for_condition"(
	"condition" TEXT, /* &str */
	"max_check_interval" interval, /* pgrx::datum::interval::Interval */
	"notify_key" TEXT DEFAULT NULL /* core::option::Option<&str> */
) RETURNS TEXT /* alloc::string::String */

LANGUAGE c /* Rust */
AS 'MODULE_PATHNAME', 'wait_for_condition_wrapper';
