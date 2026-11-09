#!/usr/bin/env python3
"""Tests for the migration integrity checks.

The five cases below are the ones that decide whether `supabase db push` can
run at all, so each invalid case MUST exit non-zero:

  1. a valid migration set                    -> exit 0
  2. a duplicate version, different filename  -> exit non-zero
  3. a missing version                        -> exit non-zero
  4. an unexpected extra version              -> exit non-zero
  5. a modified migration checksum            -> exit non-zero

Plus the hardening that makes case 2 reliable: duplicate detection must survive
filename ordering (a duplicate that sorts *before* the original is still caught)
and must list every colliding file (so a dictionary overwrite cannot hide it),
and `make_executable.py` must reject duplicates too.

Pure stdlib Python. No database, no Supabase CLI, no production access.

    python3 tools/migration_recovery/test_migration_checks.py
    python3 -m unittest discover -s tools/migration_recovery -p 'test_*.py'
"""
from __future__ import annotations

import hashlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
VERIFY = HERE / "verify_migrations.py"
MAKE = HERE / "make_executable.py"
REAL_ORACLE = HERE / "expected_checksums.tsv"

FIRST = "20260101000000"
SECOND = "20260102000000"


def md5(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def write_oracle(path: Path, migrations_dir: Path) -> None:
    """Write a fidelity oracle matching every file currently in migrations_dir."""
    lines = ["version\tlength\tmd5"]
    for p in sorted(migrations_dir.glob("*.sql")):
        data = p.read_bytes()
        lines.append(f"{p.name.split('_', 1)[0]}\t{len(data)}\t{md5(data)}")
    path.write_text("\n".join(lines) + "\n")


def run_verify(migrations_dir: Path, oracle: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            sys.executable,
            str(VERIFY),
            "--migrations-dir",
            str(migrations_dir),
            "--oracle",
            str(oracle),
        ],
        capture_output=True,
        text=True,
    )


def run_make(source: Path, output: Path, lengths: Path, oracle: Path,
             check: bool = True) -> subprocess.CompletedProcess:
    cmd = [
        sys.executable, str(MAKE),
        "--source-dir", str(source),
        "--output-dir", str(output),
        "--lengths", str(lengths),
        "--oracle", str(oracle),
    ]
    if check:
        cmd.append("--check")
    return subprocess.run(cmd, capture_output=True, text=True)


class MigrationFixtureTestCase(unittest.TestCase):
    """Builds a throwaway two-migration set and mutates it per test."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="migration-checks-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.migrations = self.tmp / "migrations"
        self.migrations.mkdir()
        self.oracle = self.tmp / "oracle.tsv"
        self.first = self.migrations / f"{FIRST}_first.sql"
        self.second = self.migrations / f"{SECOND}_second.sql"
        self.first.write_bytes(b"SELECT 1;\n")
        self.second.write_bytes(b"SELECT 2;\n")
        write_oracle(self.oracle, self.migrations)

    # 1 ------------------------------------------------------------------
    def test_valid_migration_set_exits_zero(self) -> None:
        result = run_verify(self.migrations, self.oracle)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("OK 2", result.stdout)
        self.assertIn("DUPLICATE 0", result.stdout)
        self.assertIn("EXTRA 0", result.stdout)

    # 2 ------------------------------------------------------------------
    def test_duplicate_version_different_filename_exits_non_zero(self) -> None:
        # Byte-identical copy under a second name. This is the exact case that
        # used to be reported but still exit 0.
        duplicate = self.migrations / f"{FIRST}_copy.sql"
        shutil.copyfile(self.first, duplicate)
        result = run_verify(self.migrations, self.oracle)
        self.assertNotEqual(result.returncode, 0, "duplicate must fail the check")
        self.assertIn("DUPLICATE", result.stdout)
        self.assertIn("DUPLICATE 1", result.stdout)

    def test_duplicate_with_differing_content_is_reported(self) -> None:
        duplicate = self.migrations / f"{FIRST}_divergent.sql"
        duplicate.write_bytes(b"SELECT 999;\n")
        result = run_verify(self.migrations, self.oracle)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DUPLICATE", result.stdout)
        self.assertIn("the files differ", result.stdout)

    # Hardening for case 2 -------------------------------------------------
    def test_duplicate_survives_filename_ordering(self) -> None:
        # The duplicate sorts BEFORE the original, and the original is renamed so
        # it sorts last. Detection must not depend on which file comes first.
        self.first.rename(self.migrations / f"{FIRST}_zzz_original.sql")
        (self.migrations / f"{FIRST}_aaa_duplicate.sql").write_bytes(b"SELECT 1;\n")
        result = run_verify(self.migrations, self.oracle)
        self.assertNotEqual(result.returncode, 0, "duplicate must fail regardless of order")
        self.assertIn("DUPLICATE", result.stdout)
        # Both colliding files must be named, so a dict overwrite cannot hide one.
        self.assertIn(f"{FIRST}_aaa_duplicate.sql", result.stdout)
        self.assertIn(f"{FIRST}_zzz_original.sql", result.stdout)

    # 3 ------------------------------------------------------------------
    def test_missing_version_exits_non_zero(self) -> None:
        self.second.unlink()
        result = run_verify(self.migrations, self.oracle)
        self.assertNotEqual(result.returncode, 0, "missing version must fail")
        self.assertIn("MISSING", result.stdout)
        self.assertIn(SECOND, result.stdout)

    # 4 ------------------------------------------------------------------
    def test_unexpected_extra_version_exits_non_zero(self) -> None:
        (self.migrations / "20990101000000_bogus.sql").write_bytes(b"SELECT 3;\n")
        result = run_verify(self.migrations, self.oracle)
        self.assertNotEqual(result.returncode, 0, "extra version must fail")
        self.assertIn("EXTRA", result.stdout)
        self.assertIn("20990101000000", result.stdout)

    # 5 ------------------------------------------------------------------
    def test_modified_checksum_exits_non_zero(self) -> None:
        self.first.write_bytes(b"SELECT 1;\n-- tampered\n")
        result = run_verify(self.migrations, self.oracle)
        self.assertNotEqual(result.returncode, 0, "checksum mismatch must fail")
        self.assertIn("MISMATCH", result.stdout)
        self.assertIn(FIRST, result.stdout)

    def test_truncated_file_exits_non_zero(self) -> None:
        self.first.write_bytes(b"SELECT 1;")
        result = run_verify(self.migrations, self.oracle)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MISMATCH", result.stdout)

    # make_executable.py ---------------------------------------------------
    def test_make_executable_accepts_a_valid_set(self) -> None:
        lengths = self.tmp / "lengths.json"
        lengths.write_text("{}")
        output = self.tmp / "executable"
        result = run_make(self.migrations, output, lengths, self.oracle, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((output / f"{FIRST}_first.sql").exists())

    def test_make_executable_rejects_duplicate_version(self) -> None:
        lengths = self.tmp / "lengths.json"
        lengths.write_text("{}")
        output = self.tmp / "executable"
        self.assertEqual(
            run_make(self.migrations, output, lengths, self.oracle, check=False).returncode, 0
        )
        # Now add a second file claiming an existing version and re-check.
        shutil.copyfile(self.first, self.migrations / f"{FIRST}_copy.sql")
        result = run_make(self.migrations, output, lengths, self.oracle, check=True)
        self.assertNotEqual(result.returncode, 0, "make_executable must reject duplicates")
        self.assertIn("duplicate version", result.stdout)
        self.assertIn(FIRST, result.stdout)


class RealRepositoryTestCase(unittest.TestCase):
    """The fixtures above are synthetic - guard the tree we actually ship."""

    @unittest.skipUnless(REAL_ORACLE.exists(), "production oracle not present")
    def test_real_repository_passes(self) -> None:
        result = subprocess.run(
            [sys.executable, str(VERIFY)], cwd=str(ROOT), capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("OK 38", result.stdout)
        self.assertIn("DUPLICATE 0", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
