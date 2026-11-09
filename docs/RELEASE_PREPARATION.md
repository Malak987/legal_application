# Legal App — Release Preparation

Verified against the repository and the live Supabase project
`legal` (`qqfzbecwhewswkyxgebu`, `eu-west-1`, PostgreSQL 17) on 2026-11-08.

---

## 1. Store identifiers

| Platform | Where it is defined | Default in the repo |
|---|---|---|
| Android application id | `-PlegalAndroidApplicationId` → `applicationId` and `namespace` in `android/app/build.gradle.kts` | `com.example.legal_app` |
| iOS bundle id | `LEGAL_IOS_BUNDLE_ID` build setting in `ios/Runner.xcodeproj/project.pbxproj` | set per xcconfig |

The Android **release** build already refuses to run while the application id is
still the placeholder:

```
Set -PlegalAndroidApplicationId to the operator-approved Android application ID.
```

It also requires `-PauthCallbackScheme`, `-PauthCallbackHost` and
`-PauthCallbackPath` (defaults for local builds live in
`android/gradle.properties`).

`ios/RunnerTests` still carries the literal `com.example.legalApp.RunnerTests`
bundle identifier. That only affects the unit-test target, not the App Store
binary, but it should be aligned with the approved bundle id when the id is
finalised.

---

## 2. Supabase configuration

The public URL is compiled to the correct production project by default
(`https://qqfzbecwhewswkyxgebu.supabase.co`). The public key is **not** in the
repository and must be supplied at build time:

```bash
flutter build appbundle --release \
  --dart-define=SUPABASE_URL=https://qqfzbecwhewswkyxgebu.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<public anon/publishable key> \
  --dart-define=SUPABASE_AUTH_REDIRECT_URL=legalserviceapp://auth-callback
```

- Only the **anon/publishable** key belongs in the client. `SupabaseClientConfig`
  rejects `sb_secret_*` keys and JWTs whose `role` is `service_role`, and refuses
  to start if the key belongs to a different project than the URL.
- `supabase.local.example.json` is a template. The real file
  (`supabase.local.json`) is git-ignored and must never be committed.
- Auth redirect allow-list is already correct:
  `legalserviceapp://auth-callback` and
  `https://legal-dashboard-1.web.app/auth/callback`.

---

## 3. Android release checklist

1. **Create the upload keystore** (once, then keep it safe):
   ```bash
   keytool -genkey -v -keystore keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias legal
   ```
2. **Provide `android/key.properties`** (git-ignored):
   ```properties
   storeFile=/absolute/path/to/keystore.jks
   storePassword=...
   keyAlias=legal
   keyPassword=...
   ```
   `android/app/build.gradle.kts` now uses it for `buildTypes.release`.
   **If the file is missing the build still succeeds but signs with the debug
   key and prints a loud warning — Google Play rejects debug-signed bundles.**
3. **Build**:
   ```bash
   flutter build appbundle --release \
     -PlegalAndroidApplicationId=com.company.legalapp \
     --dart-define=SUPABASE_URL=... \
     --dart-define=SUPABASE_ANON_KEY=...
   ```
4. **Upload** the `.aab` to the Play Console (internal testing first).

---

## 4. iOS release checklist (Codemagic)

1. Apple Developer Program membership + App Store Connect record for the bundle id.
2. Upload the iOS distribution certificate and provisioning profile to Codemagic.
3. Set `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_AUTH_REDIRECT_URL` and
   `LEGAL_IOS_BUNDLE_ID` as encrypted Codemagic variables.
4. Run `ios-release-build` (or push a tag — both store workflows trigger on tags).

`codemagic.yaml` also provides an `android-release-build` workflow and a
`verify` workflow that runs `flutter analyze` and `flutter test` on every push.

---

## 5. Sign in with Apple — **not applicable**

The previous version of this document required Sign in with Apple because it
assumed Google/Facebook social login. That is no longer true:

- No OAuth provider is enabled in Supabase Auth (`external_google_enabled`,
  `external_facebook_enabled`, `external_apple_enabled` are all `false`).
- There is no `signInWithOAuth` call anywhere in the Flutter code.

Authentication is **email + password only**, so App Review Guideline 4.8 does
not apply. If social login is added later, this section must be revisited.

---

## 6. Account deletion (App Store Guideline 5.1.1(v))

In-app account deletion is implemented and satisfies the guideline:

- `views/profile/delete_account.dart` requires typing the confirmation word and a
  second modal confirmation.
- The `delete-my-account` Edge Function verifies the bearer JWT server-side,
  refuses any request that names a different target, refuses `owner`/`admin`
  accounts, purges the caller's storage objects, revokes sessions, then deletes
  the Auth user.
- Database `ON DELETE CASCADE` removes the profile and every dependent row, and
  `private.purge_user_chats_before_delete()` removes the caller's chats.

Deletion is **complete**, not anonymisation. The on-screen copy states this.

---

## 7. Outstanding manual actions before submission

| # | Action | Why |
|---|---|---|
| 1 | Create the Android upload keystore and supply `key.properties` | Release AAB must be signed with a real key |
| 2 | Decide the final Android application id and iOS bundle id | Placeholders are still the defaults |
| 3 | Register the Syncfusion licence | `syncfusion_flutter_pdf` and `syncfusion_flutter_sliders` are used and no `SyncfusionLicense.registerLicense()` call exists; unlicensed builds render a licence banner |
| 4 | Align `ios/RunnerTests` bundle id | Still `com.example.legalApp.RunnerTests` |
| 5 | Consider raising `password_min_length` above 6 and enabling CAPTCHA/HIBP in Supabase Auth | Current auth config has the 6-character minimum, CAPTCHA off and breached-password checks off |
| 6 | Confirm whether documents are meant to be uploaded by clients | `storage.objects` has SELECT and DELETE policies for `legal-documents` but **no INSERT policy**, so client uploads are rejected by RLS |

---

## 8. Verification performed

- `flutter analyze --fatal-infos`, `dart format` check and `flutter test` run in
  GitHub Actions (`.github/workflows/ci.yml`) on every push and pull request.
- `deno test` runs the `delete-my-account` Edge Function suite.
- A bundle-drift job re-runs `bundle.py` and fails if
  `supabase/functions/delete-my-account/dist/index.ts` is out of sync.
