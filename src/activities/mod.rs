// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Activities for pg_durable
//!
//! Each activity is in its own file with a co-located NAME constant.
//! This enables IDE navigation (F12 jumps to implementation).

pub mod execute_http;
pub mod execute_multipart;
pub mod execute_sql;
pub mod load_function_graph;
pub mod update_instance_status;
pub mod update_node_status;
