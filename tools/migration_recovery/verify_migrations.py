#!/usr/bin/env python3
"""Verify recovered migration files byte-for-byte against the production oracle.

The oracle is supabase_migrations.schema_migrations: for each version, the exact
byte string is array_to_string(statements, E'\\n'). expected_checksums.tsv holds
one row per production version:  version <tab> length <tab> md5.

Every problem class below is FATAL and yields a non-zero exit status, so CI can
never go green while any of them is present:

  * MISMATCH  - the version exists but its bytes do not match the oracle.
  * MISSING   - a version in the oracle has no file in the migrations directory.
  * EXTRA     - a local version that production has never applied.
  * DUPLICATE - two or more files claim the same version.

DUPLICATE and EXTRA are as fatal as MISMATCH and MISSING. The Supabase CLI
refuses to push a migration set that contains two files with the same version,
and an EXTRA version would make a freshly built database diverge from
production. Reporting either without failing would leave `supabase db push`
broken while CI looked green.

Duplicate detection groups *every* matching file into a list keyed by version
and sorts each group by file name. It therefore cannot be defeated by
dictionary overwrites (a second file with the same version appends, it does not
replace the first) or by filename ordering (the group is sorted, and the file
checksummed for a duplicated version is always the first one in sorted order).

Usage:  python3 tools/migration_recovery/verify_migrations.py
        python3 tools/migration_recovery/verify_migrations.py \
            --migrations-dir DIR --oracle FILE      # used by the test suite

Exit 0 only when every expected version is present exactly once and byte-exact,
and no unexpected or duplicated version exists.
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "supabase" / "migrations"
ORACLE = Path(__file__).resolve().parent / "expected_checksums.tsv"


def load_oracle(path: Path) -> list[tuple[str, int, str]]:
    rows: list[tuple[str, int, str]] = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("version\t"):
            continue
        version, length, md5 = line.split("\t")
        rows.append((version, int(length), md5))
    return rows


def group_by_version(migrations_dir: Path) -> dict[str, list[Path]]:
    """Map each numeric version prefix to ALL files claiming it, sorted by name.

    The value is always a list, never a single path: a second file carrying the
    same version appends to the list rather than overwriting the first, so a
    duplicate can never be silently swallowed. Sorting makes the reported names
    and the file chosen for checksumming independent of directory order.
    """
    grouped: dict[str, list[Path]] = {}
    for path in migrations_dir.glob("*.sql"):
        stem = path.name.split("_", 1)[0]
        if stem.isdigit():
            grouped.setdefault(stem, []).append(path)
    for paths in grouped.values():
        paths.sort(key=lambda p: p.name)
    return grouped


def verify(migrations_dir: Path, oracle_path: Path) -> tuple[bool, str]:
    """Return (ok, report). `ok` is True only when there is nothing to report."""
    expected = load_oracle(oracle_path)
    grouped = group_by_version(migrations_dir)

    ok = mismatch = missing = 0
    problems: list[str] = []

    duplicates = {v: p for v, p in grouped.items() if len(p) > 1}
    for version, paths in sorted(duplicates.items()):
        problems.append(
            f"DUPLICATE {version}: {len(paths)} files claim this version: "
            + ", ".join(p.name for p in paths)
        )
        digests = {p.name: hashlib.md5(p.read_bytes()).hexdigest() for p in paths}
        if len(set(digests.values())) > 1:
            problems.append(
                f"DUPLICATE {version}: the files differ, so which one is applied "
                f"would depend on file ordering: {digests}"
            )

    for version, exp_len, exp_md5 in expected:
        paths = grouped.get(version, [])
        if not paths:
            missing += 1
            problems.append(f"MISSING  {version}  (expected {exp_len} B, {exp_md5})")
            continue
        # For a duplicated version this is the first file in sorted order, so the
        # verdict never depends on the order the directory happened to yield.
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

    extra = sorted(set(grouped) - {v for v, _, _ in expected})
    for version in extra:
        problems.append(
            "EXTRA    "
            + version
            + ": "
            + ", ".join(p.name for p in grouped[version])
            + "  (no matching production version)"
        )

    summary = (
        f"EXPECTED {len(expected)}  OK {ok}  MISMATCH {mismatch}  MISSING {missing}  "
        f"EXTRA {len(extra)}  DUPLICATE {len(duplicates)}"
    )
    report = summary
    if problems:
        report += "\n\n" + "\n".join(problems)

    fatal = bool(mismatch or missing or extra or duplicates)
    return (not fatal), report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify recovered migrations against the production checksum oracle."
    )
    parser.add_argument(
        "--migrations-dir",
        type=Path,
        default=MIGRATIONS,
        help="directory holding <version>_<name>.sql files (default: %(default)s)",
    )
    parser.add_argument(
        "--oracle",
        type=Path,
        default=ORACLE,
        help="expected_checksums.tsv fidelity oracle (default: %(default)s)",
    )
    args = parser.parse_args(argv)

    ok, report = verify(args.migrations_dir, args.oracle)
    print(report)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
