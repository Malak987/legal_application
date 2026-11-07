# Android device test — signup, email confirmation, PKCE

Manual test on a physical Android phone (written for a OnePlus **CPH2737**, but the
commands are device-agnostic). **No physical-device test has been performed.**

---

## 0. Current build status

| Item | Status |
|---|---|
| Code, tests, analyzer | complete — 371/371 tests, 0 errors, 0 warnings |
| Debug APK | **not built for device testing** — the local Supabase publishable key is absent |
| Supabase redirect allow-list | **requires the project owner** (§2) |
| HTTPS App Links / `assetlinks.json` | **not published** — not used for this test |

Without the key the app boots straight to `SupabaseConfigErrorApp`, so an APK built
today could not exercise signup. It is deliberately not offered as a deliverable.

### Build the APK once the key is supplied

```bash
cd legal_application
cp supabase.local.example.json supabase.local.json
# edit supabase.local.json: paste the project's PUBLIC publishable/anon key
# (Authentication → Project Settings → API keys). NEVER a service_role/secret key.

export ENABLE_CLIENT_SIGNUP=true
export SUPABASE_AUTH_REDIRECT_URL='legalserviceapp://auth-callback'
dart run tool/supabase_flutter.dart build apk --debug
```

`supabase.local.json` is git-ignored. The helper reads the key from that file (or the
`SUPABASE_ANON_KEY` environment variable), validates it, and refuses to run if it is
missing, malformed, or a secret key. It never prints the key — only a redacted form.

Output: `build/app/outputs/flutter-apk/app-debug.apk`

---

## 1. Prerequisites

* Android platform-tools on the workstation (`adb version`).
* Phone with **USB debugging** on: Settings → About device → tap *Build number* 7×,
  then Settings → System → Developer options → USB debugging.
* The phone connected and authorised (`adb devices` shows `device`, not `unauthorized`).
* A real email inbox you can open **on the phone**.

Sanity check the APK you are about to install:

```bash
APK=build/app/outputs/flutter-apk/app-debug.apk
ls -l "$APK" && sha256sum "$APK"
$ANDROID_HOME/build-tools/36.0.0/aapt2 dump badging "$APK" | head -3
$ANDROID_HOME/build-tools/36.0.0/aapt2 dump xmltree "$APK" --file AndroidManifest.xml \
  | grep -E 'scheme|host|path' 
```

Expected in the manifest dump: `scheme="legalserviceapp" host="auth-callback"`.

---

## 2. Required Supabase configuration (project owner only)

**Not done by this task — do not skip it.** Supabase silently replaces an unlisted
`redirect_to` with `SITE_URL`, which is why a confirmation link would open the browser
instead of the app.

Dashboard → **Authentication** → **URL Configuration** → **Redirect URLs** → add:

```
legalserviceapp://auth-callback
```

* Exact string: lowercase scheme, one dash, no trailing slash.
* A custom scheme needs no `assetlinks.json`.
* Keep `https://legal-dashboard-1.web.app/auth/callback` if the web dashboard must
  still handle recovery.

Also confirm **Authentication → Providers → Email** has *Confirm email* enabled — the
whole flow depends on it.

---

## 3. Install

```bash
# Remove any previous build so the intent filter is re-registered
adb uninstall com.example.legal_app || true
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Expected: `Success`.

---

## 4. Verify Android routes the deep link to the app

```bash
adb shell pm query-activities -a android.intent.action.VIEW \
  -d "legalserviceapp://auth-callback?code=test&type=signup"
```

The result **must** list `com.example.legal_app/.MainActivity`.

If it is empty, the installed APK is not the one you think it is — reinstall and
re-check. (The HTTPS App Link in the same manifest will show `unverified`; that is
expected and is why the custom scheme is used.)

---

## 5. Start logging

In a second terminal:

```bash
adb logcat -c
adb logcat | grep -Ei 'flutter|AndroidRuntime|legal_app|ActivityTaskManager'
```

---

## 6. Run the journey

| # | Action | Expected |
|---|---|---|
| 1 | Launch the app | Auth flow (not the configuration-error screen) |
| 2 | Open **Sign up**, register with a fresh email + password | *"check your inbox, confirm, then sign in"* |
| 3 | Observe the app | Stays **signed out** — no session until confirmation |
| 4 | Open the confirmation email **on the phone** | A button/link to confirm |
| 5 | Tap it | App comes to the foreground (directly, or via a chooser → *Legal*) |
| 6 | Watch the app | Briefly resolving, then **Home**, signed in |
| 7 | Check logcat | No `invalid_grant`, no `both auth code and code verifier should be non-empty` |
| 8 | `adb shell am force-stop com.example.legal_app` then relaunch | Still signed in (session restored from the keystore) |
| 9 | Sign out from the app | Returns to the auth flow |
| 10 | Relaunch | Signed out |

### Duplicate-delivery check

Repeat steps 4–5 by tapping the *same* link a second time (from an already-opened
email). The app must **not** error and must **not** sign itself out — the consumed
code is recognised and the existing session is returned.

### Concurrent-flow check (signup vs recovery)

1. Request a password reset for the same address, then immediately register a second
   account with a different address.
2. Confirm **both** links. Each must complete independently: requesting the reset must
   not invalidate the pending confirmation, and vice versa.

---

## 7. Diagnosing failures

Capture a focused log for a report:

```bash
adb logcat -d | grep -Ei 'flutter|legal_app' | tail -200 > auth-test.log
```

| Symptom | Likely cause | Check |
|---|---|---|
| Link opens the **browser**, app never launches | `redirect_to` not allow-listed, so Supabase substituted `SITE_URL` | §2; confirm the string is exact |
| App launches but shows *"This email-confirmation link is invalid or has expired"* | Code expired (~5 min), already used, or **no verifier on this device** (different device / app data cleared / app reinstalled) | Did you reinstall between steps 2 and 5? Reinstalling wipes the keystore |
| App launches, then returns to sign-in with a confirmation error | Same as above; this is the intended routing (a failed **confirmation** must not show the password-reset form) | logcat for `invalid-pkce-link` |
| *"Secure storage is unavailable…"* at signup | Keystore unavailable (locked device, keystore reset) | Unlock the phone; retry. **No account was created.** |
| App stuck on the splash/resolving screen | Profile load failing after a successful exchange | logcat for `/rest/v1/users` errors; check RLS for the new user |
| `both auth code and code verifier should be non-empty` | The app sent no verifier — should be impossible now | Report it: `test/pkce_email_confirmation_test.dart` proves the request shape |
| `code challenge does not match` | Verifier/flow mismatch — several same-purpose flows outstanding (see `docs/AUTH_PKCE_ARCHITECTURE.md`, limitation 1) | Confirm the newest email for that purpose |
| Signup does nothing / *"Registration is currently unavailable"* | APK built without `ENABLE_CLIENT_SIGNUP=true` | Rebuild with the helper (§0) |
| Configuration-error screen at launch | APK built without a valid `SUPABASE_ANON_KEY` | Rebuild (§0) |

---

## 8. Production readiness (NOT done, and not claimed)

The HTTPS App Link `https://legal-dashboard-1.web.app/auth/callback` in
`src/main/AndroidManifest.xml` carries `android:autoVerify="true"`, but
`https://legal-dashboard-1.web.app/.well-known/assetlinks.json` currently returns the
Flutter SPA `index.html`, not a Digital Asset Links document. Until that file is
published with the **release** signing certificate's SHA-256 and
`package_name: com.example.legal_app`, Android will not associate the app with that
link. The custom scheme is the working path for local testing; App Links are **not**
verified and must not be described as ready for production.
