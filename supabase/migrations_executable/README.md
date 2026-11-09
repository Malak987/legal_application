# Executable migration set

This directory holds **executable** copies of all 38 migrations. Point
`supabase db push` / `supabase db reset` here when you need to apply them to a
database.

```bash
supabase db reset --db-url "$DISPOSABLE_DB_URL"   # with migrations dir remapped
# or
psql "$DISPOSABLE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations_executable/<file>.sql
```

## Relationship to `supabase/migrations/`

`supabase/migrations/` is the **archive**: 38 files recovered byte-for-byte from
production, each verified against the fidelity oracle

```sql
array_to_string(statements, E'\n')   -- over supabase_migrations.schema_migrations
```

Run `python3 tools/migration_recovery/verify_migrations.py` to re-check it; it
exits 0 only at
`EXPECTED 38  OK 38  MISMATCH 0  MISSING 0  EXTRA 0  DUPLICATE 0`. `MISMATCH`,
`MISSING`, `EXTRA` and `DUPLICATE` are all fatal: the Supabase CLI refuses to
push a set containing duplicate versions, and an extra version would let a
freshly built database diverge from production.

**The archive is authoritative for provenance, but five of its files are not
runnable SQL.** This directory exists to fix exactly that, and nothing else.

## Why five files need terminators

Supabase stores an applied migration in one of two shapes:

| shape | meaning | terminators |
| --- | --- | --- |
| `cardinality(statements) = 1` | whole file executed as one query string | preserved |
| `cardinality(statements) > 1` | file pre-split into statements | **consumed by the splitter** |

33 migrations are the first shape and pass through here unchanged. Five were
pre-split, so the `;` that separated their top-level statements is gone and
`array_to_string(statements, E'\n')` runs the statements into one another:

| version | name | statements | archive bytes | executable bytes |
| --- | --- | ---: | ---: | ---: |
| `20261025140000` | `supabase_security_storage` | 162 | 29,391 | 29,553 |
| `20261025141000` | `identity_owner_lawyer_access` | 50 | 15,403 | 15,453 |
| `20261025142000` | `authenticated_transactional_rpcs` | 99 | 67,082 | 67,181 |
| `20261025143000` | `supabase_native_workflows` | 31 | 11,711 | 11,742 |
| `20261025144000` | `admin_native_workflows` | 21 | 11,866 | 11,887 |

`tools/migration_recovery/make_executable.py` regenerates them. It does **not**
guess where the terminators go: `tools/migration_recovery/statement_lengths.json`
records the stored byte length of every statement, and since the archive text is
exactly those statements joined by one `\n`, statement *i* ends at
`sum(len[0..i]) + i`. The script asserts that tiling invariant before writing.

## Verification

Each restored file is byte-identical to production's own re-terminated form:

```sql
SELECT md5(array_to_string(statements, E';\n') || ';') ...
```

| version | executable md5 |
| --- | --- |
| `20261025140000` | `ff04b0b7ef5f06fd6b2eb1ef9a877e85` |
| `20261025141000` | `b6543f997f3a95cc2964c68a81535019` |
| `20261025142000` | `61e6d83639251ebf615f85de0f42c81a` |
| `20261025143000` | `3b097311877546b71d025f8ac9824445` |
| `20261025144000` | `fdc27dbe5b4569d268c094f7a2737535` |

So the statement sequence, statement text and terminator placement are exact —
they are the same bytes production would produce from its own `statements` array.

### Known, semantically inert limitation

The splitter stored the statements, not the whitespace between them. If the
original files had blank lines or standalone comment blocks *between* two
statements, those are not recoverable from `statements`; here the separator is a
single `\n`. Comments that sat inside or immediately ahead of a statement are
part of that statement and **are** preserved (see the header block on
`20261025142000`, which is statement 1).

This affects layout only. No statement is reordered, added, dropped or
rewritten, and it has no effect on the resulting schema, grants, policies,
triggers or functions.

### Regenerating and drift-checking

```bash
python3 tools/migration_recovery/make_executable.py          # rebuild
python3 tools/migration_recovery/make_executable.py --check  # fail on drift
```

Do not hand-edit files here. Change `supabase/migrations/` and regenerate.
