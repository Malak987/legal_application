# Legal App — Cross-Platform Release Preparation Guide

This document outlines the operational and technical steps required to publish **Legal App** to the Google Play Store and Apple App Store.

---

## 1. Store Identifiers & Configuration

Before generating final store binaries, update the placeholder identifiers with the company's official registered identifiers:

- **Android Application ID:** Replace `com.example.legal_app` in Gradle properties or build commands with the official package name (e.g., `com.company.legalapp`).
- **iOS Bundle ID:** Replace `com.example.legalApp` in `ios/Runner.xcodeproj/project.pbxproj` (`LEGAL_IOS_BUNDLE_ID`) with the official App Store Connect bundle identifier (e.g., `com.company.legalapp`).

---

## 2. Android Release Checklist

1. **Keystore Configuration:** Generate a production release keystore (`keystore.jks`) using keytool.
2. **Signing Properties:** Configure `android/key.properties` with store file path, store password, key alias, and key password.
3. **Build Command:**
   ```bash
   flutter build appbundle --release \
     --dart-define=SUPABASE_URL=https://<project>.supabase.co \
     --dart-define=SUPABASE_ANON_KEY=<public-key>
   ```
4. **Google Play Console:** Upload the signed `.aab` to the Google Play Console internal testing track.

---

## 3. iOS Release Checklist (Codemagic CI/CD)

1. **Apple Developer Account:** Ensure an active Apple Developer Program membership.
2. **App Store Connect Record:** Create the app record using your approved Bundle ID.
3. **Signing:** Upload your iOS distribution certificate and provisioning profile to Codemagic.
4. **Environment Variables:** Set `SUPABASE_URL` and `SUPABASE_ANON_KEY` in Codemagic environment variables.
5. **Trigger Build:** Run the `ios-release-build` workflow in Codemagic to generate the signed `.ipa`.

---

## 4. Sign in with Apple Compliance (Guideline 4.8)

Because the app offers Google and Facebook social login options, **Sign in with Apple** is required by Apple App Review Guideline 4.8.

- **Capability:** Add `com.apple.developer.applesignin` to `ios/Runner.entitlements`.
- **Supabase Auth:** Enable Apple Provider in the Supabase Dashboard Authentication settings.
- **Implementation:** Integrate `supabase.auth.signInWithOAuth(OAuthProvider.apple)` within `AuthService`.
