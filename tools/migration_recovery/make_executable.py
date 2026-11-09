#!/usr/bin/env python3
"""Produce executable migration files from the byte-exact recovered originals.

Why this exists
---------------
`supabase/migrations/*.sql` holds the 38 migrations recovered byte-exactly from
production: each file is verified, byte for byte, against the fidelity oracle

    array_to_string(statements, E'\\n')   over supabase_migrations.schema_migrations

That oracle is the right thing to archive, but for five migrations it is NOT
executable SQL. Those five were applied through a path that split the file into
individual statements, and the splitter consumed the top-level `;` terminators.
Joining the stored statements back together with '\\n' therefore yields statements
that run into one another - e.g.

    ALTER TABLE public.wallet_transactions
      DROP CONSTRAINT IF EXISTS wallet_transactions_amount_check
    ALTER TABLE public.wallet_transactions
      ADD CONSTRAINT wallet_transactions_amount_check ...

which no PostgreSQL client can parse. The remaining 33 migrations were stored as
a single array element (whole file, verbatim) and keep their terminators.

What this does
--------------
For each migration, emit `supabase/migrations_executable/<same file name>`:

  * the 33 single-statement migrations are copied through unchanged;
  * the five split migrations get a ';' inserted at the end of every statement.

The insertion offsets are not guessed. `statement_lengths.json` records the
stored byte length of every statement; because the joined text is exactly
statements joined by one '\\n', statement i ends at  sum(len[0..i]) + i.  This
script asserts that invariant before writing anything, and refuses to run if the
byte-exact source has drifted from the recorded lengths.

This is a terminator-only transformation. It does not reorder, add, drop, or
rewrite any statement, and it does not touch the byte-exact originals in
`supabase/migrations/`.

Usage
-----
    python3 tools/migration_recovery/make_executable.py            # build
    python3 tools/migration_recovery/make_executable.py --check    # drift check

Both modes exit non-zero on drift, including a duplicate migration version (two
files claiming the same version), which the Supabase CLI refuses to push.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = ROOT / "supabase" / "migrations"
OUTPUT = ROOT / "supabase" / "migrations_executable"
LENGTHS = HERE / "statement_lengths.json"
ORACLE = HERE / "expected_checksums.tsv"


def load_lengths(path: Path = LENGTHS) -> dict[str, list[int]]:
    raw = json.loads(path.read_text())
    return {k: v for k, v in raw.items() if not k.startswith("_")}


def load_oracle(path: Path = ORACLE) -> dict[str, str]:
    expected: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("version\t"):
            continue
        version, _length, md5 = line.split("\t")
        expected[version] = md5
    return expected


def executable_text(source: bytes, lengths: list[int] | None) -> bytes:
    """Re-terminate top-level statements. Returns the source unchanged if no split."""
    if lengths is None:
        return source

    # Invariant: the joined text is exactly the statements joined by a single '\n'.
    if sum(lengths) + (len(lengths) - 1) != len(source):
        raise AssertionError(
            "statement lengths do not tile the source: "
            f"sum(lengths)+{len(lengths) - 1}={sum(lengths) + len(lengths) - 1} "
            f"!= len(source)={len(source)}"
        )

    out = bytearray()
    pos = 0
    for i, length in enumerate(lengths):
        out += source[pos : pos + length]
        out += b";"
        pos += length
        if i < len(lengths) - 1:
            # Skip the single '\n' that joined this statement to the next.
            out += b"\n"
            pos += 1
    if pos != len(source):
        raise AssertionError("did not consume the whole source")
    return bytes(out)


def build(
    check: bool,
    source_dir: Path = SOURCE,
    output_dir: Path = OUTPUT,
    lengths_path: Path = LENGTHS,
    oracle_path: Path = ORACLE,
) -> int:
    lengths_by_version = load_lengths(lengths_path)
    expected = load_oracle(oracle_path)
    sources = sorted(source_dir.glob("*.sql"))

    # A dict of LISTS, never a dict of single paths: a second file claiming the
    # same version appends instead of overwriting the first, so a duplicate
    # version can never be swallowed by a dictionary assignment.
    seen: dict[str, list[Path]] = {}
    drift: list[str] = []
    restored: list[str] = []

    for path in sources:
        stem = path.name.split("_", 1)[0]
        if not stem.isdigit():
            continue
        seen.setdefault(stem, []).append(path)
        source = path.read_bytes()

        if stem not in expected:
            drift.append(f"{path.name}: version {stem} is not in the production oracle")
            continue

        lengths = lengths_by_version.get(stem)
        text = executable_text(source, lengths)
        target = output_dir / path.name

        if not check:
            output_dir.mkdir(parents=True, exist_ok=True)
            target.write_bytes(text)

        if target.exists() and target.read_bytes() != text:
            drift.append(f"{path.name}: generated output differs from what is committed")
        if lengths is not None:
            restored.append(f"{stem}  {len(lengths):3d} statements  "
                            f"{len(source)} -> {len(text)} bytes")

    # Duplicate versions are fatal for the same reason they are in
    # verify_migrations.py: the Supabase CLI refuses to push a set in which two
    # files claim the same version.
    for stem, paths in sorted(seen.items()):
        if len(paths) > 1:
            drift.append(
                f"duplicate version {stem}: "
                + ", ".join(sorted(p.name for p in paths))
                + "  (the Supabase CLI cannot push duplicate versions)"
            )

    missing = sorted(set(expected) - set(seen))
    for version in missing:
        drift.append(f"{version}: in the production oracle but absent from migrations/")

    print(
        f"source files      {sum(len(v) for v in seen.values())}"
        f"  ({len(seen)} unique version(s))"
    )
    print(f"oracle versions   {len(expected)}")
    print(f"terminators restored in {len(restored)} migration(s):")
    for line in restored:
        print(f"  {line}")
    if drift:
        print("\nDRIFT:")
        for line in drift:
            print(f"  {line}")
        return 1
    print("\nOK - executable output is consistent with the byte-exact originals.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the committed executable output rather than rewriting it",
    )
    parser.add_argument("--source-dir", type=Path, default=SOURCE,
                        help="byte-exact archive directory (default: %(default)s)")
    parser.add_argument("--output-dir", type=Path, default=OUTPUT,
                        help="executable output directory (default: %(default)s)")
    parser.add_argument("--lengths", type=Path, default=LENGTHS,
                        help="statement_lengths.json (default: %(default)s)")
    parser.add_argument("--oracle", type=Path, default=ORACLE,
                        help="expected_checksums.tsv (default: %(default)s)")
    args = parser.parse_args()
    return build(
        args.check,
        source_dir=args.source_dir,
        output_dir=args.output_dir,
        lengths_path=args.lengths,
        oracle_path=args.oracle,
    )


if __name__ == "__main__":
    sys.exit(main())
