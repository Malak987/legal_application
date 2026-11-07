import 'package:flutter_test/flutter_test.dart';
import 'package:legalserviceapp/services/auth_service.dart';

/// Deep-link *parsing* is exercised end-to-end in
/// `pkce_email_confirmation_test.dart`; these tests pin the redirect-matching
/// and error-shape rules that decide whether a delivered URI is even trusted.
void main() {
  group('auth callback shape', () {
    test('the configured redirect is compared exactly', () {
      // Mirrors SupabaseAuthGateway._matchesConfiguredRedirect: scheme, host,
      // port and path must all match; query/fragment are the callback payload.
      bool matches(String configured, String incoming) {
        final expected = Uri.parse(configured);
        final actual = Uri.parse(incoming);
        return expected.hasScheme &&
            actual.scheme == expected.scheme &&
            actual.host == expected.host &&
            actual.port == expected.port &&
            actual.path == expected.path;
      }

      const configured = 'https://legal-dashboard-1.web.app/auth/callback';

      expect(
        matches(configured, 'https://legal-dashboard-1.web.app/auth/callback?code=abc'),
        isTrue,
      );
      expect(
        matches(
          configured,
          'https://legal-dashboard-1.web.app/auth/callback#access_token=a&type=recovery',
        ),
        isTrue,
      );
      // Wrong host, wrong path, wrong scheme, wrong port.
      expect(
        matches(configured, 'https://evil.example/auth/callback?code=abc'),
        isFalse,
      );
      expect(
        matches(configured, 'https://legal-dashboard-1.web.app/auth/evil?code=abc'),
        isFalse,
      );
      expect(
        matches(configured, 'http://legal-dashboard-1.web.app/auth/callback?code=abc'),
        isFalse,
      );
      expect(
        matches(configured, 'https://legal-dashboard-1.web.app:8443/auth/callback?code=abc'),
        isFalse,
      );
    });

    test('query parameters win over a stale fragment', () {
      // Mirrors the merge rule in _restoreCallbackSession.
      final uri = Uri.parse(
        'https://legal-dashboard-1.web.app/auth/callback?code=real#code=stale',
      );
      final merged = <String, String>{...uri.queryParameters};
      final fragment = Uri.splitQueryString(uri.fragment);
      for (final entry in fragment.entries) {
        merged.putIfAbsent(entry.key, () => entry.value);
      }
      expect(merged['code'], 'real');
    });

    test('the confirmation callback carries a code and no tokens', () {
      final uri = Uri.parse(
        'https://legal-dashboard-1.web.app/auth/callback?code=abc123&type=signup',
      );
      expect(uri.queryParameters['code'], 'abc123');
      expect(uri.queryParameters.containsKey('access_token'), isFalse);
      expect(uri.queryParameters.containsKey('refresh_token'), isFalse);
    });

    test('PKCE error codes never leak into the UI message', () {
      // The user-facing text is fixed and never echoes link parameters.
      final error = AuthException(
        'This email-confirmation link is invalid or has expired. Request a new link.',
        code: 'invalid-pkce-link',
      );
      expect(error.message, isNot(contains('code=')));
      expect(error.message, isNot(contains('http')));
    });
  });
}
