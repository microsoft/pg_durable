#!/usr/bin/env python3
"""Generate per-function migration diff with full context."""
import subprocess, sys, os, tempfile, textwrap

def psql(db_url, query):
    r = subprocess.run(
        ["psql", db_url, "-t", "-A", "-c", query],
        capture_output=True, text=True
    )
    return r.stdout.strip()

def psql_exec(db_url, cmd):
    subprocess.run(["psql", db_url, "-q", "-v", "ON_ERROR_STOP=1", "-c", cmd],
                   capture_output=True, text=True)

def psql_file(db_url, schema, filepath):
    subprocess.run(
        ["psql", db_url, "-q", "-v", "ON_ERROR_STOP=1",
         "-c", f"SET search_path TO {schema};", "-f", filepath],
        capture_output=True, text=True
    )

def get_funcs(db_url, schema):
    """Returns dict of {name(args): definition}"""
    sigs = psql(db_url, f"""
        SELECT p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
        FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = '{schema}' ORDER BY p.proname;
    """).split('\n')
    
    result = {}
    for sig in sigs:
        if not sig.strip():
            continue
        defn = psql(db_url, f"""
            SELECT pg_get_functiondef(p.oid)
            FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = '{schema}'
              AND p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' = '{sig}';
        """)
        defn = defn.replace(schema, 'SCHEMA')
        result[sig] = defn
    return result

def get_tables(db_url, schema):
    """Returns dict of {table_name: [(col, type, nullable, default)]}"""
    rows = psql(db_url, f"""
        SELECT table_name || '|' || column_name || '|' || UPPER(data_type) || '|' || is_nullable || '|' || COALESCE(column_default, '')
        FROM information_schema.columns WHERE table_schema='{schema}'
        ORDER BY table_name, ordinal_position;
    """).split('\n')
    
    tables = {}
    for row in rows:
        if not row.strip():
            continue
        parts = row.split('|')
        tbl = parts[0]
        if tbl not in tables:
            tables[tbl] = []
        col_str = f"{parts[1]} {parts[2]}"
        if parts[3] == 'NO':
            col_str += " NOT NULL"
        if parts[4]:
            col_str += f" DEFAULT {parts[4]}"
        tables[tbl].append((parts[1], col_str))
    return tables

def get_indexes(db_url, schema):
    rows = psql(db_url, f"""
        SELECT indexname, indexdef FROM pg_indexes 
        WHERE schemaname='{schema}' AND indexname NOT LIKE '%_pkey' ORDER BY indexname;
    """).split('\n')
    result = {}
    for row in rows:
        if not row.strip() or '|' not in row:
            continue
        name, defn = row.split('|', 1)
        result[name] = defn.replace(schema, 'SCHEMA')
    return result

def diff_lines(before_text, after_text):
    """Generate diff with full context (huge context window)."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.sql', delete=False) as bf:
        bf.write(before_text)
        bf_name = bf.name
    with tempfile.NamedTemporaryFile(mode='w', suffix='.sql', delete=False) as af:
        af.write(after_text)
        af_name = af.name
    
    r = subprocess.run(["diff", "-U99999", bf_name, af_name], capture_output=True, text=True)
    os.unlink(bf_name)
    os.unlink(af_name)
    
    # Skip the --- +++ header lines
    lines = r.stdout.split('\n')
    result = []
    for line in lines:
        if line.startswith('---') or line.startswith('+++') or line.startswith('@@'):
            continue
        result.append(line)
    return '\n'.join(result)

def main():
    project_dir = sys.argv[1]
    migration_num = int(sys.argv[2])
    db_url = sys.argv[3]
    
    padded = f"{migration_num:04d}"
    os.chdir(project_dir)
    
    # Find migration file
    import glob as g
    files = g.glob(f"migrations/{padded}_*.sql")
    if not files:
        print(f"No migration file found for {padded}")
        sys.exit(1)
    migration_name = os.path.basename(files[0])
    
    ts = str(os.getpid())
    before_schema = f"fdiff_b_{padded}_{ts}"
    after_schema = f"fdiff_a_{padded}_{ts}"
    
    try:
        # Create schemas and apply migrations
        psql_exec(db_url, f"CREATE SCHEMA {before_schema};")
        psql_exec(db_url, f"CREATE SCHEMA {after_schema};")
        
        for i in range(1, migration_num):
            p = f"{i:04d}"
            fs = g.glob(f"migrations/{p}_*.sql")
            if fs:
                psql_file(db_url, before_schema, fs[0])
        
        for i in range(1, migration_num + 1):
            p = f"{i:04d}"
            fs = g.glob(f"migrations/{p}_*.sql")
            if fs:
                psql_file(db_url, after_schema, fs[0])
        
        # Get data
        before_funcs = get_funcs(db_url, before_schema)
        after_funcs = get_funcs(db_url, after_schema)
        before_tables = get_tables(db_url, before_schema)
        after_tables = get_tables(db_url, after_schema)
        before_indexes = get_indexes(db_url, before_schema)
        after_indexes = get_indexes(db_url, after_schema)
        
        # Build output
        out = []
        out.append(f"# Diff for migration {padded}")
        out.append(f"")
        out.append(f"**Migration file:** `{migration_name}`")
        out.append(f"")
        out.append("Each changed function is shown **in full** with `+`/`-` markers on changed lines.")
        out.append("")
        
        # Table changes
        out.append("## Table Changes")
        out.append("")
        
        for tbl in sorted(after_tables.keys()):
            if tbl.startswith('_'):
                continue
            if tbl not in before_tables:
                out.append(f"### `{tbl}` — NEW")
                out.append("```sql")
                for _, col_str in after_tables[tbl]:
                    out.append(f"  {col_str}")
                out.append("```")
                out.append("")
            else:
                before_cols = {c[0] for c in before_tables[tbl]}
                after_cols = after_tables[tbl]
                new_cols = [c for c in after_cols if c[0] not in before_cols]
                if new_cols:
                    out.append(f"### `{tbl}` — Modified")
                    out.append("```diff")
                    for col_name, col_str in after_cols:
                        if col_name in before_cols:
                            out.append(f"  {col_str}")
                        else:
                            out.append(f"+ {col_str}")
                    out.append("```")
                    out.append("")
        
        # Index changes
        new_idx = {k: v for k, v in after_indexes.items() if k not in before_indexes}
        if new_idx:
            out.append("## New Indexes")
            out.append("")
            for name, defn in sorted(new_idx.items()):
                out.append(f"### `{name}`")
                out.append("```sql")
                out.append(defn)
                out.append("```")
                out.append("")
        
        # Function changes
        out.append("## Function Changes")
        out.append("")
        
        # Match before/after funcs by name
        before_by_name = {}
        for sig, defn in before_funcs.items():
            name = sig.split('(')[0]
            before_by_name[name] = (sig, defn)
        
        after_by_name = {}
        for sig, defn in after_funcs.items():
            name = sig.split('(')[0]
            after_by_name[name] = (sig, defn)
        
        for name in sorted(after_by_name.keys()):
            after_sig, after_def = after_by_name[name]
            
            if name not in before_by_name:
                # New function
                out.append(f"### `{name}` — NEW")
                out.append("```sql")
                out.append(after_def)
                out.append("```")
                out.append("")
            else:
                before_sig, before_def = before_by_name[name]
                if before_def == after_def:
                    continue  # Unchanged
                
                # Signature change?
                sig_changed = before_sig != after_sig
                if sig_changed:
                    out.append(f"### `{name}` — Signature Changed + Body Modified")
                    out.append("```diff")
                    out.append(f"- {before_sig}")
                    out.append(f"+ {after_sig}")
                    out.append("```")
                else:
                    out.append(f"### `{name}` — Body Modified")
                
                out.append("")
                out.append("Full function with diff:")
                out.append("```diff")
                out.append(diff_lines(before_def, after_def))
                out.append("```")
                out.append("")
        
        # Removed functions
        for name in sorted(before_by_name.keys()):
            if name not in after_by_name:
                sig, _ = before_by_name[name]
                out.append(f"### `{name}` — REMOVED")
                out.append(f"Was: `{sig}`")
                out.append("")
        
        out.append("---")
        
        output_file = f"migrations/{padded}_diff.md"
        with open(output_file, 'w') as f:
            f.write('\n'.join(out) + '\n')
        
        print(f"Done: {output_file} ({len(out)} lines)")
    
    finally:
        psql_exec(db_url, f"DROP SCHEMA IF EXISTS {before_schema} CASCADE;")
        psql_exec(db_url, f"DROP SCHEMA IF EXISTS {after_schema} CASCADE;")

if __name__ == '__main__':
    main()
