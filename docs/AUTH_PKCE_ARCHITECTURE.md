# PKCE verifier architecture

How the app stores `code_verifier` values between an authorization request and its
callback, why it is shaped this way, and what it deliberately does not solve.

Code: `lib/services/auth_service.dart` (`PkceKeystore`, `PkceVerifierStore`,
`PendingPkceFlow`, `SecurePkceVerifierStore`, `SupabaseAuthGateway`).

## The problem

A PKCE `code_verifier` is bearer-equivalent while its authorization code is alive:
whoever holds both can exchange them for that user's session. It must therefore be
persisted (the callback usually arrives in a *new process*) and must survive until
the exchange succeeds.

The previous implementation kept **one** slot:

```
legal_supabase_pkce_verifier_v1 -> <verifier>
```

That single slot had three defects:

1. **Signup and password recovery shared it.** Requesting a reset destroyed a pending
   confirmation's verifier, permanently stranding that email.
2. **Rollback was not ownership-conditional.** On a rejected signup the code wrote a
   remembered "previous" value back, which could overwrite a newer flow created by
   another operation while the request was in flight.
3. **"Superseded" was treated like "server rejected"**, so an operation that never
   started a flow could still destroy state.

## The design

### One row per flow

Every authorization request persists its own entry, keyed by purpose **and** a unique id:

```
legal_supabase_pkce_v2:signup:<id>    -> {"verifier": "...", "created_at": 1762...}
legal_supabase_pkce_v2:recovery:<id>  -> {"verifier": "...", "created_at": 1762...}
```

* `PkceFlowPurpose { signup, recovery }` — the two flows can never collide, because
  they never share a key.
* `<id>` is 9 CSPRNG bytes, base64url-unpadded, generated per `save()`.
* `created_at` orders flows so an unlabelled callback can pick the newest.

### Contract

```dart
abstract interface class PkceVerifierStore {
  Future<List<PendingPkceFlow>> readAll();      // may throw → caller fails closed
  Future<PendingPkceFlow> save(PkceFlowPurpose, String verifier);
  Future<void> remove(String id);               // idempotent
}
```

Deliberately **there is no `clear()`**. No code path can mass-delete another flow's
verifier. `remove(id)` takes the id returned by `save()`, so it can only ever delete
the row the caller created.

### Ownership-conditional rollback

This is the core safety property, and it is structural rather than procedural:

```dart
final flow = await _pkceStore.save(PkceFlowPurpose.signup, verifier);  // owns flow.id
...
if (response.statusCode >= 300) {
  await _discardFlow(flow);   // removes flow.id only
}
```

There is **no read-compare-write window** and **no remembered value written back**.
A rollback can only delete its own row, so it is impossible for it to overwrite a
newer flow — including one created by another process, because the keys differ.

Note what the rollback does *not* do: it does not restore anything. A rejected signup
simply removes the flow it created; any earlier pending flow was never touched, so it
is still there.

### Callback resolution

```
readAll() ──> usable flows only (non-empty verifier)
          ──> prefer the purpose implied by the callback's `type`
          ──> else newest first
          ──> none usable ⇒ invalid-pkce-link, and NO network request
```

Fails closed: an unreadable store, or no usable flow, never triggers a guessed
exchange. A failed exchange **keeps** the verifier (a transient 5xx must not consume
a flow the user can still complete). On success the session is installed *first*, and
only then is that one row removed — so a failed session install leaves the verifier
intact for a retry.

### Duplicate and stale callbacks

| Case | Behaviour |
|---|---|
| Same code delivered twice (cold start + stream, or double tap) | A bounded set of consumed codes returns the already-installed session; no second exchange, no second removal |
| Duplicate while already signed in | Returns the existing session; the controller no longer re-walks the profile load (previously it could stay stuck in `resolving`) |
| Callback with no pending flow | `invalid-pkce-link`, no request |
| Callback for an older flow after a newer one started | Both rows exist; the exchange uses the newest matching purpose. If the older code is still valid on the server the wrong verifier is offered, the server rejects it, and the flow fails **safely** — the newer flow is untouched (see limitation 1) |
| Callback on a non-configured origin / `type=invite` | Ignored before any request |

## Concurrency

There is **no mutex**, and one would not help: a real device can have two processes
(the OS may spawn the activity in a second process) and an in-process mutex would not
protect the persisted state anyway.

Correctness comes from the data model instead:

* Distinct keys per flow ⇒ concurrent writers cannot clobber each other.
* Id-scoped removal ⇒ a late operation cannot delete a newer one's row.
* No cross-key invariants ⇒ no ordering requirement between writers.

Verified by the test *"cross-process safety: a stale writer cannot delete a newer
flow"*, which drives two independent stores over one keystore.

## Failure handling

| Failure | Result |
|---|---|
| `save()` throws (keystore unavailable) | Signup/recovery is **not** sent. No account is created that could never be confirmed. Error `pkce-storage-failed`. |
| Save succeeds but read-back does not match | Row discarded, `pkce-storage-failed` |
| `readAll()` throws during a callback | `invalid-pkce-link`, no exchange |
| `remove()` throws after a successful session install | Session stays installed; the stale row is bounded by eviction |
| Session install throws | Verifier kept, `session-storage-failed` |
| Corrupt/empty row | Skipped, never used as a verifier |

## Limitations (deliberate, not oversights)

1. **Matching a callback to the right verifier is best-effort.** Supabase does not
   reliably tell the client which authorization request a `code` belongs to. With
   several same-purpose flows outstanding, the app offers the newest and the server
   rejects a mismatch. This fails safely but is not a cryptographic match; a
   flow-id in the redirect would be needed to make it exact, which requires an
   allow-listed redirect per flow and is out of scope here.
2. **Eviction bound:** at most `maxFlowsPerPurpose` (5) rows per purpose; the oldest is
   dropped. A user with six outstanding confirmations could lose the sixth-oldest
   verifier. This bounds stored secrets on disk.
3. **No TTL.** Confirmation emails may legitimately be opened days later, so expiry is
   the server's job (Supabase authorization codes expire in ~5 minutes).
4. **Upgrade path:** a single slot from the previous version
   (`legal_supabase_pkce_verifier_v1`) is still read as a legacy signup flow so a
   device mid-flight during the upgrade can finish, and it is deleted when consumed.

## Test coverage

`test/pkce_email_confirmation_test.dart` (44 tests):
RFC 7636 vectors, challenge derivation, persistence-before-request (sampled *inside*
the HTTP handler), the GoTrue exchange contract, per-flow isolation in both
directions, two-signups/two-recoveries, rejected-signup scoping, ownership rollback,
supersession, storage write/read/delete failures, failed session install, app restart
with pending flows, duplicate callbacks, and 9 tests against the real
`SecurePkceVerifierStore` over an in-memory keystore including cross-process safety.

`test/auth_deep_link_delivery_test.dart` (6 tests): cold start through
`bootstrapApp(initialCallbackUri:)`, warm start through `uriLinkStream`, duplicate
delivery, orphan callback, and the invalid-config gate.
