-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Invoice Approval Pipeline — demo schema
-- Run once to create tables. Safe to re-run (uses IF NOT EXISTS + TRUNCATE).

CREATE EXTENSION IF NOT EXISTS pg_durable;

CREATE SCHEMA IF NOT EXISTS demo;

-- Main invoices table
CREATE TABLE IF NOT EXISTS demo.invoices (
    id BIGSERIAL PRIMARY KEY,
    description TEXT NOT NULL,
    raw_amount TEXT NOT NULL,
    vendor TEXT,
    category TEXT,
    amount NUMERIC,
    status TEXT NOT NULL DEFAULT 'pending',
    -- Status lifecycle: pending → processing → approved | awaiting_approval → approved | rejected | failed
    instance_id TEXT,
    approved_by TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ
);

-- Audit trail
CREATE TABLE IF NOT EXISTS demo.invoice_audit (
    id BIGSERIAL PRIMARY KEY,
    invoice_id BIGINT NOT NULL REFERENCES demo.invoices(id) ON DELETE CASCADE,
    action TEXT NOT NULL,
    details JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Reset for clean demo
TRUNCATE TABLE demo.invoice_audit, demo.invoices RESTART IDENTITY;

SELECT 'Schema ready.' AS result;
