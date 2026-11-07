#!/usr/bin/env python3
"""Builds the single-file Edge Function bundle that is deployed to Supabase.

The Management API (and the dashboard editor) upload one file per function, so
`account_deletion.ts` is inlined ahead of `index.ts` without its relative
import. Nothing else is modified: the deployed code is byte-for-byte the repo
source, joined.

Usage:  python3 supabase/functions/delete-my-account/bundle.py
Output: supabase/functions/delete-my-account/dist/index.ts
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "dist" / "index.ts"

HEADER = """// GENERATED FILE — do not edit.
// Produced by supabase/functions/delete-my-account/bundle.py from
//   account_deletion.ts + index.ts
// Deploy this file as the `delete-my-account` Edge Function.

"""


def strip_nocheck(text: str) -> str:
    lines = text.splitlines(keepends=True)
    if lines and lines[0].startswith("// @ts-nocheck"):
        lines = lines[1:]
    return "".join(lines)


def main() -> None:
    handler = strip_nocheck((HERE / "account_deletion.ts").read_text())
    entry = strip_nocheck((HERE / "index.ts").read_text())

    import_line = "import { createSelfDeleteAccountHandler } from './account_deletion.ts';\n"
    if import_line not in entry:
        raise SystemExit("entry file no longer imports the handler module")
    entry = entry.replace(import_line, "")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(HEADER + handler.rstrip() + "\n\n" + entry.lstrip())
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
