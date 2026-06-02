#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

"""Extract top-level DO blocks from SQL file(s) for isolated pgspot scanning.

pgspot marks a file "search_path secure" after the first function that sets a
trusted search_path, then skips the unqualified-reference checks on later
top-level statements. Anonymous DO blocks don't inherit that search_path at run
time, so an unqualified reference inside one is a real CVE-2018-1058 surface the
whole-file pass misses. This pulls each top-level DO block into its own file,
prefixed with a plain `CREATE SCHEMA df;` (gives df.* trusted context without
tripping PS010), so scanning them in isolation catches those references. It is a
targeted guard for DO blocks only; keep other install DDL schema-qualified.

Usage: extract-do-blocks.py OUTDIR FILE [FILE ...]
Writes <OUTDIR>/<basename>.doN.sql per DO block and prints each path. Exits 0
even when none are found.
"""

import os
import sys

from pglast import ast, parse_sql, split


def extract(path, outdir):
    with open(path, encoding="utf-8") as fh:
        sql = fh.read()

    written = []
    base = os.path.basename(path)
    index = 0
    for stmt in split(sql):
        try:
            node = parse_sql(stmt)[0].stmt
        except Exception:
            # A fragment pglast can re-split but not re-parse in isolation is not
            # a DO block we can check; the whole-file pass still covers the file.
            continue
        if not isinstance(node, ast.DoStmt):
            continue
        index += 1
        out_path = os.path.join(outdir, f"{base}.do{index}.sql")
        with open(out_path, "w", encoding="utf-8") as out:
            # Plain CREATE SCHEMA df (not IF NOT EXISTS) gives df trusted-schema
            # context without tripping PS010.
            out.write("CREATE SCHEMA df;\n")
            out.write(stmt)
            out.write(";\n")
        written.append(out_path)
    return written


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: extract-do-blocks.py OUTDIR FILE [FILE ...]\n")
        return 2
    outdir = argv[1]
    os.makedirs(outdir, exist_ok=True)
    for path in argv[2:]:
        for out_path in extract(path, outdir):
            print(out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
