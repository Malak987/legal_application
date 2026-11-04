# Samaha visual revision — local review guide

Date: 2026-11-02. Source baseline HEAD: `e5911a6d1c31a64d5b8159cf8726626703beac20`.

The application source is complete within the portable-source exclusions documented in the delivery manifest. This is **not a deployed or release-approved build**.

## Run the isolated visual preview

Validated SDK: Flutter 3.47.0 / Dart 3.13.0.

```sh
flutter pub get
flutter run -d web-server --web-hostname=0.0.0.0 --web-port=8790 \
  --dart-define=SAMAHA_LOCAL_PREVIEW=true -t tool/samaha_preview.dart
```

The preview executes the real Home/directory widgets and the real bundled JSON/media. Operational Home responses and the auth gateway are explicitly mocked. It cannot establish production availability, account flows or access-control behavior. `lib/main.dart` remains the real application entrypoint; it does not import this preview.

## Validation

```sh
flutter test --no-pub
flutter analyze --no-pub
```

The final full suite passed **282 tests**. Analyzer exit 1 reports the **same 27 pre-existing findings** as baseline (5 warnings, 22 infos), not a clean analyzer run. New tests cover PageStorage isolation and provenance lifecycle, original portraits and permission/subject gates, bilingual filters, neutral image fallback and scoped text-color contrast. Existing operational test files remain unchanged.

## Content and photographs

The nine registered JSON files under `assets/data/samaha/` are the only runtime editorial authority. They contain 28 published person records and 26 original photographs. Review manifests and historical generators are not competing runtime sources. The two conflicting photographs remain withheld, and missing media uses a neutral symbol rather than an unrelated portrait.

The requester selected **“لدي إذن باستخدام الصور”** for the 26 clearly associated photos. This is recorded as a user declaration, not a verified licence or supplied permission document. Read [SAMAHA_MEDIA_RIGHTS.md](SAMAHA_MEDIA_RIGHTS.md) before any publication. No bios, credentials, office operation or platform accounts are inferred from published names or photos.

## Portable-source limitations

Actual key-bearing `android/app/google-services.json` and `supabase.local.example.json` are excluded from the delivered ZIP only; their original source files are not modified. Machine caches, SDKs, build outputs and local environment files are not packaged. Existing package/Bundle IDs, platform files and dependency lockfile remain unchanged. Supply approved local configuration through the existing configuration flow; never put secret/service-role credentials in the Flutter client.

Android wrapper scripts/JAR and iOS/macOS Podfiles were absent in the supplied source and were not fabricated. No native build, production auth/service test, release build, public deployment or new cold-offline/PWA test is claimed.
