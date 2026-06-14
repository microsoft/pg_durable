// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! `pg_durable_matrix_gen` — deterministic generator for the Phase 2
//! combinator-nesting E2E test matrix (#232).
//!
//! It enumerates every combinator-nesting shape up to a bounded depth, renders
//! each to a pg_durable DSL program with marker leaves, and emits:
//!   * `<out>/sql/gen-NNNN.sql` — self-contained E2E tests (gitignored).
//!   * `<out>/manifest.json`    — the committed golden regression baseline.
//!
//! `--check` regenerates the manifest in memory and diffs it against the
//! committed copy, guarding that generation stays deterministic.
//!
//! Usage:
//!   pg_durable_matrix_gen [--max-depth N] [--combinators a,b,c] [--full]
//!                         [--loop-iters K] [--max-shapes N] [--no-seeds]
//!                         [--out DIR] [--check]

mod emit;
mod meta;
mod render;
mod shape;

// Phase 3 (#232): recursive proptest Strategy<Meta> + property suite. Test-only
// (depends on the `proptest` dev-dependency), so it never enters the generation
// binary and has no bearing on `--check` determinism or the committed goldens.
#[cfg(test)]
mod prop;

use emit::{manifest_json, sql_test, MatrixMeta, ShapeRecord};
use meta::{meta_manifest_json, meta_sql_test, registry, Relation};
use shape::{build_matrix, Comb};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const DEFAULT_COMBS: [Comb; 5] = [Comb::Seq, Comb::If, Comb::Loop, Comb::Join, Comb::Race];
const FULL_COMBS: [Comb; 6] = [
    Comb::Seq,
    Comb::If,
    Comb::Loop,
    Comb::Join,
    Comb::Join3,
    Comb::Race,
];

const DEFAULT_MAX_DEPTH: u32 = 2;
const DEFAULT_LOOP_ITERS: u64 = 2;
const DEFAULT_WAIT_TIMEOUT_SECS: u32 = 60;
const DEFAULT_QUARANTINE_TIMEOUT_SECS: u32 = 10;

struct Config {
    max_depth: u32,
    combinators: Vec<Comb>,
    loop_iters: u64,
    max_shapes: Option<usize>,
    include_seeds: bool,
    out: PathBuf,
    check: bool,
    wait_timeout: u32,
    quarantine_timeout: u32,
}

fn default_out() -> PathBuf {
    // CARGO_MANIFEST_DIR = .../tests/e2e/generated/generator; parent = .../generated.
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn print_help() {
    println!(
        "pg_durable_matrix_gen — Phase 2 combinator-nesting matrix generator (#232)\n\n\
Options:\n\
  --max-depth N        Maximum combinator-nesting depth (default {DEFAULT_MAX_DEPTH})\n\
  --combinators LIST   Comma list of: seq,if,loop,join,join3,race\n\
                       (default: seq,if,loop,join,race)\n\
  --full               Shortcut for the full set including join3\n\
  --loop-iters K       Iterations each generated loop runs (default {DEFAULT_LOOP_ITERS})\n\
  --max-shapes N       Cap (>=1) on the sorted shape list, applied AFTER enumeration;\n\
                       bounds output size, not enumeration cost at high depth\n\
  --no-seeds           Exclude the hand-written else/break seed shapes\n\
  --out DIR            Output dir (default: tests/e2e/generated)\n\
  --wait-timeout N     Seconds each test waits for completion (default {DEFAULT_WAIT_TIMEOUT_SECS})\n\
  --quarantine-timeout N  Seconds each QUARANTINED test waits (default {DEFAULT_QUARANTINE_TIMEOUT_SECS})\n\
  --check              Regenerate manifest in memory and diff vs committed copy\n\
  --help               Show this help"
    );
}

fn parse_args() -> Result<Option<Config>, String> {
    let mut cfg = Config {
        max_depth: DEFAULT_MAX_DEPTH,
        combinators: DEFAULT_COMBS.to_vec(),
        loop_iters: DEFAULT_LOOP_ITERS,
        max_shapes: None,
        include_seeds: true,
        out: default_out(),
        check: false,
        wait_timeout: DEFAULT_WAIT_TIMEOUT_SECS,
        quarantine_timeout: DEFAULT_QUARANTINE_TIMEOUT_SECS,
    };

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    let next = |i: &mut usize, flag: &str| -> Result<String, String> {
        *i += 1;
        args.get(*i)
            .cloned()
            .ok_or_else(|| format!("{flag} requires a value"))
    };

    while i < args.len() {
        let arg = args[i].as_str();
        match arg {
            "--help" | "-h" => {
                print_help();
                return Ok(None);
            }
            "--max-depth" => {
                cfg.max_depth = next(&mut i, arg)?
                    .parse()
                    .map_err(|_| "--max-depth must be a non-negative integer".to_string())?;
            }
            "--loop-iters" => {
                let k: u64 = next(&mut i, arg)?
                    .parse()
                    .map_err(|_| "--loop-iters must be an integer".to_string())?;
                if k < 1 {
                    return Err("--loop-iters must be >= 1".to_string());
                }
                cfg.loop_iters = k;
            }
            "--max-shapes" => {
                let n: usize = next(&mut i, arg)?
                    .parse()
                    .map_err(|_| "--max-shapes must be an integer".to_string())?;
                if n == 0 {
                    return Err("--max-shapes must be >= 1".to_string());
                }
                cfg.max_shapes = Some(n);
            }
            "--wait-timeout" => {
                let t: u32 = next(&mut i, arg)?
                    .parse()
                    .map_err(|_| "--wait-timeout must be a non-negative integer".to_string())?;
                if t < 1 {
                    return Err("--wait-timeout must be >= 1".to_string());
                }
                cfg.wait_timeout = t;
            }
            "--quarantine-timeout" => {
                let t: u32 = next(&mut i, arg)?.parse().map_err(|_| {
                    "--quarantine-timeout must be a non-negative integer".to_string()
                })?;
                if t < 1 {
                    return Err("--quarantine-timeout must be >= 1".to_string());
                }
                cfg.quarantine_timeout = t;
            }
            "--combinators" => {
                let list = next(&mut i, arg)?;
                let mut combs = Vec::new();
                for tok in list.split(',') {
                    if tok.trim().is_empty() {
                        continue;
                    }
                    combs.push(Comb::parse(tok)?);
                }
                if combs.is_empty() {
                    return Err("--combinators list is empty".to_string());
                }
                cfg.combinators = combs;
            }
            "--full" => {
                cfg.combinators = FULL_COMBS.to_vec();
            }
            "--no-seeds" => {
                cfg.include_seeds = false;
            }
            "--out" => {
                cfg.out = PathBuf::from(next(&mut i, arg)?);
            }
            "--check" => {
                cfg.check = true;
            }
            other => {
                return Err(format!("unknown argument '{other}' (try --help)"));
            }
        }
        i += 1;
    }

    Ok(Some(cfg))
}

/// Builds the ordered shape records (id + signature + dsl + expected counts).
fn build_records(cfg: &Config) -> Vec<ShapeRecord> {
    let shapes = build_matrix(
        &cfg.combinators,
        cfg.max_depth,
        cfg.include_seeds,
        cfg.max_shapes,
    );
    shapes
        .iter()
        .enumerate()
        .map(|(idx, shape)| {
            let id = format!("gen-{:04}", idx + 1);
            let rendered = render::render(shape, cfg.loop_iters, &id);
            let reason = shape.is_problematic();
            ShapeRecord {
                id,
                signature: shape.signature(),
                depth: shape.depth(),
                class: if reason.is_some() {
                    "quarantine"
                } else {
                    "live"
                },
                reason,
                dsl: rendered.dsl,
                expected: rendered.expected,
            }
        })
        .collect()
}

/// Reports the first line where two manifests diverge (for `--check`).
fn first_diff_line(committed: &str, fresh: &str) -> Option<usize> {
    let a: Vec<&str> = committed.lines().collect();
    let b: Vec<&str> = fresh.lines().collect();
    let max = a.len().max(b.len());
    for line in 0..max {
        if a.get(line) != b.get(line) {
            return Some(line + 1);
        }
    }
    None
}

/// Compares one freshly-generated artifact against its committed copy.
fn check_artifact(out: &Path, filename: &str, fresh: &str) -> bool {
    let path = out.join(filename);
    let committed = match std::fs::read_to_string(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("--check: cannot read {}: {e}", path.display());
            eprintln!("Run the generator without --check to create it.");
            return false;
        }
    };
    // Normalize line endings so a CRLF checkout never trips the comparison.
    let committed_norm = committed.replace("\r\n", "\n");
    if committed_norm == *fresh {
        println!("--check: {filename} is up to date ({} bytes).", fresh.len());
        true
    } else {
        eprintln!("--check: {filename} is STALE — regenerate it.");
        if let Some(line) = first_diff_line(&committed_norm, fresh) {
            eprintln!("First difference at line {line}.");
        }
        eprintln!("Regenerate: cargo run --manifest-path tests/e2e/generated/generator/Cargo.toml");
        false
    }
}

fn run_check(cfg: &Config, manifest: &str, meta_manifest: &str) -> ExitCode {
    let ok_matrix = check_artifact(&cfg.out, "manifest.json", manifest);
    let ok_meta = check_artifact(&cfg.out, "meta-manifest.json", meta_manifest);
    if ok_matrix && ok_meta {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

fn clean_generated_sql(sql_dir: &Path) {
    if let Ok(entries) = std::fs::read_dir(sql_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if (name.starts_with("gen-") || name.starts_with("meta-")) && name.ends_with(".sql") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}

fn run_generate(
    cfg: &Config,
    records: &[ShapeRecord],
    manifest: &str,
    relations: &[Relation],
    meta_manifest: &str,
) -> ExitCode {
    let sql_dir = cfg.out.join("sql");
    let quarantine_dir = cfg.out.join("quarantine");
    for dir in [&sql_dir, &quarantine_dir] {
        if let Err(e) = std::fs::create_dir_all(dir) {
            eprintln!("cannot create {}: {e}", dir.display());
            return ExitCode::FAILURE;
        }
        clean_generated_sql(dir);
    }

    let mut live = 0usize;
    let mut quarantined = 0usize;
    for rec in records {
        let (dir, timeout) = if rec.reason.is_some() {
            quarantined += 1;
            (&quarantine_dir, cfg.quarantine_timeout)
        } else {
            live += 1;
            (&sql_dir, cfg.wait_timeout)
        };
        let path = dir.join(format!("{}.sql", rec.id));
        if let Err(e) = std::fs::write(&path, sql_test(rec, timeout)) {
            eprintln!("cannot write {}: {e}", path.display());
            return ExitCode::FAILURE;
        }
    }

    // Phase 4 metamorphic relations are live → sql/ (blocking, collected by the
    // harness's --include-generated glob alongside the matrix tests).
    for rel in relations {
        let path = sql_dir.join(format!("{}.sql", rel.id));
        if let Err(e) = std::fs::write(&path, meta_sql_test(rel, cfg.wait_timeout)) {
            eprintln!("cannot write {}: {e}", path.display());
            return ExitCode::FAILURE;
        }
    }

    let manifest_path = cfg.out.join("manifest.json");
    if let Err(e) = std::fs::write(&manifest_path, manifest) {
        eprintln!("cannot write {}: {e}", manifest_path.display());
        return ExitCode::FAILURE;
    }
    let meta_manifest_path = cfg.out.join("meta-manifest.json");
    if let Err(e) = std::fs::write(&meta_manifest_path, meta_manifest) {
        eprintln!("cannot write {}: {e}", meta_manifest_path.display());
        return ExitCode::FAILURE;
    }

    println!(
        "Generated {} shape(s): {} live → {}, {} quarantined → {} (manifest: {})",
        records.len(),
        live,
        sql_dir.display(),
        quarantined,
        quarantine_dir.display(),
        manifest_path.display()
    );
    println!(
        "Generated {} metamorphic relation(s) → {} (manifest: {})",
        relations.len(),
        sql_dir.display(),
        meta_manifest_path.display()
    );
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    let cfg = match parse_args() {
        Ok(Some(cfg)) => cfg,
        Ok(None) => return ExitCode::SUCCESS, // --help
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };

    let records = build_records(&cfg);
    let matrix_meta = MatrixMeta {
        max_depth: cfg.max_depth,
        combinators: &cfg.combinators,
        loop_iters: cfg.loop_iters,
        include_seeds: cfg.include_seeds,
    };
    let manifest = manifest_json(&records, &matrix_meta);

    let relations = registry();
    let meta_manifest = meta_manifest_json(&relations);

    if cfg.check {
        run_check(&cfg, &manifest, &meta_manifest)
    } else {
        run_generate(&cfg, &records, &manifest, &relations, &meta_manifest)
    }
}
