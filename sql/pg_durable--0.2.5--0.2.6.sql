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
