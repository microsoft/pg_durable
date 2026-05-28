// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Orchestrations for pg_durable
//!
//! ⚠️ DETERMINISTIC CODE ONLY in orchestration files!
//! - No I/O except through activities
//! - No random numbers, current time, or other non-deterministic sources
//! - Same input must always produce the same scheduling decisions

pub mod execute_function_graph;
