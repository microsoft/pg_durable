//! Visual explain functionality for durable SQL functions

use pgrx::prelude::*;
use std::collections::HashMap;

/// Represents a node for visualization
#[derive(Debug, Clone)]
struct ExplainNode {
    #[allow(dead_code)]
    id: String,
    node_type: String,
    query: Option<String>,
    result_name: Option<String>,
    left_node: Option<String>,
    right_node: Option<String>,
    status: Option<String>,
    #[allow(dead_code)]
    result: Option<String>,
}

/// Explain a durable function - either an existing instance or a DSL expression
///
/// Usage:
/// ```sql
/// -- Explain existing instance
/// SELECT df.explain('abc12345');
///
/// -- Explain a DSL expression (dry-run, no execution)
/// SELECT df.explain($$
///     df.sql('SELECT 1') ~> df.sleep(60) ~> df.sql('SELECT 2')
/// $$);
/// ```
#[pg_extern(schema = "df")]
pub fn explain(input: &str) -> String {
    let trimmed = input.trim();

    // Detect if input is an instance_id (8 hex chars) or a DSL expression
    let is_instance_id = trimmed.len() == 8 && trimmed.chars().all(|c| c.is_ascii_hexdigit());

    if is_instance_id {
        explain_instance(trimmed)
    } else {
        explain_expression(trimmed)
    }
}

/// Explain an existing durable function instance
fn explain_instance(instance_id: &str) -> String {
    // Get instance info from PostgreSQL
    let instance_info: Option<(String, Option<String>, String)> = Spi::connect(|client| {
        let sql = format!(
            "SELECT root_node, label, status FROM df.instances WHERE id = '{}'",
            instance_id.replace('\'', "''")
        );
        if let Ok(table) = client.select(&sql, None, &[]) {
            for row in table {
                let root_node: Option<String> = row.get(1).ok().flatten();
                let label: Option<String> = row.get(2).ok().flatten();
                let status: Option<String> = row.get(3).ok().flatten();
                if let Some(root) = root_node {
                    return Some((root, label, status.unwrap_or_default()));
                }
            }
        }
        None
    });

    let (root_id, label, pg_status) = match instance_info {
        Some(info) => info,
        None => return format!("Instance '{instance_id}' not found"),
    };

    // Get status and output from Duroxide
    let (duroxide_status, output) = get_duroxide_instance_info(instance_id);

    // Load all nodes for this instance
    let nodes = load_nodes_from_table("df.nodes", Some(instance_id));

    if nodes.is_empty() {
        return format!("No nodes found for instance '{instance_id}'");
    }

    // Build header
    let mut result = String::new();

    // Instance ID and label
    if let Some(lbl) = label {
        result.push_str(&format!("Instance: {instance_id} ({lbl})\n"));
    } else {
        result.push_str(&format!("Instance: {instance_id}\n"));
    }

    // Status with icon
    let status = if !duroxide_status.is_empty() {
        &duroxide_status
    } else {
        &pg_status
    };
    let status_icon = match status.to_lowercase().as_str() {
        "completed" | "continuedabnew" => "✓",
        "failed" | "canceled" => "✗",
        "running" => "⏳",
        _ => "○",
    };
    result.push_str(&format!("Status:   {status_icon} {status}\n"));

    // Output (truncated if too long)
    if let Some(out) = output {
        let truncated = if out.len() > 60 {
            format!("{}...", &out[..57])
        } else {
            out
        };
        result.push_str(&format!("Output:   {truncated}\n"));
    }

    result.push('\n');

    // Build tree visualization
    result.push_str(&build_tree_visualization(&root_id, &nodes, true));

    result
}

/// Get instance info from Duroxide store
fn get_duroxide_instance_info(instance_id: &str) -> (String, Option<String>) {
    use crate::types::{backend_provider_config, postgres_connection_string};
    use duroxide::Client;
    use duroxide_pg_opt::PostgresProvider;
    use std::sync::Arc;

    let pg_conn_str = postgres_connection_string();

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(_) => return (String::new(), None),
    };

    rt.block_on(async {
        let store = match PostgresProvider::new_with_config(&pg_conn_str, backend_provider_config())
            .await
        {
            Ok(s) => Arc::new(s),
            Err(_) => return (String::new(), None),
        };

        let client = Client::new(store);

        match client.get_instance_info(instance_id).await {
            Ok(info) => (info.status, info.output),
            Err(_) => (String::new(), None),
        }
    })
}

/// Explain a DSL expression without executing it
fn explain_expression(expr: &str) -> String {
    // 1. Create temp table for dry-run nodes
    if let Err(e) = Spi::run(
        r#"CREATE TEMP TABLE IF NOT EXISTS _durable_explain_nodes (
            id VARCHAR(8) PRIMARY KEY,
            instance_id VARCHAR(8),
            node_type TEXT NOT NULL,
            query TEXT,
            result_name TEXT,
            left_node VARCHAR(8),
            right_node VARCHAR(8),
            status TEXT DEFAULT 'pending',
            result JSONB,
            error TEXT,
            created_at TIMESTAMPTZ DEFAULT now(),
            updated_at TIMESTAMPTZ DEFAULT now()
        )"#,
    ) {
        return format!("Failed to create temp table: {e:?}");
    }

    // Clear any previous dry-run nodes
    let _ = Spi::run("TRUNCATE _durable_explain_nodes");

    // 2. Set explain mode flag
    let _ = Spi::run("SET LOCAL df._explain_mode = 'true'");

    // 3. Execute the expression to populate temp table
    let durofut_json: Result<Option<String>, _> = Spi::get_one(&format!("SELECT {expr}"));

    // 4. Reset explain mode
    let _ = Spi::run("RESET df._explain_mode");

    let root_json = match durofut_json {
        Ok(Some(json)) => json,
        Ok(None) => return "Expression returned NULL".to_string(),
        Err(e) => return format!("Failed to evaluate expression: {e:?}"),
    };

    // Parse the root node ID from the Durofut JSON
    let root_id = match serde_json::from_str::<serde_json::Value>(&root_json) {
        Ok(v) => v["node_id"].as_str().unwrap_or("").to_string(),
        Err(e) => return format!("Failed to parse result: {e:?}"),
    };

    if root_id.is_empty() {
        return "Could not determine root node".to_string();
    }

    // 5. Load nodes from temp table
    let nodes = load_nodes_from_table("_durable_explain_nodes", None);

    // 6. Build visualization (without status markers for dry-run)
    let result = build_tree_visualization(&root_id, &nodes, false);

    // 7. Cleanup temp table
    let _ = Spi::run("DROP TABLE IF EXISTS _durable_explain_nodes");

    result
}

/// Load nodes from a table into a HashMap
fn load_nodes_from_table(table: &str, instance_id: Option<&str>) -> HashMap<String, ExplainNode> {
    let sql = if let Some(id) = instance_id {
        format!(
            r#"SELECT id, node_type, query, result_name, left_node, right_node, status, result::text
               FROM {} WHERE instance_id = '{}'"#,
            table,
            id.replace('\'', "''")
        )
    } else {
        format!(
            "SELECT id, node_type, query, result_name, left_node, right_node, status, result::text FROM {table}"
        )
    };

    let mut nodes = HashMap::new();

    Spi::connect(|client| {
        if let Ok(table_result) = client.select(&sql, None, &[]) {
            for row in table_result {
                if let Ok(Some(id)) = row.get::<String>(1) {
                    let node = ExplainNode {
                        id: id.clone(),
                        node_type: row.get(2).ok().flatten().unwrap_or_default(),
                        query: row.get(3).ok().flatten(),
                        result_name: row.get(4).ok().flatten(),
                        left_node: row.get(5).ok().flatten(),
                        right_node: row.get(6).ok().flatten(),
                        status: row.get(7).ok().flatten(),
                        result: row.get(8).ok().flatten(),
                    };
                    nodes.insert(id, node);
                }
            }
        }
    });

    nodes
}

/// Build a tree visualization of the function graph
fn build_tree_visualization(
    root_id: &str,
    nodes: &HashMap<String, ExplainNode>,
    show_status: bool,
) -> String {
    let mut output = String::new();
    build_tree_recursive(root_id, nodes, "", true, &mut output, show_status);

    // Pad each line for cleaner output with trailing spaces
    let lines: Vec<&str> = output.trim_end().lines().collect();
    let max_len = lines.iter().map(|l| l.chars().count()).max().unwrap_or(0);
    let padded_width = max_len + 4; // Add 4 spaces of padding

    lines
        .iter()
        .map(|line| format!("{line:padded_width$}"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Recursively build the tree visualization
fn build_tree_recursive(
    node_id: &str,
    nodes: &HashMap<String, ExplainNode>,
    prefix: &str,
    is_last: bool,
    output: &mut String,
    show_status: bool,
) {
    let node = match nodes.get(node_id) {
        Some(n) => n,
        None => return,
    };

    // Determine the connector
    let connector = if prefix.is_empty() {
        ""
    } else if is_last {
        "└─"
    } else {
        "├─"
    };

    // Get status marker
    let status_marker = if show_status {
        match node.status.as_deref() {
            Some("completed") => " ✓",
            Some("failed") => " ✗",
            Some("running") => " ⏳",
            Some("pending") => " ○",
            _ => "",
        }
    } else {
        ""
    };

    // Format the node line based on type
    let node_display = format_node_display(node);

    // Handle THEN nodes specially - we want to show sequence with arrows
    if node.node_type == "THEN" {
        // For THEN, we flatten the sequence and show with arrows
        let sequence = collect_sequence(node_id, nodes);

        for (i, seq_node_id) in sequence.iter().enumerate() {
            if let Some(seq_node) = nodes.get(seq_node_id) {
                // All sequence items use the same prefix, just different connectors
                let seq_connector = if i == 0 {
                    connector.to_string()
                } else {
                    "→ ".to_string()
                };

                let seq_status = if show_status {
                    match seq_node.status.as_deref() {
                        Some("completed") => " ✓",
                        Some("failed") => " ✗",
                        Some("running") => " ⏳",
                        Some("pending") => " ○",
                        _ => "",
                    }
                } else {
                    ""
                };

                let seq_display = format_node_display(seq_node);
                output.push_str(&format!(
                    "{prefix}{seq_connector}{seq_display}{seq_status}\n"
                ));

                // If this node has children (not THEN), recurse
                if seq_node.node_type != "THEN"
                    && seq_node.node_type != "SQL"
                    && seq_node.node_type != "SLEEP"
                    && seq_node.node_type != "WAIT_SCHEDULE"
                    && seq_node.node_type != "HTTP"
                {
                    let child_prefix = format!("{prefix}    ");
                    render_children(seq_node, nodes, &child_prefix, output, show_status);
                }
            }
        }
    } else {
        // Regular node - output it
        output.push_str(&format!(
            "{prefix}{connector}{node_display}{status_marker}\n"
        ));

        // Recurse into children
        let child_prefix = if prefix.is_empty() {
            "    ".to_string()
        } else if is_last {
            format!("{prefix}    ")
        } else {
            format!("{prefix}│   ")
        };

        render_children(node, nodes, &child_prefix, output, show_status);
    }
}

/// Collect all nodes in a THEN sequence (flattening nested THENs)
fn collect_sequence(node_id: &str, nodes: &HashMap<String, ExplainNode>) -> Vec<String> {
    let mut sequence = Vec::new();
    collect_sequence_recursive(node_id, nodes, &mut sequence);
    sequence
}

fn collect_sequence_recursive(
    node_id: &str,
    nodes: &HashMap<String, ExplainNode>,
    sequence: &mut Vec<String>,
) {
    if let Some(node) = nodes.get(node_id) {
        if node.node_type == "THEN" {
            // Recurse into left (first in sequence)
            if let Some(ref left) = node.left_node {
                collect_sequence_recursive(left, nodes, sequence);
            }
            // Recurse into right (next in sequence)
            if let Some(ref right) = node.right_node {
                collect_sequence_recursive(right, nodes, sequence);
            }
        } else {
            // Non-THEN node - add to sequence
            sequence.push(node_id.to_string());
        }
    }
}

/// Render children of a node
fn render_children(
    node: &ExplainNode,
    nodes: &HashMap<String, ExplainNode>,
    prefix: &str,
    output: &mut String,
    show_status: bool,
) {
    match node.node_type.as_str() {
        "LOOP" => {
            // Check for while-condition
            let condition_id = node
                .query
                .as_ref()
                .and_then(|q| serde_json::from_str::<serde_json::Value>(q).ok())
                .and_then(|v| v["condition_node"].as_str().map(|s| s.to_string()));

            if let Some(ref body_id) = node.left_node {
                output.push_str(&format!("{prefix}↻ body:\n"));
                build_tree_recursive(
                    body_id,
                    nodes,
                    &format!("{prefix}  "),
                    true,
                    output,
                    show_status,
                );
            }

            if let Some(ref cond_id) = condition_id {
                output.push_str(&format!("{prefix}? while:\n"));
                build_tree_recursive(
                    cond_id,
                    nodes,
                    &format!("{prefix}  "),
                    true,
                    output,
                    show_status,
                );
            }
        }
        "BREAK" => {
            // BREAK has no children, just the value in query
        }
        "IF" => {
            // Parse condition from query JSON
            let condition_id = node
                .query
                .as_ref()
                .and_then(|q| serde_json::from_str::<serde_json::Value>(q).ok())
                .and_then(|v| v["condition_node"].as_str().map(|s| s.to_string()));

            if let Some(ref cond_id) = condition_id {
                output.push_str(&format!("{prefix}? condition:\n"));
                build_tree_recursive(
                    cond_id,
                    nodes,
                    &format!("{prefix}  "),
                    true,
                    output,
                    show_status,
                );
            }

            if let Some(ref then_id) = node.left_node {
                output.push_str(&format!("{prefix}✓ then:\n"));
                build_tree_recursive(
                    then_id,
                    nodes,
                    &format!("{prefix}  "),
                    true,
                    output,
                    show_status,
                );
            }

            if let Some(ref else_id) = node.right_node {
                output.push_str(&format!("{prefix}✗ else:\n"));
                build_tree_recursive(
                    else_id,
                    nodes,
                    &format!("{prefix}  "),
                    true,
                    output,
                    show_status,
                );
            }
        }
        "JOIN" => {
            let mut branches = Vec::new();
            if let Some(ref left_id) = node.left_node {
                branches.push(left_id.clone());
            }
            if let Some(ref right_id) = node.right_node {
                branches.push(right_id.clone());
            }

            // Check for extra nodes in join3
            if let Some(ref query) = node.query {
                if let Ok(cfg) = serde_json::from_str::<serde_json::Value>(query) {
                    if let Some(extras) = cfg["extra_nodes"].as_array() {
                        for extra in extras {
                            if let Some(extra_id) = extra.as_str() {
                                branches.push(extra_id.to_string());
                            }
                        }
                    }
                }
            }

            let branch_count = branches.len();
            for (i, branch_id) in branches.iter().enumerate() {
                let is_last_branch = i == branch_count - 1;
                output.push_str(&format!("{}║ branch {}:\n", prefix, i + 1));
                build_tree_recursive(
                    branch_id,
                    nodes,
                    &format!("{prefix}  "),
                    is_last_branch,
                    output,
                    show_status,
                );
            }
        }
        _ => {
            // Leaf nodes (SQL, SLEEP, WAIT_SCHEDULE) have no children
        }
    }
}

/// Format a node for display
fn format_node_display(node: &ExplainNode) -> String {
    let name_suffix = node
        .result_name
        .as_ref()
        .map(|n| format!(" |=> '{n}'"))
        .unwrap_or_default();

    match node.node_type.as_str() {
        "SQL" => {
            let query = node.query.as_deref().unwrap_or("?");
            let truncated = if query.len() > 50 {
                format!("{}...", &query[..47])
            } else {
                query.to_string()
            };
            format!("SQL: {truncated}{name_suffix}")
        }
        "SLEEP" => {
            let seconds = node.query.as_deref().unwrap_or("?");
            format!("SLEEP {seconds}s{name_suffix}")
        }
        "WAIT_SCHEDULE" => {
            // Parse config to get cron expression and wait seconds
            let (cron, secs) = node
                .query
                .as_ref()
                .and_then(|q| serde_json::from_str::<serde_json::Value>(q).ok())
                .map(|cfg| {
                    let c = cfg["cron_expr"].as_str().unwrap_or("?").to_string();
                    let s = cfg["wait_seconds"].as_u64().unwrap_or(0);
                    (c, s)
                })
                .unwrap_or_else(|| ("?".to_string(), 0));
            format!("WAIT '{cron}' ({secs}s){name_suffix}")
        }
        "HTTP" => {
            // Parse config to get method and URL
            let (method, url) = node
                .query
                .as_ref()
                .and_then(|q| serde_json::from_str::<serde_json::Value>(q).ok())
                .map(|cfg| {
                    let method = cfg["method"].as_str().unwrap_or("POST");
                    let url = cfg["url"].as_str().unwrap_or("?");
                    // Truncate long URLs
                    let display_url = if url.len() > 40 {
                        format!("{}...", &url[..37])
                    } else {
                        url.to_string()
                    };
                    (method.to_string(), display_url)
                })
                .unwrap_or_else(|| ("?".to_string(), "?".to_string()));
            format!("HTTP {method} {url}{name_suffix}")
        }
        "SIGNAL" => {
            // Parse config to get signal name and timeout
            let (signal_name, timeout) = node
                .query
                .as_ref()
                .and_then(|q| serde_json::from_str::<serde_json::Value>(q).ok())
                .map(|cfg| {
                    let name = cfg["signal_name"].as_str().unwrap_or("?");
                    let timeout = cfg["timeout_seconds"].as_i64();
                    (name.to_string(), timeout)
                })
                .unwrap_or_else(|| ("?".to_string(), None));
            let timeout_str = timeout.map(|t| format!(" ({t}s)")).unwrap_or_default();
            format!("SIGNAL '{signal_name}'{timeout_str}{name_suffix}")
        }
        "LOOP" => {
            // Check if it has a while condition
            let has_condition = node
                .query
                .as_ref()
                .and_then(|q| serde_json::from_str::<serde_json::Value>(q).ok())
                .map(|cfg| cfg["condition_node"].is_string())
                .unwrap_or(false);
            if has_condition {
                format!("LOOP (while){name_suffix}")
            } else {
                format!("LOOP (infinite){name_suffix}")
            }
        }
        "BREAK" => {
            // Parse config to get break value
            let value = node
                .query
                .as_ref()
                .and_then(|q| serde_json::from_str::<serde_json::Value>(q).ok())
                .and_then(|cfg| cfg["break_value"].as_str().map(|s| s.to_string()));
            match value {
                Some(v) if v.len() > 20 => format!("BREAK '{}...'{}", &v[..17], name_suffix),
                Some(v) => format!("BREAK '{v}'{name_suffix}"),
                None => format!("BREAK{name_suffix}"),
            }
        }
        "IF" => format!("IF{name_suffix}"),
        "JOIN" => {
            // Count branches
            let mut count = 0;
            if node.left_node.is_some() {
                count += 1;
            }
            if node.right_node.is_some() {
                count += 1;
            }
            if let Some(ref query) = node.query {
                if let Ok(cfg) = serde_json::from_str::<serde_json::Value>(query) {
                    if let Some(extras) = cfg["extra_nodes"].as_array() {
                        count += extras.len();
                    }
                }
            }
            format!("JOIN ({count}){name_suffix}")
        }
        "THEN" => "SEQUENCE".to_string(), // Should rarely be seen due to flattening
        _ => node.node_type.clone(),
    }
}
