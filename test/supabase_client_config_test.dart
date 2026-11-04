import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:legalserviceapp/config/supabase_client_config.dart';
import 'package:legalserviceapp/config/supabase_config.dart';

// Test-only fixtures. None of these is a real project credential.
const _url = 'https://qqfzbecwhewswkyxgebu.supabase.co';
const _publishable = 'sb_publishable_TESTONLY_not_a_real_key_0000';

String _jwt(Map<String, Object?> claims) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(claims)}.test-signature';
}

List<SupabaseConfigIssue> _issues(
  String url,
  String key, {
  bool strict = true,
}) =>
    SupabaseClientConfig.resolve(
      url: url,
      anonKey: key,
      requireKnownKeyFormat: strict,
    ).issues;

void main() {
  group('valid public configuration', () {
    test('project URL with a publishable key', () {
      final config = SupabaseClientConfig.resolve(
        url: '$_url/',
        anonKey: _publishable,
      );
      expect(config.isValid, isTrue);
      expect(config.url, _url, reason: 'trailing slash is normalized');
      expect(config.anonKey, _publishable);
      expect(config.errorMessage, isEmpty);
    });

    test('legacy anon JWT for the same project', () {
      expect(
        _issues(_url, _jwt({'role': 'anon', 'ref': 'qqfzbecwhewswkyxgebu'})),
        isEmpty,
      );
    });

    test(
      'http only for a local stack, including the Android emulator host',
      () {
        expect(_issues('http://127.0.0.1:54321', _publishable), isEmpty);
        expect(_issues('http://localhost:54321', _publishable), isEmpty);
        expect(_issues('http://10.0.2.2:54321', _publishable), isEmpty);
        expect(
          _issues('http://qqfzbecwhewswkyxgebu.supabase.co', _publishable),
          [SupabaseConfigIssue.insecureUrl],
        );
      },
    );
  });

  group('missing and empty values', () {
    test('missing URL', () {
      expect(_issues('', _publishable), [SupabaseConfigIssue.missingUrl]);
    });

    test('missing key', () {
      expect(_issues(_url, ''), [SupabaseConfigIssue.missingKey]);
    });

    test('whitespace-only values count as empty', () {
      expect(_issues('  ', ' \n '), [
        SupabaseConfigIssue.missingUrl,
        SupabaseConfigIssue.missingKey,
      ]);
    });
  });

  group('malformed, placeholder, wrong-project and server-only values', () {
    test('malformed URLs', () {
      for (final url in <String>[
        'qqfzbecwhewswkyxgebu.supabase.co',
        'ftp://qqfzbecwhewswkyxgebu.supabase.co',
        'https://',
        '$_url/rest/v1',
        '$_url/auth/v1',
        '$_url?apikey=x',
        '$_url#fragment',
        'https://user:pass@qqfzbecwhewswkyxgebu.supabase.co',
        'not a url',
      ]) {
        expect(_issues(url, _publishable), [
          SupabaseConfigIssue.malformedUrl,
        ], reason: url);
      }
    });

    test('placeholders and non-key strings', () {
      for (final key in <String>[
        '<public anon/publishable key>',
        '<PUBLIC_PUBLISHABLE_KEY>',
        'ci-public-anon-key-for-build-only',
        'sb_publishable_',
        'anon-key',
        _jwt({'role': 'authenticated'}),
      ]) {
        expect(_issues(_url, key), [
          SupabaseConfigIssue.malformedKey,
        ], reason: SupabaseClientConfig.redactKey(key));
      }
    });

    test('secret and service-role keys are rejected in every mode', () {
      for (final strict in [true, false]) {
        expect(_issues(_url, 'sb_secret_TESTONLY_0000000000', strict: strict), [
          SupabaseConfigIssue.secretKey,
        ]);
        expect(_issues(_url, _jwt({'role': 'service_role'}), strict: strict), [
          SupabaseConfigIssue.secretKey,
        ]);
      }
    });

    test('a legacy key from another project', () {
      expect(
        _issues(_url, _jwt({'role': 'anon', 'ref': 'otherprojectref00000'})),
        [SupabaseConfigIssue.projectMismatch],
      );
    });

    test('test-injection mode skips only the key-format check', () {
      expect(_issues(_url, 'public-anon-key', strict: false), isEmpty);
      expect(_issues('', 'public-anon-key', strict: false), [
        SupabaseConfigIssue.missingUrl,
      ]);
    });
  });

  group('actionable, credential-free messages', () {
    test('name the define and the mobile rebuild steps', () {
      final message =
          SupabaseClientConfig.resolve(url: _url, anonKey: '').errorMessage;
      expect(
        message,
        startsWith('Supabase authentication is not configured for this build.'),
      );
      expect(message, contains('SUPABASE_ANON_KEY is empty'));
      expect(message, contains('--dart-define-from-file=supabase.local.json'));
      expect(message, contains('flutter build apk/appbundle/ipa/web'));
      expect(message, contains('hot restart'));
      expect(message, contains('Xcode or Gradle'));
    });

    test('never contain the key value', () {
      const marker = 'SENSITIVE0123456789abcdef';
      for (final key in <String>[
        'sb_publishable_$marker',
        'sb_secret_$marker',
        '<$marker>',
        _jwt({'role': 'service_role', 'marker': marker}),
      ]) {
        for (final url in [_url, '', 'https://bad/path?x']) {
          final config = SupabaseClientConfig.resolve(url: url, anonKey: key);
          final encoded = key.contains('.') ? key.split('.')[1] : marker;
          for (final text in [
            config.errorMessage,
            config.toString(),
            config.redactedKey,
            ...config.issueDescriptions,
          ]) {
            expect(text.contains(marker), isFalse);
            expect(text.contains(encoded), isFalse);
          }
        }
      }
    });
  });

  group('compile-time defines', () {
    // Run with and without --dart-define=SUPABASE_ANON_KEY=<fake key> to show
    // the value reaches the app only through the compile-time define.
    test('environment is validated once and reflects SUPABASE_ANON_KEY', () {
      final environment = SupabaseClientConfig.environment;
      expect(identical(environment, SupabaseClientConfig.environment), isTrue);
      expect(SupabaseConfig.isConfigured, environment.isValid);
      if (const bool.hasEnvironment('SUPABASE_ANON_KEY')) {
        expect(environment.isValid, isTrue, reason: environment.toString());
      } else {
        expect(SupabaseConfig.supabaseAnonKey, isEmpty);
        expect(environment.issues, contains(SupabaseConfigIssue.missingKey));
      }
    });

    test('select() returns the shared instance unless values are injected', () {
      final config = SupabaseClientConfig.resolve(
        url: _url,
        anonKey: _publishable,
      );
      expect(
        identical(SupabaseClientConfig.select(config: config), config),
        isTrue,
      );
      expect(
        identical(
          SupabaseClientConfig.select(),
          SupabaseClientConfig.environment,
        ),
        isTrue,
      );
    });
  });
}
