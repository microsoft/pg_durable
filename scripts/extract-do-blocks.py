#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

"""Extract top-level DO blocks from SQL file(s) for isolated pgspot scanning.

Why this exists
---------------
pgspot scans a whole file and, once it has seen a function that establishes a
trusted search_path (``CREATE FUNCTION ... SET search_path = ..., df, ...`` with
``CREATE SCHEMA df`` earlier in the file), it marks the top-level state as
"search_path secure" and exempts every SUBSEQUENT top-level statement from the
unqualified-reference rules (PS001/PS016/PS017).

Anonymous ``DO`` blocks, however, do NOT inherit a function's ``SET search_path``
at run time -- they execute under the installing role's *session* search_path.
An unqualified reference inside a DO block is therefore a genuine CVE-2018-1058
surface, yet pgspot's whole-file pass masks it.

This script pulls each top-level ``DO`` block out and writes it to its own file,
prefixed with a plain ``CREATE SCHEMA df;`` (so ``df.``-qualified references have
trusted-schema context, and -- being a plain CREATE, not ``IF NOT EXISTS`` -- it
does not itself trip PS010). Scanning those files in isolation defeats the leak
for the DO-block class.

This is a TARGETED regression guard for anonymous DO blocks, not a complete fix
for pgspot's whole-file search_path leak; other statement classes that cannot
carry their own search_path are guarded by manually schema-qualifying the
install DDL (see docs/upgrade-testing.md).

Usage:
    extract-do-blocks.py OUTDIR FILE [FILE ...]

Writes ``<OUTDIR>/<basename>.doN.sql`` for each DO block found and prints each
written path on stdout. Exits 0 even when no DO blocks are found.
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
