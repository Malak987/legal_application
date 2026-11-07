# Production repair — booking/availability and chat authentication

Date: 2026-11-07. Project: `qqfzbecwhewswkyxgebu` (Supabase, `eu-west-1`).
Status: **implemented locally, not committed, not deployed**. No production
write was performed during the investigation; every live check ran inside a
transaction that was rolled back.

---

## 1. Exact root cause of the booking authentication error

`Could not load availability / AUTHENTICATION REQUIRED / Try again` came from
`POST /rest/v1/rpc/rpc_refresh_lawyer_availability` and was reproduced verbatim
against the live database.

`public.rpc_refresh_lawyer_availability` starts with

```sql
IF auth.uid() IS NULL OR v_actor IS NULL THEN
  RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATION_REQUIRED';
END IF;
```

where `v_actor := private.current_app_user_id()`. That resolver matched the
caller's `public.users` row but only kept roles `client | lawyer | admin |
owner`. Ordinary client accounts are provisioned with `role = 'user'` by the
Auth trigger `public.link_migrated_auth_user()` (`v_signup_role := … ELSE
'user'`). For such an account:

| Signal | Value |
|---|---|
| `auth.uid()` | present (valid JWT) |
| `Authorization: Bearer <token>` | present |
| `apikey` | correct public publishable key |
| token expired / stale | no |
| `private.current_app_user_role()` | `user` |
| `private.current_app_user_id()` | **NULL** |

So the request was authenticated, the JWT was valid, and the database still
answered `42501 AUTHENTICATION_REQUIRED` — because the *actor resolver*, not the
token, disagreed with the role model used everywhere else:

* `AppProfile.isClient` accepts `client` **and** `user`;
* `private.current_app_user_role()` accepts `user`;
* the RLS policies on `bookings`, `booking_slots`, `chats`, `chat_messages`,
  `cases` already spell out `'client'` **and** `'user'`.

The same NULL actor is why chat failed for clients
(`rpc_chat_list`, `rpc_chat_messages_page`, `rpc_chat_send_message`,
`rpc_chat_start_with_lawyer`, `rpc_chat_create` all start with the same guard)
and why `GET /rest/v1/chats` and `GET /rest/v1/bookings` came back **empty**
instead of erroring — the client-role predicates evaluated to NULL.

It also explains why these accounts could still sign in and reach the screen at
all: `users_select_self_or_admin` has a second branch,
`auth_user_id = auth.uid()`, so the profile read succeeded while every
actor-dependent path failed. The failure was therefore not “the user is signed
out” — the session was healthy and the database disagreed with itself.

### Live evidence (disposable simulation, rolled back)

Simulating a real authenticated session for an existing `role='user'` profile
(`set local role authenticated` + `request.jwt.claims`, no data written):

```
rpc_refresh_lawyer_availability   -> 42501 | AUTHENTICATION_REQUIRED
rpc_create_booking                -> 42501 | AUTHENTICATION_REQUIRED
rpc_chat_list                     -> 42501 | AUTHENTICATION_REQUIRED
rpc_chat_messages_page            -> 42501 | AUTHENTICATION_REQUIRED
rpc_chat_send_message             -> 42501 | AUTHENTICATION_REQUIRED
visible chats / messages / bookings / booking_slots -> 0 / 0 / 0 / 0
```

After applying the new `private.current_app_user_id()` definition **inside the
same rolled-back transaction**, the same session produced:

```
actor_resolved                                    -> <profile id>
rpc_refresh_lawyer_availability(nonexistent)      -> 22023 | LAWYER_NOT_FOUND      (guard passed)
rpc_create_booking(hours = 0)                     -> 22023 | INVALID_BOOKING_DURATION (guard passed)
rpc_chat_list                                     -> ok
rpc_chat_messages_page(foreign chat)              -> 42501 | CHAT_NOT_FOUND_OR_FORBIDDEN
```

The guard passes and authorisation is unchanged: the role=`user` caller still
cannot read a conversation they do not participate in.

## 2. Where the fault was

| Layer | Verdict |
|---|---|
| Flutter access-token retrieval / headers | **correct** — `apikey` + `Authorization: Bearer <user token>`, never the publishable key as a bearer, never `anon` for these calls |
| Token refresh | correct in the happy path; hardened (see §4) for concurrent 401s, which is a latent session-loss bug |
| Supabase Auth | correct (JWT 1 h, rotation on, `email` provider only) |
| Edge Functions | not involved in this flow |
| **RLS / RPC / SQL actor resolution** | **root cause** — `private.current_app_user_id()` omitted the client signup role |
| Realtime | authorisation correct (`chats`, `chat_messages` in `supabase_realtime` publication, `can_read_chat` policy); clients got no rows only because the actor was NULL |

## 3. Files modified

| File | Change |
|---|---|
| `supabase/migrations/20261107093000_resolve_user_role_actor.sql` | **new** — redefines `private.current_app_user_id()` to accept the non-elevated signup role `user`, matching `current_app_user_role()`, the RLS policies and the client. RLS, grants, policies, Realtime and Edge Function JWT settings untouched. |
| `supabase/tests/actor_role_resolution_test.sql` | **new** — read-only regression guard: both resolvers must agree, a live `role=user` session must resolve, booking/availability RPCs must get past the guard, and a client still cannot read a foreign chat. |
| `lib/services/api_client.dart` | one retry only, with the rejected token passed to the refresh provider; a refresh that cannot produce a new token now raises an explicit session-expired error instead of replaying the stale token; `42501 AUTHENTICATION_REQUIRED` is translated into an actionable message (status and code preserved). |
| `lib/services/auth_service.dart` | `getAccessToken({forceRefresh, staleToken})` — reuses an already-refreshed session instead of rotating the refresh token a second time. |
| `lib/app_bootstrap.dart` | wires the rejected token into the force-refresh provider. |
| `lib/main.dart` | registers exactly one session listener and one `authSessionChanges` subscription (previously `didChangeDependencies` re-registered both, leaking a listener and asking Realtime for an extra token on every rebuild). |
| `test/booking_chat_auth_regression_test.dart` | **new** — see §6. |

No UI redesign, no unrelated feature touched, no policy weakened, **no
client-side `service_role`/secret key**, **no RLS disabled**, **no JWT
verification disabled**.

## 4. Security implications

* **Actor resolver (`'user'` added).** `user` is the default, non-elevated
  provisioning role. It confers the same row scope a `client` has today and
  nothing more: `private.is_admin()` still requires `admin|owner`,
  `private.is_current_user_lawyer_for()` still requires `role='lawyer'` plus a
  matching `lawyers.user_id`, and `private.chat_participant_can_read()` still
  requires a two-participant chat containing the caller and a lawyer/client
  pair. Row access remains `user_id = current_app_user_id()` /
  `participant = current_app_user_id()`. Verified by simulation that a client
  role user cannot read a foreign chat or another client's bookings.
* **Retry hardening.** No request is ever downgraded to `anon`; the client
  sends the public key only in `apikey`. A second consecutive 401 now fails as
  “session expired” rather than replaying a rejected token.
* **Fewer refresh rotations.** Supabase rotates refresh tokens (reuse window
  10 s). Reusing the token another request already installed removes the
  realistic path where a duplicate refresh invalidates a healthy session and
  signs the user out mid-booking/mid-chat.
* **Message sender identity** is still derived server-side from the JWT; the
  client sends only `p_chat_id`, `p_text`, `p_client_message_id` (asserted by a
  new test).
* **Error text.** The raw uppercase machine code is no longer shown to users;
  the HTTP status and `code` are unchanged for callers that branch on them.

## 5. Database changes

One migration, one function replacement (`CREATE OR REPLACE`, `STABLE`,
`SECURITY DEFINER`, explicit `search_path`). No table, column, index,
constraint, policy, grant or publication change. No row was inserted, updated or
deleted. Rollback = restore the previous definition without `'user'`.

## 6. Tests added / executed

Added `test/booking_chat_auth_regression_test.dart`:

* valid access token → sent as `Authorization: Bearer <token>` with the public
  `apikey`; never anonymous;
* expired token → one retry with the refreshed token, exactly two requests;
* refresh that returns the rejected token → **no replay**, explicit
  “session has expired” (`401`, `ApiErrorKind.unauthorized`);
* missing token → **zero** HTTP requests;
* concurrent 401s → **one** refresh-token rotation, both callers get the new
  token; a late 401 carrying the pre-refresh token reuses the session rather
  than rotating again;
* failed refresh → session cleared (`currentUser == null`, stored refresh token
  deleted), not silently anonymous;
* role contract: `role='user'` is a client profile and not a lawyer/admin;
* availability failure surfaces an explained message, not
  `AUTHENTICATION_REQUIRED`;
* availability + booking requests carry the session token and public key, and
  `p_user_id` stays `null` (the owner comes from the JWT);
* chat load + send carry the session token, and the send body contains no
  sender identity.

Added `supabase/tests/actor_role_resolution_test.sql` (read-only) and the
migration. Booking-cycle, duplicate-slot, cross-user access and
reconnect/token-refresh paths remain covered by the existing
`availability_booking_test.dart`, `chat_repository_test.dart`,
`chat_services_test.dart` and `auth_lifecycle_test.dart`.

**Not executed in this environment:** `flutter analyze`, `flutter test` and
`deno test` cannot run here — the sandbox has no Flutter/Dart/Deno SDK and its
network allow-list does not include the SDK download hosts. Every Dart change
was hand-checked (balanced syntax, no changed signatures outside the two
call sites) and the new tests are written against the existing `MockClient`
harness, but they must be run before deployment:

```bash
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/tests/actor_role_resolution_test.sql
```

## 7. Live Supabase verification (performed)

* Schema/functions/policies/grants/publication read from the live project.
* Confirmed `role='user'` profiles exist and are Auth-linked; confirmed
  `current_app_user_id()` returns NULL for them.
* Reproduced all five `AUTHENTICATION_REQUIRED` failures.
* Confirmed the replacement definition resolves the actor and lets every RPC
  reach its business validation, inside a rolled-back transaction.
* Confirmed chat authorisation for a real lawyer: own chat visible (1), other
  chat invisible (0), own messages 3, foreign messages 0, cross-chat page →
  `CHAT_NOT_FOUND_OR_FORBIDDEN`, send to a foreign chat →
  `NOT_CHAT_PARTICIPANT`, own bookings 2.
* `bookings` / `lawyers` are exposed to PostgREST through **column-level**
  grants that cover exactly the columns the app selects — the catalogue and
  booking-history reads are not blocked by a missing table grant.

Not performed: creating disposable test accounts (the sandbox has no HTTP
access to `*.supabase.co`, and no Auth admin user was created), end-to-end
device runs, and any production migration.

## 8. Remaining issues / blockers

1. **Deployment is required for the fix to take effect.** The migration is not
   applied to production, so affected accounts still receive
   `AUTHENTICATION_REQUIRED` until it is.
2. **Three orphaned `client` profiles** in `public.users` have
   `auth_user_id IS NULL` and no matching `auth.users` row; nobody can sign in
   as them and they own one existing chat and several bookings. They need a
   deliberate identity-link decision (do not delete). Not touched here.
3. **`role='client'` vs `role='user'`.** Two client roles now both work. A
   future cleanup could normalise `client → user` (or vice-versa), but that is
   a data migration over real accounts and is out of scope.
4. **Admin chat access:** `private.can_read_chat` grants a bypass only to
   `owner`; an `admin` who is a participant of a conversation (one live chat)
   cannot read it. Changing that is an authorisation change, so it was left
   alone and is reported, not fixed.
5. **Environment limits:** no Flutter/Dart/Deno toolchain here, so the test
   commands above must be run on a machine with the SDK before deployment.
