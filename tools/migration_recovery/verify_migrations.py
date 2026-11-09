#!/usr/bin/env python3
"""Verify recovered migration files byte-for-byte against the production oracle.

The oracle is supabase_migrations.schema_migrations: for each version, the exact
byte string is array_to_string(statements, E'\\n'). expected_checksums.tsv holds
one row per production version:  version <tab> length <tab> md5.

Usage:  python3 tools/migration_recovery/verify_migrations.py
Exit 0 when every expected file is present and byte-exact.
"""
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "supabase" / "migrations"
ORACLE = Path(__file__).resolve().parent / "expected_checksums.tsv"


def load_oracle() -> list[tuple[str, int, str]]:
    rows: list[tuple[str, int, str]] = []
    for line in ORACLE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("version\t"):
            continue
        version, length, md5 = line.split("\t")
        rows.append((version, int(length), md5))
    return rows


def main() -> int:
    expected = load_oracle()
    index: dict[str, list[Path]] = {}
    for path in sorted(MIGRATIONS.glob("*.sql")):
        stem = path.name.split("_", 1)[0]
        if stem.isdigit():
            index.setdefault(stem, []).append(path)

    ok = mismatch = missing = 0
    problems: list[str] = []
    for version, exp_len, exp_md5 in expected:
        paths = index.get(version, ())
        if not paths:
            missing += 1
            problems.append(f"MISSING  {version}  (expected {exp_len} B, {exp_md5})")
            continue
        if len(paths) > 1:
            problems.append(
                f"DUPLICATE {version}: " + ", ".join(p.name for p in paths)
            )
        path = paths[0]
        data = path.read_bytes()
        got_md5 = hashlib.md5(data).hexdigest()
        got_len = len(data)
        if got_md5 == exp_md5 and got_len == exp_len:
            ok += 1
        else:
            mismatch += 1
            problems.append(
                f"MISMATCH {version}  {path.name}\n"
                f"          len {got_len} vs {exp_len} (delta {got_len - exp_len:+d})\n"
                f"          md5 {got_md5} vs {exp_md5}"
            )

    extra = sorted(set(index) - {v for v, _, _ in expected})
    for version in extra:
        problems.append(
            "EXTRA    "
            + version
            + ": "
            + ", ".join(p.name for p in index[version])
            + "  (no matching production version)"
        )

    print(f"EXPECTED {len(expected)}  OK {ok}  MISMATCH {mismatch}  MISSING {missing}  EXTRA {len(extra)}")
    if problems:
        print()
        for problem in problems:
            print(problem)
    return 0 if (mismatch == 0 and missing == 0) else 1


if __name__ == "__main__":
    sys.exit(main())
