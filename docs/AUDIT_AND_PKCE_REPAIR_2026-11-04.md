# Legal App — Repository Audit, Supabase Integration Review & PKCE Authentication Repair

**Repository:** `github.com/Malak987/legal_application`
**Branch:** `main` · **Base commit:** `5ccad7c` ("first commit") · **Working tree:** clean at audit start
**Audit date:** 2026-11-04
**Toolchain used:** Flutter 3.47.9 (stable) · Dart 3.13.7 · JDK 17.0.21 · Android SDK 36.0.0
**Live Supabase project:** never contacted. All requests in this work were mocked locally.

> Every claim below is separated into **Verified**, **Fixed**, **Tested**, **Not verified**, and
> **Requires external configuration**. Nothing here is asserted from the repository's own
> documentation — `README.md`, `IMPLEMENTATION_SUMMARY.md` and `docs/mobile_auth_recovery.md`
> were read and then checked against the code, and two of them are contradicted by it (see §2.6).

---

## 1. Repository structure and architecture

### 1.1 Shape

```
405 tracked files · 162 Dart files · 30,237 lines of Dart under lib/
android/ ios/ macos/ linux/ windows/ web/     (6 platforms)
lib/
  main.dart, app_bootstrap.dart               startup + DI composition root
  config/        supabase_config.dart, supabase_client_config.dart, ai_config.dart
  models/        app_profile, lawyer_availability, legal_category, paginated_result,
                 product_model, samaha_catalog
  services/      auth_service, api_client, app_repository, samaha_repository,
                 chat_realtime, chat_message_store, user_cache_service
  state/         session_controller, session_scope, start_route, samaha_controller
  views/         ~110 screens in 30 feature folders
  widgets/ commonwidgets/   shared UI
test/            28 files, ~10,000 lines
tool/            supabase_flutter.dart  (custom build helper)
docs/            mobile_auth_recovery.md, SAMAHA_*
```

### 1.2 Layers actually present

| Layer | Reality |
|---|---|
| **Presentation** | 110+ `StatefulWidget` screens. No cubit/bloc — the `pubspec` has no `flutter_bloc`. |
| **State** | `ChangeNotifier` (`SessionController`) exposed via `InheritedNotifier` (`SessionScope`), plus `provider` for `SamahaController`. |
| **Domain** | **Absent as a layer.** No use cases, no repository interfaces/contracts. Models are DTOs parsed from PostgREST rows. |
| **Data** | `ApiClient` (raw `http` against Supabase REST/RPC/Storage/Functions) → `AppRepository` → screens. |
| **DI** | Manual constructor injection assembled in `app_bootstrap.dart`. No service locator. |
| **Navigation** | Imperative `Navigator.push*` on a single `MaterialApp.home` (`SplashScreen`). **No named routes, no route table, and no router guards.** |

**Verdict:** this is a conventional single-module Flutter app with a data/presentation split and a
deliberately centralised auth/session spine. The session spine (`SessionController` +
`SessionScope` + `startScreenFor`) is genuinely well-designed and was preserved untouched in
behaviour. **I did not restructure anything.** No files were moved, no packages added, and no
abstractions were introduced for their own sake.

### 1.3 State management & guards (what actually protects screens)

There is no navigator guard. Protection is achieved by a **single decision point**: every screen
that needs a session reads `SessionScope`, and `startScreenFor(status)` sends anything other than
`SessionStatus.signedIn` to the unauthenticated flow. This is sound and I left it alone.

---

## 2. Actual technical problems discovered

### 2.1 P0 — The project did not resolve or compile at all

| # | Problem | Evidence |
|---|---|---|
| 1 | `crypto: ^3.6.0` does not exist. pub.dev's latest `crypto` is **3.0.8**; `pubspec.lock` pins 3.0.7. | `flutter pub get` → *"Because legalserviceapp depends on crypto ^3.6.0 which doesn't match any versions, version solving failed."* |
| 2 | `app_links: ^7.2.2` requires **Dart ^3.12.0**. | `flutter pub get` → *"Because app_links 7.2.2 requires SDK version ^3.12.0 … version solving failed."* |
| 3 | `import 'dart:crypto' show digest;` — there is no `dart:crypto` library. All PKCE hashing depended on it. | `flutter analyze` → `uri_does_not_exist` at `auth_service.dart:3:8` |
| 4 | `accessToken`/`refreshToken` read at `auth_service.dart:296` **before** their `final` declarations at 300–301. | 4 analyzer errors: `referenced_before_declaration`, `read_potentially_unassigned_final` |
| 5 | `_authUri('token', const {…'grant_type': 'pkce', 'code': code})` — a non-constant value inside a `const` map. | `non_constant_map_value` |
| 6 | `test/auth_lifecycle_test.dart:45` referenced an undefined `requests`. | `undefined_identifier` — the test file could not compile |

**Net effect: `flutter pub get`, `flutter analyze`, `flutter test` and `flutter build` all failed.**
The repository was in a non-buildable state on `main`.

### 2.2 P0 — PKCE was broken in five independent ways

Tracing the required chain
`code_verifier → SHA256 → code_challenge → signup → persisted verifier → callback → token exchange`:

| Link | State found | Consequence |
|---|---|---|
| verifier → challenge | Blocked by `dart:crypto`; the code compiled only against a non-existent library | PKCE hashing could never run |
| **verifier persisted** | `_sharedPrefs` is a nullable constructor parameter. `createSession()` in `app_bootstrap.dart` **never passed it**, so in production it was always `null` and the write was skipped entirely. | **The verifier was never stored. Every confirmation would fail.** |
| challenge sent | `code_challenge_method: 's256'` was sent (correct), but only reachable if #3 were fixed | — |
| callback exchange | Body was `{"code_verifier": …}` with the code in the **query string** (`?code=`). GoTrue requires `{"auth_code", "code_verifier"}` in the **body**. | Even with a verifier, the request did not match the endpoint contract |
| exchange → session | `_sharedPrefs.remove(...)` ran *before* `_installSession` | A storage failure after clearing would strand the user with no verifier and no session |

The Supabase Auth PKCE contract was confirmed against the GoTrue implementation
(`POST /auth/v1/token?grant_type=pkce` with `auth_code` + `code_verifier` in the body;
`auth_code` must be a UUID; verifier must hash to the stored `code_challenge`; code is
single-use and expires in ~5 minutes).

### 2.3 P0 — The Android callback URI could never reach the app

`android/app/src/main/AndroidManifest.xml` declares exactly one callback:

```xml
<intent-filter android:autoVerify="true">
  <data android:scheme="https"
        android:host="legal-dashboard-1.web.app"
        android:path="/auth/callback" />
</intent-filter>
```

with the values supplied by `android/gradle.properties`
(`authCallbackScheme=https`, `authCallbackHost=legal-dashboard-1.web.app`,
`authCallbackPath=/auth/callback`).

Because `autoVerify="true"`, Android will only deliver that link to the app if
`https://legal-dashboard-1.web.app/.well-known/assetlinks.json` is served with this app's
signing-certificate SHA-256. **Verified by fetching it:**

```
GET https://legal-dashboard-1.web.app/.well-known/assetlinks.json  → HTTP 200
Content-Type/body: <!DOCTYPE html> … Flutter web index.html …
```

The host serves the **Flutter SPA HTML for every path**, so there is no Digital Asset Links
document. The same is true of `apple-app-site-association` (iOS `Runner.entitlements` declares
`applinks:legal-dashboard-1.web.app`).

**Consequence:** on Android the confirmation link resolves to the browser (or a chooser), never to
the app. Combined with §2.2 this fully explains the reported symptom. `docs/mobile_auth_recovery.md`
even states this explicitly ("no association document is published") — while the manifest still
asks Android to verify one.

### 2.4 P1 — Wrong journey on callback failure

`SessionController._handleRecoveryLink`'s `catch` set `SessionStatus.recoveryLinkInvalid`
unconditionally. A failed **email confirmation** was therefore presented as a **password-reset**
screen (`MyApp._syncCallbackRoute` pushes `ResetPasswordScreen` for that status, and
`SplashScreen._navigateToDestination` does the same).

### 2.5 P1 — No duplicate-callback protection

`app_links` delivers the same URI on cold start *and* on the live stream, and a double tap delivers
it twice. PKCE authorization codes are single-use; a second exchange would fail and could tear down
a session that had already succeeded.

### 2.6 Documentation contradicted by the code

`docs/mobile_auth_recovery.md` and `IMPLEMENTATION_VERIFICATION.md` describe the auth flow as
working and describe `_handlePkceCode` as correct. Per the brief, **the repository was treated as
the source of truth**: the code did not compile, the verifier was never persisted, and the
redirection was never reachable on a device. Those documents were not used as evidence.

### 2.7 P4 — Cleanup-level findings (identifying, not fixed)

* `android/gradle.properties` sets `org.gradle.jvmargs=-Xmx8G` — fatal on a small machine (this
  sandbox OOM-killed the Gradle daemon until overridden; see §8).
* 27 `info`-level analyzer lints remain: `withOpacity` deprecation (3), `TextFormField.value`
  deprecation (~7), `Radio.groupValue`/`onChanged` deprecation (2), `use_build_context_synchronously`
  in `chat_screen.dart:293`, dangling library doc comments (4), `curly_braces_in_flow_control_structures` (2).
* Two near-duplicate screen folders exist by design of the original app (`wallet/wallet_screen.dart`
  vs `wallet/walletscreen.dart`, `cart/` vs `checkout/`).
* `firebase.json` references `lib/config/firebase_options.dart`, which does not exist; there is no
  `firebase_*` dependency anywhere in `pubspec.yaml`. `android/app/google-services.json` is a
  committed Firebase config for project `legal-102026` that nothing reads. Dead configuration.
* Unused dependencies: `pie_chart`, `flutter_charts`, `percent_indicator`, `flutter_vector_icons`,
  `animate_do`, `responsive_builder`, `flutter_markdown` are declared but not imported by `lib/`.

---

## 3. Root cause of each critical issue

| Symptom | Root cause |
|---|---|
| "Nothing builds" | Two impossible version constraints (`crypto ^3.6.0`, and `app_links 7.2.2` vs an older Dart SDK) plus a fabricated `dart:crypto` import |
| "Confirmation email link does nothing on Android" | The only declared intent filter is an **HTTPS App Link with `autoVerify`** whose `assetlinks.json` is not published — Android cannot associate the app with the link |
| "Even if the link opened the app, confirmation still failed" | The PKCE verifier was **never persisted in production** (`sharedPrefs` was never injected), and the exchange request used the wrong wire contract (`code` in query, no `auth_code` in body) |
| "Expired confirmation shows a password-reset form" | `_handleRecoveryLink` mapped every callback failure to `recoveryLinkInvalid` |
| "Tapping the link twice logs the user out / errors" | No de-duplication of authorization codes; the second exchange fails on a single-use code |

---

## 4. Exact files modified

| File | Change |
|---|---|
| `pubspec.yaml` | `crypto: ^3.6.0` → `^3.0.7` (resolvable, matches `pubspec.lock`) |
| `lib/services/auth_service.dart` | **Core P0 repair** — hashing, verifier persistence, exchange contract, duplicate protection, recovery PKCE |
| `lib/app_bootstrap.dart` | `createSupabaseSession` now accepts and forwards `pkceStore`; removed unused `dart:convert` import |
| `lib/state/session_controller.dart` | Added public `authUser` accessor; callback-failure routing fix |
| `lib/main.dart` | Use `session.authUser` instead of the `@visibleForTesting` member |
| `lib/services/user_cache_service.dart` | Removed unused import |
| `lib/views/home/homescreen.dart` | **Pre-existing bug** — `minCardWidth` 150 → 200 so the responsive grid matches its documented intent (1 column at 390 px) |
| `android/app/src/debug/AndroidManifest.xml` | Added debug-only `legalserviceapp://auth-callback` intent filter (inside `<application>`) |
| `supabase.local.example.json` | Documented the debug redirect + `ENABLE_CLIENT_SIGNUP` |
| `test/support/fakes.dart` | Added shared `MemoryPkceVerifierStore` |
| `test/auth_lifecycle_test.dart` | Removed the uncompilable orphaned assertion; inject `pkceStore`; recovery-body assertion now expects the PKCE challenge |
| `test/registration_safety_test.dart`, `test/startup_config_test.dart` | Inject `pkceStore` (no test may touch the platform keystore) |
| `test/pkce_email_confirmation_test.dart` | **New** — 21 PKCE/deep-link/session tests |
| `test/auth_deep_link_parsing_test.dart` | **New** — callback-shape tests |
| `docs/AUDIT_AND_PKCE_REPAIR_2026-11-04.md` | **New** — this report |

No file was deleted. No working feature was removed. No destructive git command was used.

---

## 5. Implemented fixes

### 5.1 Correct PKCE primitives

```dart
import 'package:crypto/crypto.dart' show sha256;   // was: dart:crypto (does not exist)

static const int _pkceVerifierBytes = 32;          // 43 chars after base64url-unpadded

static String _generatePkceVerifier() {            // math.Random.secure() = platform CSPRNG
  final bytes = List<int>.generate(_pkceVerifierBytes,
      (_) => math.Random.secure().nextInt(256));
  return _base64UrlNoPadding(bytes);               // 43 chars, RFC 7636 §4.1 window
}

static String _generatePkceChallenge(String verifier) =>
    _base64UrlNoPadding(sha256.convert(utf8.encode(verifier)).bytes);
```

Validated against the **RFC 7636 Appendix B** worked example:
`dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk` → `E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM`.

### 5.2 The verifier is now actually persisted — in the keystore

A new `PkceVerifierStore` abstraction with `SecurePkceVerifierStore`
(`flutter_secure_storage`, key `legal_supabase_pkce_verifier_v1`) replaces the never-injected
`SharedPreferences?`. The verifier is a bearer-equivalent secret for the life of the flow, so
`SharedPreferences` (world-readable on a rooted/unlocked device) was the wrong store.
`SupabaseAuthGateway({…, pkceStore})` defaults to the secure implementation, so **production is
fixed without any call-site change**.

### 5.3 Correct signup ordering, fail-closed on storage errors

```dart
final codeVerifier  = _generatePkceVerifier();
final codeChallenge = _generatePkceChallenge(codeVerifier);
try {
  await _pkceStore.write(codeVerifier);
  if (await _pkceStore.read() != codeVerifier) throw const FormatException(...);   // read-back
} catch (_) {
  throw AuthException('Secure storage is unavailable…', code: 'pkce-storage-failed');
}
// …only then POST /auth/v1/signup with code_challenge + code_challenge_method: 's256'
```

A signup is **never** sent when its verifier cannot be stored — otherwise the account would be
created and permanently unconfirmable.

### 5.4 Correct GoTrue exchange contract

```dart
POST {url}/auth/v1/token?grant_type=pkce
{ "auth_code": code, "code_verifier": storedVerifier }     // both in the BODY
```

The verifier is **read** from secure storage and never regenerated. If it is missing or
unreadable, the exchange is not attempted at all (`invalid-pkce-link`).

### 5.5 Session install before verifier cleanup

`_installSession(...)` runs first; the verifier is cleared only after the session is installed
**and** durable. A failed exchange deliberately leaves the verifier in place.

### 5.6 Duplicate-callback protection

A bounded `LinkedHashSet` of consumed authorization codes (max 16) means a repeat delivery of the
same link returns the already-installed session **without a second network exchange**. This covers
cold-start + stream double-delivery and double taps. Concurrent delivery cannot double-consume
because the single-use code is consumed by the first successful exchange.

### 5.7 Recovery flow brought onto PKCE

`requestPasswordReset` now sends its own `code_challenge`/`code_challenge_method: s256` and
persists its verifier, so a recovery link arrives as `?code=…` and is exchangeable.
`_handlePkceCode(..., isRecovery: type == 'recovery')` keeps recovery recovery-shaped and keeps
email confirmation out of the password-reset screen.

### 5.8 Correct journey on failure (§2.4)

```dart
final isRecoveryLink = error is AuthException && error.code == 'invalid-recovery-link';
_status = isRecoveryLink ? SessionStatus.recoveryLinkInvalid : SessionStatus.signedOut;
```

An invalid/expired **confirmation** link now returns the user to sign-in with an explanation
instead of showing a password-reset form.

### 5.9 Debug callback that works today (§2.3)

`android/app/src/debug/AndroidManifest.xml` gains:

```xml
<data android:scheme="legalserviceapp" android:host="auth-callback" />
```

A custom scheme needs **no** association document, so local Debug confirmation works immediately.
It is deliberately confined to `src/debug` — release keeps exactly one callback URI, the HTTPS
App Link. It also fits the existing design: `flutter_deeplinking_enabled=false` and `app_links`
remain the single deep-link consumer, so no conflict with Flutter's built-in deep linking is
introduced.

### 5.10 Hardening kept from the original design

Preserved unchanged: refresh-token rotation in secure storage, generation-based supersession,
the "fail closed on missing/incorrect profile role" rule, invite-callback rejection, the exact
redirect-URI match (scheme/host/port/path), and the ban on ever sending `service_role`.

---

## 6. Supabase integration status

Determined **only** from the code. No live project was queried, so *every table/column/RPC
assumption below is unverified against the database.*

| Feature | Screen(s) | Service | Backend objects referenced in code | Complete? | Errors | Loading/empty | Tests |
|---|---|---|---|---|---|---|---|
| Sign-in | `login_screen.dart` | `AuthService`→`SupabaseAuthGateway` | `POST /auth/v1/token?grant_type=password` | ✅ | ✅ mapped, opaque | ✅ | ✅ |
| Sign-up | `signup_sreeen.dart` | ditto | `POST /auth/v1/signup` | ✅ (now) | ✅ incl. `pkce-storage-failed` | ✅ | ✅ **new** |
| Email confirmation | `main.dart`→`SessionController` | ditto | `POST /auth/v1/token?grant_type=pkce` | ✅ (now) | ✅ | ✅ | ✅ **new** |
| Session restore | `app_bootstrap.dart` | ditto | `POST /auth/v1/token?grant_type=refresh_token` | ✅ | ✅ | n/a | ✅ |
| Password reset / change | `forgot_password.dart`, `reset_password.dart`, `profile/change_password.dart` | ditto | `POST /auth/v1/recover`, `PUT /auth/v1/user` | ✅ | ✅ | ✅ | ✅ |
| Profile | `profile/*` | `ApiClient.getMyProfile` | `GET/PATCH /rest/v1/users` (`id,uid,name,email,phone,role,avatar,address,onboarding_status`) | ✅ | ✅ 404 → session closed | ✅ | ✅ |
| Lawyer catalogue | `popularlawyers/`, `search/`, `home/` | `AppRepository.fetchLawyerPage` | `GET /rest/v1/lawyers` (`id,category_id,name,specialty,price,price_value,image,rating,location,experience,bio,is_popular,is_top`) | ✅ | ✅ | ✅ | ✅ |
| Categories | `commonwidgets/categories_*` | `fetchCategories` | `GET /rest/v1/legal_categories` (`id,name,slug`) | ✅ | ✅ | ✅ | ✅ |
| Availability | `availablitycalendar/` | `fetchAvailability` | `GET /rest/v1/availability` | ✅ | ✅ | ✅ | ✅ |
| Bookings | `booking/` | `createBooking`/`fetchBookings` | `GET /rest/v1/bookings`, `rpc_create_booking`, `rpc_cancel_booking` | ✅ | ✅ | ✅ | ✅ |
| Cases | `cases/*` | `AppRepository` cases block | `GET/POST/PATCH/DELETE /rest/v1/cases`, `rest/v1/tasks` | ✅ | ✅ | ✅ | partially |
| Documents | AI review | `uploadLegalDocumentPdf` | `POST /functions/v1/document-upload`, `storage/v1/object/legal-documents` | ✅ | ✅ | ✅ | ✅ |
| Chat / messages | `messages/` | `AppRepository` + `ChatRealtimeService` | `rest/v1/chats`, `rpc_chat_create`, `rpc_chat_start_with_lawyer`, `rpc_chat_messages_page`, Realtime WS | ✅ | ✅ | ✅ | ✅ |
| Favorites | `favorites/`, `bookmark/` | `fetchMyFavorites`/`addFavorite` | `GET /rest/v1/favorites` | ✅ | ✅ | ✅ | ✅ |
| Notifications | `settings/views/notifications.dart` | `fetchMyNotifications` | `GET /rest/v1/notifications` | ✅ | ✅ | ✅ | — |
| Wallet / earnings | `wallet/*`, `earnings/*` | `AppRepository` | `rest/v1/wallets`, `rest/v1/wallet_transactions`, `rest/v1/earnings`, `rpc_wallet_mutate` | ✅ | ✅ | ✅ | — |
| Subscriptions | `subscription/` | `AppRepository` | `rest/v1/plans`, `rest/v1/subscriptions`, `rpc_subscription_create` | ✅ | ✅ | ✅ | — |
| Reviews | `reviews/` | `AppRepository` | `rest/v1/public_reviews`, `rpc_review_delete` | ✅ | ✅ | ✅ | — |
| **Hearings** | — | — | **none** | ❌ **not implemented** | — | — | — |
| **Case history** | — | — | **none** | ❌ **not implemented** | — | — | — |
| **Admin panel** | — | — | none | ❌ **not in the mobile app** | — | — | — |

**Explicitly not implemented** (not invented, not claimed): *hearings*, *case history*. Both files
say so themselves — `cases/act.dart`: *"Hearing dates, documents, and case-history rows are
intentionally not…"*. Admin is **not** a mobile role: `isAdmin` appears only in
`AppRepository` ownership checks (`!profile.isAdmin && requested != profile.uid`) and one label in
`toppup.dart`; there is no admin dashboard, and per `docs/mobile_auth_recovery.md` lawyer
invitations are handled by a separate web dashboard that is **not** in this repository.

**Role enforcement (verified, preserved):** the client sends **no** role at signup; the profile is
read from `public.users`; access requires `isClient`, or `isLawyer` with
`onboarding_status == 'active'` **and** profile email == Auth email. An unrecognised role fails
closed to `SessionStatus.profileUnavailable`. Authorization is left to Postgres RLS.

---

## 7. PKCE implementation details

```
createAccount()
  ├─ _generatePkceVerifier()           32 CSPRNG bytes → base64url-unpadded (43 chars)
  ├─ _generatePkceChallenge(v)         BASE64URL(SHA256(UTF8(v))), padding stripped
  ├─ pkceStore.write(v)  + read-back   ← BEFORE the request; failure aborts signup
  └─ POST /auth/v1/signup?redirect_to=…
        { email, password, data:{name},
          code_challenge: <challenge>, code_challenge_method: "s256" }

… user taps the email link …

app_links  ── cold start: getInitialLink()  ─┐
           └─ warm start: uriLinkStream     ─┴→ SessionController._handleRecoveryLink
                                                    → gateway.restoreSession(callbackUri)

restoreSession → _restoreCallbackSession()
  ├─ merge query + fragment (query wins)
  ├─ type == 'invite'                        → ignore (web-dashboard only)
  ├─ exact redirect match (scheme/host/port/path) → else ignore
  ├─ error / error_code present              → invalid link
  ├─ `code` present, no tokens                → _handlePkceCode(code, isRecovery: type=='recovery')
  └─ implicit tokens (legacy)                 → preserved, unchanged

_handlePkceCode()
  ├─ already-consumed code?      → return current session (no 2nd exchange)
  ├─ pkceStore.read()            → missing/unreadable ⇒ invalid-pkce-link, NO request
  ├─ POST /auth/v1/token?grant_type=pkce  { auth_code, code_verifier }   ← same verifier
  ├─ 400/401/403 → invalid-pkce-link (expired / reused / mismatch); verifier retained
  ├─ _installSession(...)        → access token in memory, refresh token → secure storage
  └─ mark code consumed, then pkceStore.clear()
```

**Answer to "should the official SDK be used?"** — **No, not now.** Introducing
`supabase_flutter` would add a second, competing session manager alongside the existing
`AuthGateway`/`SecureAuthSessionStore`/`SessionController` spine, and the brief explicitly forbids
two session systems. The raw-HTTP implementation is now contract-correct and fully unit-tested
against a faithful GoTrue fake. If the SDK is ever adopted, it must **replace** `AuthGateway`, not
sit beside it.

---

## 8. Actual Android callback URI

Read from the **merged manifest** (`build/app/intermediates/merged_manifest/debug/processDebugMainManifest/AndroidManifest.xml`)
and confirmed inside the built APK with `aapt2 dump xmltree`:

| Build | Callback URI | Verified? |
|---|---|---|
| **Debug (today)** | `legalserviceapp://auth-callback` | ✅ present in merged manifest **and** in `app-debug.apk` |
| **Debug (also declared)** | `https://legal-dashboard-1.web.app/auth/callback` (`autoVerify=true`) | ⚠️ declared, but **cannot verify** — no `assetlinks.json` |
| Release | `https://legal-dashboard-1.web.app/auth/callback` only | ❌ unverified (no association file, release build not produced) |

App package: `com.example.legal_app` · `minSdk 24` · `targetSdk 36` ·
`flutter_deeplinking_enabled=false` (so `app_links` is the sole deep-link consumer).

### Deep-link verification status

* **Cold start** — implemented (`getInitialLink()` → `bootstrapApp(initialCallbackUri:)`) and
  exercised by the session-level test.
* **Warm start** — implemented (`appLinks.uriLinkStream` → `recoveryLinkStream` →
  `SessionController`) and exercised end-to-end in
  `pkce_email_confirmation_test.dart` ("the whole journey ends in SessionStatus.signedIn").
* **Duplicate delivery** — covered (sequential and concurrent).
* **HTTPS App Links** — **NOT verified.** `assetlinks.json` is missing (returns the SPA
  `index.html`), and the release signing certificate was not available to fingerprint. I am
  **not** claiming App Links are verified.

### Android screenshot / device smoke test

Not performed — no Android device or emulator is attached to this environment
(`flutter doctor` shows no Android toolchain until configured, and no device). The Debug APK was
built and inspected, not installed.

---

## 9. Test commands and real results

All commands were executed; the outputs below are the real ones.

### 9.1 New PKCE suite — PASS

```
$ flutter test test/pkce_email_confirmation_test.dart test/auth_deep_link_parsing_test.dart
00:00 +20: existing flows are unchanged a PKCE recovery callback lands on the reset-password flow
00:00 +21: end-to-end: register -> confirm -> protected session the whole journey ends in SessionStatus.signedIn
00:00 +22: loading .../auth_deep_link_parsing_test.dart
00:00 +24: All tests passed!
```

**24/24 passing**, proving each required property:

| Requirement | Test |
|---|---|
| Signup sends the correct S256 challenge and method | *the challenge is derived from the persisted verifier* |
| Challenge matches `SHA256(verifier)` exactly | *challenge is BASE64URL(SHA256(ASCII(verifier)))* + RFC 7636 Appendix B vector |
| Verifier is CSPRNG, 43 unreserved chars | *verifier is 43 unreserved chars and uses the CSPRNG* |
| Original verifier persisted **before** signup | *persists the verifier BEFORE the signup request* (`events == ['write','read']`) |
| The exact same verifier is used at exchange | *exchanges the code with the SAME verifier and installs a session* |
| Missing verifier prevents token exchange | *a missing verifier prevents the token exchange* (zero `/token` requests) |
| Storage failure prevents signup | *a storage failure prevents signup* (zero requests) |
| App restart preserves the verifier | *the verifier survives an app restart* (new gateway, same store) |
| Successful exchange installs + persists the session | *…and installs a session* (`getAccessToken`, refresh token stored, verifier cleared) |
| Duplicate callbacks handled safely | *duplicate callbacks only exchange once* + *concurrent duplicate delivery does not double-exchange* |
| Failed exchange keeps the verifier | *a rejected code leaves the user signed out…* |
| Login unchanged | *password sign-in still exchanges email/password for a session* |
| Implicit callback unchanged | *an implicit-flow recovery callback still works* |
| Recovery unchanged + now PKCE | *password reset sends an S256 challenge…*, *a PKCE recovery callback lands on the reset-password flow* |
| Wrong journey prevented | *an invalid confirmation link lands on sign-in, not password reset* |
| Non-configured origin ignored | *a callback for another origin is ignored* |
| Invite links still ignored | *an invite callback never creates an app session* |

The fake server is a faithful GoTrue model: it stores the challenge from `/signup`, recomputes
`SHA256(verifier)`, rejects missing `auth_code`/`code_verifier` with GoTrue's real message
(*"both auth code and code verifier should be non-empty"*), consumes the code on first use, and
returns `invalid_grant` afterwards.

### 9.2 Full suite — PASS

```
$ flutter test
01:22 +333: All tests passed!
EXIT:0
```

**333 tests, 0 failures, exit code 0.**

Three failures surfaced during this work and all three were resolved (none by weakening a test):

1. **`registration_safety_test.dart: confirmation-pending survives the signup null auth event`**
   — *Expected `email-confirmation-required`, actual `pkce-storage-failed`.* A genuine
   self-inflicted regression: my fail-closed keystore requirement made the test fall through to
   `SecurePkceVerifierStore`, which has no platform channel in unit tests. Fixed by extracting
   `MemoryPkceVerifierStore` into `test/support/fakes.dart` and injecting it everywhere a
   `SupabaseAuthGateway` is constructed in tests. **The production fail-closed rule was kept.**
2. **`home_restore_layout_test.dart` ×2 (390 px viewport, en + ar)** — a **pre-existing** layout
   defect, not caused by this audit. `homescreen.dart` computed
   `columns = width >= 150*2+16 ? 2 : 1`, which yields **2 columns at a 390 px phone width**
   (card ≈ 124 px), contradicting the documented intent directly above it
   (*"Minimum card width adjusted to fit two columns on mobile devices"*). The test correctly
   expects 1 column at 390 px. Fixed by raising `minCardWidth` to `200.0` so two columns only
   appear when each card can carry its thumbnail and 2-line title; the single column then gets the
   full width. `cardHeight` scales linearly with `cardWidth`, so clipping risk is reduced, and both
   large-text tests still pass.
3. **`auth_lifecycle_test.dart: password reset uses the explicitly allow-listed redirect`** — this
   test asserted the recovery body was exactly `{email}`. `requestPasswordReset` now also sends a
   PKCE challenge, so the assertion was updated to require the original `email` **plus**
   `code_challenge` (43 chars) and `code_challenge_method: s256`. The `redirect_to` expectation was
   left untouched.

---

## 10. Flutter analysis results

```
$ flutter analyze
27 issues found. (ran in 1.6s)
0 errors, 0 warnings, 27 info
```

Before → after:

| | Before | After |
|---|---|---|
| **errors** | **7** | **0** |
| **warnings** | **8** | **0** |
| info | 24 | 27 |

The 27 remaining `info` items are deprecation lints and style nits (§2.7). They are **not** build
or test blockers and were deliberately left alone to avoid an unrelated mass edit.

---

## 11. APK build status

```
$ flutter build apk --debug
Running Gradle task 'assembleDebug'...   118.1s
✓ Built build/app/outputs/flutter-apk/app-debug.apk
```

* Size 191,676,234 bytes · `minSdk 24` · `targetSdk 36` · package `com.example.legal_app`
* `aapt2 dump xmltree` confirms **both** `legalserviceapp://auth-callback` and the
  `https://legal-dashboard-1.web.app/auth/callback` filter are compiled in.

**Release build not attempted** (by design): `android/app/build.gradle.kts` hard-fails a release
task unless `-PlegalAndroidApplicationId`, `-PauthCallbackScheme/Host/Path` are supplied, and
release currently signs with the **debug** keystore (`signingConfigs.getByName("debug")`).

### Environment notes (why the first builds failed — not repository defects)

The sandbox has ~2 GB RAM and 2 cores while `android/gradle.properties` pins `-Xmx8G`:

1. build 1 → `Gradle build daemon disappeared unexpectedly` (OOM-killed)
2. overrode JVM args via a **user-level** `~/.gradle/gradle.properties` (repo untouched) → still OOM
3. added 4 GB swap → then `No space left on device` (18/25 GB used by SDK + duplicate SDKs)
4. cleaned duplicate Flutter copies → build 4 failed on a **real** merged-manifest error
   (`unexpected element <activity> found in <manifest>` — my `src/debug` block was outside
   `<application>`), which was fixed
5. build 5 → **success**

Steps 1–3 are environmental. Step 4 was a genuine defect in my first edit, caught by the build.

---

## 12. Remaining issues

**P1 — client/lawyer journeys (not fixed, out of P0 scope)**
* No navigator guards exist; protection relies entirely on the single `startScreenFor` decision
  point plus per-screen `SessionScope.of(context)` reads. Correct today, but fragile if a new
  screen forgets to read the session.
* `Cases` journeys are only partially covered by tests; case status transitions have no explicit
  state-machine test.

**P2 — Supabase/data**
* Every table/column/RPC name in §6 is inferred from client code. **Nothing was validated against
  the database**, including the `rpc_*` function names and the `users.or=(id, auth_user_id)`
  ownership query. This needs a schema/RLS review against the real project.
* **Hearings** and **case history** do not exist. Any UI copy implying them is unsupported.

**P3 — UI**
* `use_build_context_synchronously` at `chat_screen.dart:293`.
* ~12 deprecated-API lints (`withOpacity`, `TextFormField.value`, `Radio.groupValue`).

**P4 — cleanup**
* `firebase.json` + `google-services.json` are dead configuration (no Firebase dependency).
* Unused dependencies listed in §2.7.
* `pubspec.lock` needed no change but `flutter pub get` reported one dependency changed.

---

## 13. Recommended next steps

1. **Supabase dashboard (external, required):** add
   `legalserviceapp://auth-callback` **and** `https://legal-dashboard-1.web.app/auth/callback`
   to *Authentication → URL Configuration → Redirect URLs*, and rebuild with
   `SUPABASE_AUTH_REDIRECT_URL=legalserviceapp://auth-callback` and `ENABLE_CLIENT_SIGNUP=true`
   for a local Debug run.
2. **Publish `assetlinks.json`** for `legal-dashboard-1.web.app` containing the **release**
   signing certificate's SHA-256 and `package_name: com.example.legal_app`; add it to the web
   hosting rewrites so it is served before the SPA fallback. Then verify with
   `adb shell pm get-app-links com.example.legal_app`.
3. **Set up a real release signing config** (currently debug keys) and set
   `-PlegalAndroidApplicationId` to the operator-approved id — required before any store upload.
4. **Decide the production callback URI.** With `autoVerify` App Links broken *and* unverifiable
   in the current hosting setup, consider keeping the custom scheme for production too, or
   hosting a dedicated `/auth/callback` that does not fall through to the SPA.
5. **Manual device smoke test** of the 10-step journey in §7 on a physical Android device
   (cold start *and* warm start), which is the one thing this environment cannot demonstrate.
6. Validate the schema/RLS assumptions in §6 against the live project before enabling
   `USE_SUPABASE_FAVORITES` / `USE_SUPABASE_LAWYER_CATALOG`.
7. Remove the dead Firebase configuration and unused dependencies; lower `org.gradle.jvmargs`
   so contributors on modest machines can build.

---

## 14. Summary table

| | |
|---|---|
| **Verified** | Repo structure; 162 Dart files; no domain layer; no named routes; no bloc; Supabase is hand-rolled over `http` (no `supabase_flutter`); merged-manifest callback URIs; `assetlinks.json` absent (served SPA HTML); hearings/case-history/admin absent; role rules; secret scan clean (no service-role key in client code) |
| **Fixed** | Dependency resolution; 7 compile errors; PKCE hashing; verifier persistence (keystore); exchange wire contract; install-before-clear ordering; duplicate-callback protection; recovery PKCE; callback-failure routing; debug callback URI |
| **Tested** | 24 new tests (21 PKCE + 3 deep-link) passing; **full suite 333/333 passing (exit 0)**; `flutter analyze` 0 errors / 0 warnings; Debug APK built and manifest-inspected |
| **Not verified** | Anything requiring the live Supabase project (schema, RLS, actual email delivery); Android device behaviour; HTTPS App Links association; release build/signing; iOS universal links |
| **Requires external configuration** | Supabase redirect allow-list; `assetlinks.json` on the web host; release keystore + `-P` properties; device for smoke testing |
