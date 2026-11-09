#!/usr/bin/env python3
"""Collect a comparable inventory of application-schema objects.

Used to check the claim "a repository-only rebuild reproduces production". It
lists the objects the migrations are responsible for, scoped to the application
schemas (`public` and `private`), skipping Supabase platform schemas whose
contents are not governed by these migrations.

    python3 tools/migration_recovery/schema_inventory.py --out <file.json>
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import psycopg2
except ImportError:
    psycopg2 = None  # only needed for --out against a local database

SCHEMAS = "('public', 'private')"

# Objects that exist only because of the local replay shim, not because of a
# difference in the migrations. public.digest() is the pgcrypto stub that
# replay_local.py installs in place of the missing extension.
IGNORE = {
    "replay": {"function": ["public.digest(bytea, text)"]},
    "production": {},
}

QUERIES = {
    "relation": f"""
        SELECT n.nspname || '.' || c.relname || ' [' || c.relkind::text || ']'
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname IN {SCHEMAS} AND c.relkind IN ('r','v','m','p')
         ORDER BY 1
    """,
    "function": f"""
        SELECT n.nspname || '.' || p.proname || '('
               || pg_get_function_identity_arguments(p.oid) || ')'
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname IN {SCHEMAS}
         ORDER BY 1
    """,
    "trigger": f"""
        SELECT n.nspname || '.' || c.relname || ' -> ' || t.tgname::text
          FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname IN {SCHEMAS} AND NOT t.tgisinternal
         ORDER BY 1
    """,
    "policy": f"""
        SELECT n.nspname || '.' || c.relname || ' -> ' || pol.polname::text
          FROM pg_policy pol
          JOIN pg_class c ON c.oid = pol.polrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname IN {SCHEMAS}
         ORDER BY 1
    """,
    "index": f"""
        SELECT n.nspname || '.' || ci.relname
          FROM pg_class ci
          JOIN pg_namespace n ON n.oid = ci.relnamespace
          JOIN pg_index i ON i.indexrelid = ci.oid
          JOIN pg_class c ON c.oid = i.indrelid
          JOIN pg_namespace cn ON cn.oid = c.relnamespace
         WHERE n.nspname IN {SCHEMAS} AND cn.nspname IN {SCHEMAS}
         ORDER BY 1
    """,
}


def collect(cur) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for kind, sql in QUERIES.items():
        cur.execute(sql)
        out[kind] = [row[0] for row in cur.fetchall()]
    return out


def compare(prod: dict, local: dict) -> tuple[bool, list[str]]:
    """Diff two inventories. Returns (identical, human-readable findings)."""
    findings: list[str] = []
    identical = True
    kinds = sorted((set(prod) | set(local)) - {k for k in prod if k.startswith("_")})
    for kind in kinds:
        p, l = set(prod.get(kind, [])), set(local.get(kind, []))
        p -= set(IGNORE.get("production", {}).get(kind, []))
        l -= set(IGNORE.get("replay", {}).get(kind, []))
        only_prod, only_local = sorted(p - l), sorted(l - p)
        if only_prod or only_local:
            identical = False
        findings.append(
            f"{kind:<9} production={len(p):<4} replay={len(l):<4} "
            f"only-in-production={len(only_prod)} only-in-replay={len(only_local)}"
        )
        for item in only_prod:
            findings.append(f"    - production only: {item}")
        for item in only_local:
            findings.append(f"    + replay only:     {item}")
    return identical, findings


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--prod", type=Path, help="inventory JSON captured from production")
    ap.add_argument("--local", type=Path, help="inventory JSON captured from the replay")
    ap.add_argument("--out", type=Path, help="write an inventory from DATABASE_URL")
    args = ap.parse_args()

    if args.out:
        import os
        import tempfile

        import pgserver

        if psycopg2 is None:
            print("psycopg2 is required", file=sys.stderr)
            return 2
        db_url = os.environ.get("DATABASE_URL")
        if db_url:
            conn = psycopg2.connect(db_url)
        else:
            tmp = tempfile.mkdtemp(prefix="inventory-")
            db = pgserver.get_server(Path(tmp) / "pgdata")
            conn = psycopg2.connect(db.get_uri())
        conn.autocommit = True
        cur = conn.cursor()
        args.out.write_text(json.dumps(collect(cur), indent=2))
        print(f"wrote {args.out}")
        return 0

    if args.prod and args.local:
        prod = json.loads(args.prod.read_text())
        local = json.loads(args.local.read_text())
        identical, findings = compare(prod, local)
        print("\n".join(findings))
        print("\nIDENTICAL" if identical else "\nDIFFERENCES FOUND")
        return 0 if identical else 1

    ap.error("use --out, or both --prod and --local")
    return 2


if __name__ == "__main__":
    sys.exit(main())
