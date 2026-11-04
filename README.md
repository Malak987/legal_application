# Legal Services — Mobile App (`legal_app`)

Flutter client for the Legal Services platform. It uses **Supabase** directly: Supabase Auth (password sign-in, refresh-token sessions, password recovery), PostgREST/RPC under RLS, and private Storage. AI/document-upload Edge Function source exists, but no Edge Functions are deployed to the connected project yet; those screens are not live. The client does not call the Express/Cloud Functions API and has no Firebase client SDK/configuration dependency.

## Supabase configuration (required)

The app needs two **public** values, compiled in as Dart defines:

| Define | Value |
|--------|-------|
| `SUPABASE_URL` | `https://qqfzbecwhewswkyxgebu.supabase.co` (default if omitted) |
| `SUPABASE_ANON_KEY` | The project's public **publishable** key (`sb_publishable_…`) or legacy **anon** key. No default. |
| `SUPABASE_AUTH_REDIRECT_URL` | `https://legal-dashboard-1.web.app/auth/callback` — the verified HTTPS callback used by mobile password recovery. Lawyer invitations are activated on the web dashboard and do not use a native callback. It is already in the Supabase Auth redirect allow-list. |

`lib/config/supabase_client_config.dart` validates these values **once at startup**: presence, URL format (`https`; `http` only for localhost/`10.0.2.2`), public-key format, wrong-project legacy keys, and secret/service-role keys. The one validated config is shared by sign-in, session restoration and every data request. If it is invalid, the app shows a configuration screen that names the missing define and makes no network request.

**Never** use a `service_role` or `sb_secret_…` key in this app. The app and the helper both refuse it.

### Local config and normal development workflow

Use the ignored `legal_app/supabase.local.json`. Create it only when it is absent, so an existing local configuration is never overwritten:

```bash
cd legal_app
[ -e supabase.local.json ] || cp supabase.local.example.json supabase.local.json
```

The example contains only this project's public publishable key and the exact callback used by the invitation server and password recovery. Keep that callback unchanged unless the server redirect and the Supabase Auth allow-list are deliberately changed together. Never put a service-role/secret key in this file; the helper rejects those field names without reading or printing their values because Flutter's `--dart-define-from-file` passes every field to the app.

The app's normal startup validates the compiled defines before creating Supabase clients. The validating helper additionally checks the local file before invoking Flutter, prints only a redacted key description, and removes `SUPABASE_SERVICE_ROLE_KEY` / `SUPABASE_SECRET_KEY` from Flutter's process environment.

**VS Code:** open the repository root, choose an Android device in the device selector, and press Run on **Legal App Android (local Supabase)**. The checked-in launch configuration passes `--dart-define-from-file=supabase.local.json`; its pre-launch task validates that exact file first. A second iOS profile is available on macOS/Xcode hosts.

**Android Studio/IntelliJ:** set the Flutter run configuration's working directory to `legal_app`, entry point to `lib/main.dart`, and Additional run args to `--dart-define-from-file=supabase.local.json`. Add a Before Launch External Tool running `dart run tool/supabase_flutter.dart validate --file-only` with working directory `legal_app`. Set `SUPABASE_SERVICE_ROLE_KEY` and `SUPABASE_SECRET_KEY` to empty values in the Flutter Run configuration's environment so parent-process secrets cannot be inherited. The preflight must complete before Flutter Run starts.

For terminal development, use the validated wrapper (replace the device ID with one shown by `flutter devices`):

```bash
cd legal_app
dart run tool/supabase_flutter.dart run -d <android-device-id>
```

A bare `flutter run` does **not** read `supabase.local.json`. Use the validated wrapper or preflighted IDE profiles rather than bypassing validation with raw Flutter commands. Defines are fixed at compile time; stop and relaunch after changing them because hot restart does not update them.

### Release builds

Run the same validating wrapper from `legal_app`:

```bash
# Android release APK
dart run tool/supabase_flutter.dart build apk --release

# Android Play Store bundle
dart run tool/supabase_flutter.dart build appbundle --release

# iOS IPA (macOS + Xcode only)
dart run tool/supabase_flutter.dart build ipa --release
```

The wrapper validates URL/key and project mismatch where detectable, injects the resolved values into that exact build, and fails before Flutter if the public key is missing, a placeholder, malformed, or secret/service-role. For an Xcode archive, first run `dart run tool/supabase_flutter.dart build ios --release --config-only`, then archive using the generated Flutter configuration. Never build release artifacts by invoking Gradle/Xcode directly without passing the validated Flutter defines.

The same local file is used on Android and iOS for the project URL, public key, and the verified HTTPS callback. Native links are restricted to `https://legal-dashboard-1.web.app/auth/callback`.

#### Lawyer invitations are web-only

The invited lawyer activates the account in a browser:

1. The invitation email from the `invite-lawyer` Edge Function redirects to `https://legal-dashboard-1.web.app/auth/callback` with `type=invite`.
2. The dashboard validates the verified callback, confirms the Auth email, and requires the server-managed `public.users` profile to be `role=lawyer` with `onboarding_status=active` and a matching email.
3. The dedicated dashboard page asks for the password (at least 8 characters, confirmed) and updates it with the short-lived callback token, which is kept in memory only and revoked afterwards.
4. The page shows: "Your account has been activated successfully. Open the Legal app and sign in using your email and password."
5. The lawyer signs in to this app with that email and password.

No Android App Link, iOS Universal Link, association document, signing fingerprint, Apple account, Mac or iPhone is involved, and the app rejects a stray `type=invite` callback instead of creating an invitation session. Native callback handling remains only for optional mobile password recovery (see `docs/mobile_auth_recovery.md`). Ordinary client sign-up stays separate and never accepts a role or lawyer/profile ID from the app.

The project URL and public key are compile-time client configuration, not secrets.

## Deliberately unavailable legacy screens

The active booking-history route is backed by the signed-in user's Supabase bookings. The separate `HistoryScreen` still contains unrelated sample places/caregivers and is not routed from active navigation. The old retail cart/checkout files are likewise disconnected from the app's primary routes. Both duplicate payment-screen implementations now show an explicit unavailable message, collect no card details, and cannot navigate to an order-success screen. No payment-provider/webhook reconciliation or paid booking creation is deployed; do not enable checkout until that server-verified flow exists.

## Checks

```bash
cd legal_app
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test            # no key needed; configuration tests use fake values
```

## CI

The `legal-app` CI job only analyzes and tests, so it needs no key and builds no artifact. Nothing can ship from it with a fabricated key. A future mobile build job must run `dart run tool/supabase_flutter.dart build …` with `SUPABASE_ANON_KEY` supplied from a repository variable. The helper fails on a missing, placeholder or secret key instead of building.
