// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Build script to embed build timestamp

use std::process::Command;

fn main() {
    // Get current timestamp in UTC
    let output = Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|_| "unknown".to_string());

    println!("cargo:rustc-env=BUILD_TIMESTAMP={output}");
    println!("cargo:rerun-if-changed=build.rs");
}
