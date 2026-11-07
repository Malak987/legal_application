# Physical Android device test — email confirmation (PKCE)

Runbook for a controlled Debug-device test of the signup → email confirmation → session journey.
**Nothing in this document has been executed against the live Supabase project.**

---

## 1. What is already proven in code (no device needed)

| # | Claim | Evidence |
|---|---|---|
| 1 | The real signup request sends `redirect_to=legalserviceapp://auth-callback` | `test/debug_redirect_wiring_test.dart` → *"redirect_to is exactly legalserviceapp://auth-callback"* asserts the URL on the actual `POST /auth/v1/signup` |
| 2 | Recovery email uses the same redirect | same file → *"the same redirect is used for the recovery email"* |
| 3 | The custom-scheme callback is accepted by the redirect guard | *"the custom-scheme redirect is accepted by redirect matching"* |
| 4 | A different scheme is still rejected | *"a callback on a different scheme is still rejected"* (0 network calls) |
| 5 | `SUPABASE_AUTH_REDIRECT_URL` + `ENABLE_CLIENT_SIGNUP` reach the flutter command | `test/supabase_flutter_tool_test.dart` → *"ENABLE_CLIENT_SIGNUP and the redirect reach the flutter command"* |
| 6 | The URI is compiled into the shipped APK | `aapt2 dump xmltree` shows `scheme="legalserviceapp" host="auth-callback"`; the string is also present in `kernel_blob.bin` |
| 7 | One verifier, replaced only by a new pending flow | `test/pkce_email_confirmation_test.dart` → *single-verifier lifecycle* (4 tests) |

---

## 2. REQUIRES EXTERNAL CONFIGURATION — Supabase redirect allow-list

The app now sends `redirect_to=legalserviceapp://auth-callback`. **Supabase Auth rejects a
`redirect_to` that is not in its allow-list** (it falls back to `SITE_URL`), so the confirmation
email will not deep-link into the app until this is configured.

> This is a **dashboard/configuration** change. It was **not** made here, and the live project was
> not contacted or modified.

**Where:** Supabase Dashboard → *Authentication* → *URL Configuration* → **Redirect URLs** → add:

```
legalserviceapp://auth-callback
```

Keep the existing entry if recovery must also work from the web dashboard:

```
https://legal-dashboard-1.web.app/auth/callback
```

**Notes**
* Match the string exactly: lowercase scheme, single dash, no trailing slash.
* A custom scheme does **not** need `assetlinks.json`, so this works on a physical device today.
* If your project uses the newer "Redirect URLs allow-list" with wildcards, `legalserviceapp://*`
  would also work — prefer the exact URI.

---

## 3. Build the Debug APK

```bash
cd legal_application

flutter build apk --debug \
  --dart-define=SUPABASE_URL=https://qqfzbecwhewswkyxgebu.supabase.co \
  --dart-define=SUPABASE_AUTH_REDIRECT_URL=legalserviceapp://auth-callback \
  --dart-define=ENABLE_CLIENT_SIGNUP=true
```

`SUPABASE_ANON_KEY` must also be supplied or the app shows the configuration screen.
Two equivalent options:

```bash
# A. local file (git-ignored) — copy the example and paste the PUBLIC key
cp supabase.local.example.json supabase.local.json
flutter build apk --debug --dart-define-from-file=supabase.local.json

# B. the custom helper (resolves env → supabase.local.json)
export SUPABASE_ANON_KEY='sb_publishable_…'
export SUPABASE_AUTH_REDIRECT_URL='legalserviceapp://auth-callback'
export ENABLE_CLIENT_SIGNUP='true'
dart run tool/supabase_flutter.dart build apk --debug
```

> The helper **refuses** to accept Supabase defines on its own command line — it supplies them.
> Never use a `service_role`/`secret` key; `SupabaseClientConfig` rejects it at startup.

### Warnings
* Defines are compiled in. Changing one requires a full rebuild — **hot restart does not apply
  them**.
* Debug builds declare **two** callbacks: `legalserviceapp://auth-callback` and the unverified
  HTTPS App Link. Release keeps only the HTTPS one.
* `android/gradle.properties` pins `org.gradle.jvmargs=-Xmx8G`. On a machine with less RAM,
  override it in the **user-level** `~/.gradle/gradle.properties`, not in the repo.

---

## 4. Install

```bash
adb devices
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

If an older build with a different manifest is installed, uninstall first so the intent filter is
re-registered:

```bash
adb uninstall com.example.legal_app
adb install build/app/outputs/flutter-apk/app-debug.apk
```

### Verify Android routed the scheme to the app

```bash
adb shell pm query-activities -a android.intent.action.VIEW \
  -d "legalserviceapp://auth-callback?code=test&type=signup"
```
The result must list `com.example.legal_app/.MainActivity`.
(The HTTPS App Link will **not** appear as verified: `assetlinks.json` is not published — check
with `adb shell pm get-app-links com.example.legal_app`, expecting `none`/`unverified` for
`legal-dashboard-1.web.app`.)

---

## 5. Manual journey

1. Launch the app. First run shows the auth flow.
2. **Register** with a fresh, real email address + password. Expect the *"check your inbox"*
   message (registration is compiled in only because `ENABLE_CLIENT_SIGNUP=true`).
3. Confirm the app did **not** enter the signed-in UI (no session yet).
4. Open the email **on the device** and tap the confirmation link.
5. Android must show a chooser or open the app directly via `legalserviceapp://auth-callback?code=…&type=signup`.
6. The app should resolve the callback, exchange the code, install the session and land on Home.
7. Kill the app (`adb shell am force-stop com.example.legal_app`) and relaunch → it must restore
   the session without a second sign-in.

### Watch it happen

```bash
adb logcat -c && adb logcat | grep -Ei "flutter|AndroidRuntime|legal_app"
```

Tap the link **twice** in step 5 to confirm the duplicate-callback guard: the app must not
double-exchange or sign itself out.

### Expected failure modes

| Observation | Meaning |
|---|---|
| Link opens the **browser**, app never launches | Supabase dropped the `redirect_to` (URI missing from the allow-list) → §2 |
| App opens, then shows *"This email-confirmation link is invalid or has expired"* | Code expired (≈5 min), reused, or the verifier was cleared (app data wiped / different device) |
| App opens and immediately returns to sign-in with a confirmation error | Same as above; this is the corrected routing (previously it showed a *password-reset* form) |
| *"Secure storage is unavailable…"* during signup | Keystore unavailable on the device — no account was created |

---

## 6. What this runbook deliberately does NOT do

* Does not contact, deploy to, or modify the Supabase project.
* Does not change database configuration or production redirect settings.
* Does not claim any physical-device result.
