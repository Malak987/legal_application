#!/usr/bin/env python3
"""Replay the recovered migrations against a throwaway local PostgreSQL cluster.

Purpose: validate that the executable migration set
(`supabase/migrations_executable/`) applies cleanly, in the recorded version
order, to an empty database — i.e. that a repository-only rebuild is possible.

This NEVER touches production. It starts a private PostgreSQL instance in a
temporary directory (via the `pgserver` wheel), applies
`bootstrap_supabase_shim.sql` to stand in for the Supabase platform objects, and
then runs each migration in order.

Requirements:  python3 -m venv .venv && .venv/bin/pip install pgserver psycopg2-binary
Usage:         .venv/bin/python tools/migration_recovery/replay_local.py
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    import pgserver
    import psycopg2
except ImportError:
    print("Missing dependencies. Run:\n"
          "  python3 -m venv .venv && .venv/bin/pip install pgserver psycopg2-binary",
          file=sys.stderr)
    raise SystemExit(2)

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SHIM = HERE / "bootstrap_supabase_shim.sql"
MIGRATIONS = ROOT / "supabase" / "migrations_executable"

# 20261029125246 is a DATA migration, not a schema migration: it promotes the
# existing 'malak@example.com' admin account to owner and deliberately raises if
# the row is not there ("Expected exactly one matching admin account"). An empty
# schema has no users at all, so it can only be exercised once that account
# exists. Seeding it is what lets the replay cover the migration's own guard
# logic; it is a fixture for this throwaway cluster only.
SEED_BEFORE = {
    "20261029125246": """
        INSERT INTO public.users (id, uid, name, email, role)
        VALUES ('seed-malak-admin', 'seed-malak-admin', 'Malak Admin',
                'malak@example.com', 'admin');
    """,
}

# The throwaway server bundled by `pgserver` ships only plpgsql and vector, but
# 20261022174110 runs `CREATE EXTENSION IF NOT EXISTS pgcrypto;` and the
# idempotency-hash helper calls digest(bytea,text). PostgreSQL 11+ has a
# built-in sha256(bytea), so install a same-named stub extension over it. This
# only writes into the throwaway server's own extension directory and only
# provides digest(); nothing else uses pgcrypto.
PGCRYPTO_CONTROL = """# pgcrypto stub for offline migration replay.
# Provides digest() only, backed by the PostgreSQL built-in sha256().
comment = 'stub: sha256 only (offline migration replay)'
default_version = '1.3'
module_pathname = ''
relocatable = true
trusted = true
"""

PGCRYPTO_SQL = """\\echo Use "CREATE EXTENSION pgcrypto" to load this file. \\quit
CREATE FUNCTION digest(bytea, text) RETURNS bytea
LANGUAGE sql IMMUTABLE STRICT AS $fn$
  SELECT CASE WHEN lower($2) = 'sha256' THEN sha256($1) ELSE NULL END
$fn$;
"""


def install_pgcrypto_stub() -> str:
    """Make `CREATE EXTENSION IF NOT EXISTS pgcrypto;` succeed offline."""
    sharedir = Path(pgserver.__file__).resolve().parent / "pginstall" / "share" / "postgresql"
    extdir = sharedir / "extension"
    extdir.mkdir(parents=True, exist_ok=True)
    (extdir / "pgcrypto.control").write_text(PGCRYPTO_CONTROL)
    (extdir / "pgcrypto--1.3.sql").write_text(PGCRYPTO_SQL)
    return str(extdir)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dump-json",
        type=Path,
        metavar="PATH",
        help="on success, write the resulting schema inventory to PATH",
    )
    args = parser.parse_args()
    dump_path = args.dump_json

    files = sorted(
        (p for p in MIGRATIONS.glob("*.sql") if p.name.split("_", 1)[0].isdigit()),
        key=lambda p: p.name,
    )
    if not files:
        print(f"No migrations found in {MIGRATIONS}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="migration-replay-") as tmp:
        print(f"Starting disposable PostgreSQL in {tmp} ...")
        extdir = install_pgcrypto_stub()
        db = pgserver.get_server(Path(tmp) / "pgdata")
        uri = db.get_uri()

        conn = psycopg2.connect(uri)
        conn.autocommit = True
        cur = conn.cursor()

        cur.execute("SELECT version();")
        print(f"  {cur.fetchone()[0]}")
        print(f"  pgcrypto stub installed at {extdir}\n")

        cur.execute(SHIM.read_text())
        print("Applied Supabase shim (auth/storage/roles/realtime).\n")

        results: list[tuple[str, bool, str]] = []
        for path in files:
            version = path.name.split("_", 1)[0]
            seed = SEED_BEFORE.get(version)
            if seed:
                cur.execute(seed)
            sql = path.read_text()
            try:
                cur.execute("BEGIN;")
                cur.execute(sql)
                cur.execute("COMMIT;")
                results.append((path.name, True, ""))
            except Exception as exc:  # noqa: BLE001 - report and continue
                try:
                    cur.execute("ROLLBACK;")
                except Exception:  # noqa: BLE001
                    conn.rollback()
                detail = str(exc).strip().splitlines()
                msg = detail[0] if detail else exc.__class__.__name__
                results.append((path.name, False, msg))

        passed = sum(1 for _, ok, _ in results if ok)
        print(f"{'RESULT':<10} {'MIGRATION':<56} DETAIL")
        print("-" * 100)
        for name, ok, msg in results:
            print(f"{'ok':<10} {name:<56}" if ok else f"{'FAILED':<10} {name:<56} {msg[:60]}")

        print("-" * 100)
        print(f"{passed}/{len(results)} migrations applied")

        if passed == len(results):
            cur.execute("""
                SELECT (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname IN ('public','private')),
                       (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal),
                       (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                         WHERE n.nspname='public' AND c.relkind='r'),
                       (SELECT count(*) FROM pg_policy)
            """)
            procs, trigs, tables, policies = cur.fetchone()
            print(f"post-replay object counts: functions={procs} triggers={trigs} "
                  f"public_tables={tables} policies={policies}")

        if passed == len(results) and dump_path is not None:
            from schema_inventory import collect

            dump_path.write_text(json.dumps(collect(cur), indent=2))
            print(f"\nwrote schema inventory to {dump_path}")

        cur.close()
        conn.close()
        return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
