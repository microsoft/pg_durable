//! Function template support for pg_durable
//!
//! This module implements reusable workflow templates using the SQL-native DSL syntax.
//! Templates store DSL expressions with {placeholder} variables that are substituted
//! at orchestration time by the standard variable substitution mechanism.

use pgrx::prelude::*;
use pgrx::JsonB;

use crate::{dsl, explain};

// ============================================================================
// Template Management Functions
// ============================================================================

/// Register a new template
#[pg_extern(schema = "df")]
fn create_template(
    name: &str,
    dsl_template: &str,
    description: default!(Option<&str>, "NULL"),
) -> Result<String, String> {
    // Basic validation
    if name.is_empty() {
        return Err("Template name cannot be empty".to_string());
    }

    // Check if active template already exists
    let exists_query = format!(
        "SELECT 1 FROM df.templates WHERE name = '{}' AND active = true",
        name.replace('\'', "''")
    );
    let exists: bool = Spi::get_one::<i32>(&exists_query).ok().flatten().is_some();

    if exists {
        return Err(format!(
            "Template '{}' already exists. Use df.update_template() to modify it or df.drop_template() to deactivate it.",
            name
        ));
    }

    // Insert into df.templates
    let desc_value = description
        .map(|d| format!("'{}'", d.replace('\'', "''")))
        .unwrap_or_else(|| "NULL".to_string());

    let insert_query = format!(
        "INSERT INTO df.templates (name, dsl_template, description, created_by) \
         VALUES ('{}', '{}', {}, current_user)",
        name.replace('\'', "''"),
        dsl_template.replace('\'', "''"),
        desc_value
    );

    Spi::run(&insert_query).map_err(|e| format!("Failed to register template: {:?}", e))?;

    Ok(format!("Template '{}' registered successfully", name))
}

/// Instantiate a template and start a workflow with local variables
#[pg_extern(schema = "df")]
fn start_template(
    template_name: &str,
    label: default!(Option<&str>, "NULL"),
    local_vars: default!(JsonB, "'{}'"),
) -> Result<String, String> {
    // Load active template from database
    let load_query = format!(
        "SELECT id, dsl_template \
         FROM df.templates \
         WHERE name = '{}' AND active = true",
        template_name.replace('\'', "''")
    );

    let template_data: Option<(i64, String)> = Spi::connect(|client| {
        let table = client.select(&load_query, None, &[]).ok()?;

        for row in table {
            if let (Ok(Some(id)), Ok(Some(dsl_template))) =
                (row.get::<i64>(1), row.get::<String>(2))
            {
                return Some((id, dsl_template));
            }
        }
        None
    });

    let (template_id, dsl_template) =
        template_data.ok_or_else(|| format!("Active template '{}' not found", template_name))?;

    // Evaluate the DSL expression to get a Durofut JSON
    // The dsl_template might be something like: df.sql('SELECT ...') or operators like 'SELECT 1' ~> 'SELECT 2'
    let durofut_json = match Spi::get_one::<String>(&format!("SELECT {}", dsl_template)) {
        Ok(Some(json)) => json,
        _ => {
            // If evaluation fails, assume it's plain SQL and call df.sql() on it
            Spi::get_one::<String>(&format!(
                "SELECT df.sql('{}')",
                dsl_template.replace('\'', "''")
            ))
            .map_err(|e| format!("Failed to evaluate template as SQL: {:?}", e))?
            .ok_or_else(|| "Template SQL evaluation returned NULL".to_string())?
        }
    };

    // Start the workflow using the evaluated Durofut with local variables
    // Variables are substituted at orchestration time by the standard mechanism
    let instance_id = dsl::start(&durofut_json, label.map(|s| s as &str), Some(local_vars));

    // Update instance with template_id
    let update_query = format!(
        "UPDATE df.instances SET template_id = {} WHERE id = '{}'",
        template_id,
        instance_id.replace('\'', "''")
    );

    Spi::run(&update_query)
        .map_err(|e| format!("Failed to update instance with template_id: {:?}", e))?;

    Ok(instance_id)
}

/// Mark a template as inactive (soft delete)
#[pg_extern(schema = "df")]
fn drop_template(name: &str) -> Result<String, String> {
    // Check if active template exists
    let exists_query = format!(
        "SELECT 1 FROM df.templates WHERE name = '{}' AND active = true",
        name.replace('\'', "''")
    );
    let exists: bool = Spi::get_one::<i32>(&exists_query).ok().flatten().is_some();

    if !exists {
        return Err(format!("Active template '{}' does not exist", name));
    }

    // Mark template as inactive
    let update_query = format!(
        "UPDATE df.templates SET active = false WHERE name = '{}' AND active = true",
        name.replace('\'', "''")
    );
    Spi::run(&update_query).map_err(|e| format!("Failed to drop template: {:?}", e))?;

    Ok(format!("Template '{}' marked as inactive", name))
}

/// Update a template
/// If dsl_template is provided: creates new version (marks old inactive)
/// If only description is provided: updates in place
#[pg_extern(schema = "df")]
fn update_template(
    name: &str,
    dsl_template: default!(Option<&str>, "NULL"),
    description: default!(Option<&str>, "NULL"),
) -> Result<String, String> {
    // At least one parameter must be provided
    if dsl_template.is_none() && description.is_none() {
        return Err("At least one of dsl_template or description must be provided".to_string());
    }

    // Load current active template
    let load_query = format!(
        "SELECT id, description \
         FROM df.templates \
         WHERE name = '{}' AND active = true",
        name.replace('\'', "''")
    );

    let current_template: Option<(i64, Option<String>)> = Spi::connect(|client| {
        let table = client.select(&load_query, None, &[]).ok()?;

        for row in table {
            if let Ok(Some(id)) = row.get::<i64>(1) {
                let description = row.get::<String>(2).ok().flatten();
                return Some((id, description));
            }
        }
        None
    });

    let (_current_id, current_desc) =
        current_template.ok_or_else(|| format!("Active template '{}' not found", name))?;

    if let Some(new_dsl) = dsl_template {
        // DSL is changing - create new version
        let final_description = description.or(current_desc.as_deref());

        // Mark old version inactive
        let deactivate_query = format!(
            "UPDATE df.templates SET active = false WHERE name = '{}' AND active = true",
            name.replace('\'', "''")
        );
        Spi::run(&deactivate_query)
            .map_err(|e| format!("Failed to deactivate old template version: {:?}", e))?;

        // Insert new version
        let desc_value = final_description
            .map(|d| format!("'{}'", d.replace('\'', "''")))
            .unwrap_or_else(|| "NULL".to_string());

        let insert_query = format!(
            "INSERT INTO df.templates (name, dsl_template, description, created_by, active) \
             VALUES ('{}', '{}', {}, current_user, true)",
            name.replace('\'', "''"),
            new_dsl.replace('\'', "''"),
            desc_value
        );

        Spi::run(&insert_query)
            .map_err(|e| format!("Failed to create new template version: {:?}", e))?;

        Ok(format!(
            "Template '{}' updated with new DSL (new version created)",
            name
        ))
    } else {
        // Only description is changing - update in place
        let desc_value = description
            .map(|d| format!("'{}'", d.replace('\'', "''")))
            .unwrap_or_else(|| "NULL".to_string());

        let update_query = format!(
            "UPDATE df.templates SET description = {} WHERE name = '{}' AND active = true",
            desc_value,
            name.replace('\'', "''")
        );

        Spi::run(&update_query)
            .map_err(|e| format!("Failed to update template description: {:?}", e))?;

        Ok(format!("Template '{}' description updated", name))
    }
}

/// Get details of a specific template
#[pg_extern(schema = "df")]
fn get_template(name: &str) -> Result<JsonB, String> {
    let query = format!(
        "SELECT id, name, dsl_template, description, active, created_at, created_by \
         FROM df.templates \
         WHERE name = '{}' AND active = true",
        name.replace('\'', "''")
    );

    Spi::connect(|client| {
        let table = client.select(&query, None, &[]).map_err(|e| format!("Query failed: {:?}", e))?;

        for row in table {
            if let (Ok(Some(id)), Ok(Some(name)), Ok(Some(dsl_template))) = (
                row.get::<i64>(1),
                row.get::<String>(2),
                row.get::<String>(3),
            ) {
                let description = row.get::<String>(4).ok().flatten();
                let active = row.get::<bool>(5).ok().flatten().unwrap_or(false);
                let created_at = row.get::<String>(6).ok().flatten();
                let created_by = row.get::<String>(7).ok().flatten();

                let mut result = serde_json::json!({
                    "id": id,
                    "name": name,
                    "dsl_template": dsl_template,
                    "active": active,
                });

                if let Some(desc) = description {
                    result["description"] = serde_json::Value::String(desc);
                }
                if let Some(created) = created_at {
                    result["created_at"] = serde_json::Value::String(created);
                }
                if let Some(creator) = created_by {
                    result["created_by"] = serde_json::Value::String(creator);
                }

                return Ok(Some(JsonB(result)));
            }
        }

        Err(format!("Active template '{}' not found", name))
    })
}

/// List all active templates
#[pg_extern(schema = "df")]
fn list_templates(
    name_pattern: default!(Option<&str>, "NULL"),
    created_by_user: default!(Option<&str>, "NULL"),
) -> Result<JsonB, String> {
    let mut conditions = vec!["active = true".to_string()];

    if let Some(pattern) = name_pattern {
        conditions.push(format!(
            "name LIKE '{}'",
            pattern.replace('\'', "''").replace('*', "%")
        ));
    }

    if let Some(user) = created_by_user {
        conditions.push(format!("created_by = '{}'", user.replace('\'', "''")));
    }

    let where_clause = conditions.join(" AND ");
    let query = format!(
        "SELECT id, name, description, created_at, created_by \
         FROM df.templates \
         WHERE {} \
         ORDER BY name",
        where_clause
    );

    Spi::connect(|client| {
        let table = client.select(&query, None, &[]).map_err(|e| format!("Query failed: {:?}", e))?;

        let mut templates = Vec::new();

        for row in table {
            if let (Ok(Some(id)), Ok(Some(name))) = (row.get::<i64>(1), row.get::<String>(2)) {
                let description = row.get::<String>(3).ok().flatten();
                let created_at = row.get::<String>(4).ok().flatten();
                let created_by = row.get::<String>(5).ok().flatten();

                let mut template = serde_json::json!({
                    "id": id,
                    "name": name,
                });

                if let Some(desc) = description {
                    template["description"] = serde_json::Value::String(desc);
                }
                if let Some(created) = created_at {
                    template["created_at"] = serde_json::Value::String(created);
                }
                if let Some(creator) = created_by {
                    template["created_by"] = serde_json::Value::String(creator);
                }

                templates.push(template);
            }
        }

        Ok(Some(JsonB(serde_json::json!(templates))))
    })
}

/// Explain what a template would do (shows DSL structure without variable substitution)
#[pg_extern(schema = "df")]
fn explain_template(template_name: &str) -> Result<String, String> {
    // Load active template
    let load_query = format!(
        "SELECT dsl_template \
         FROM df.templates \
         WHERE name = '{}' AND active = true",
        template_name.replace('\'', "''")
    );

    let dsl_template: Option<String> = Spi::connect(|client| {
        let table = client.select(&load_query, None, &[]).ok()?;

        for row in table {
            if let Ok(Some(dsl_template)) = row.get::<String>(1) {
                return Some(dsl_template);
            }
        }
        None
    });

    let dsl_template =
        dsl_template.ok_or_else(|| format!("Active template '{}' not found", template_name))?;

    // Call df.explain on the DSL (variables are shown as {placeholders})
    Ok(explain::explain(&dsl_template))
}
