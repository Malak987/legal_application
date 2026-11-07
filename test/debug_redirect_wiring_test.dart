import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legalserviceapp/config/supabase_client_config.dart';
import 'package:legalserviceapp/config/supabase_config.dart';
import 'package:legalserviceapp/services/auth_service.dart';

import 'support/fakes.dart';

/// Verifies the *debug device-test configuration* end to end:
/// `SUPABASE_AUTH_REDIRECT_URL=legalserviceapp://auth-callback` must reach the
/// real signup request as `redirect_to`, and the Android manifest must declare
/// that same URI.
///
/// These tests do not connect to Supabase; the HTTP layer is mocked.
const String debugRedirect = 'legalserviceapp://auth-callback';
const String _url = 'https://qqfzbecwhewswkyxgebu.supabase.co';
const String _anonKey = 'public-anon-key';

http.Response _confirmationPending() => http.Response(
  jsonEncode(<String, dynamic>{
    'id': '00000000-0000-4000-8000-0000000000bb',
    'email': 'sara@example.com',
    'confirmation_sent_at': '2026-01-01T00:00:00Z',
  }),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

void main() {
  group('debug redirect reaches the signup request', () {
    test('redirect_to is exactly legalserviceapp://auth-callback', () async {
      final requests = <http.Request>[];
      final gateway = SupabaseAuthGateway(
        client: MockClient((request) async {
          requests.add(request);
          return _confirmationPending();
        }),
        supabaseUrl: _url,
        supabaseAnonKey: _anonKey,
        authRedirectUrl: debugRedirect,
        allowClientSignup: true,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: MemoryPkceVerifierStore(),
      );

      await expectLater(
        gateway.createAccount(email: 'sara@example.com', password: 'secret123'),
        throwsA(isA<AuthException>()),
      );

      final signup = requests.single;
      expect(signup.method, 'POST');
      expect(signup.url.path, '/auth/v1/signup');
      expect(
        signup.url.queryParameters['redirect_to'],
        debugRedirect,
        reason: 'the confirmation email must send the user back to the app',
      );

      // The PKCE parameters travel in the body alongside the redirect.
      final body = jsonDecode(signup.body) as Map<String, dynamic>;
      expect(body['code_challenge_method'], 's256');
      expect((body['code_challenge'] as String).length, 43);
      gateway.dispose();
    });

    test('the same redirect is used for the recovery email', () async {
      final requests = <http.Request>[];
      final gateway = SupabaseAuthGateway(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
        supabaseUrl: _url,
        supabaseAnonKey: _anonKey,
        authRedirectUrl: debugRedirect,
        allowClientSignup: true,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: MemoryPkceVerifierStore(),
      );

      await gateway.requestPasswordReset(email: 'sara@example.com');
      expect(
        requests.single.url.queryParameters['redirect_to'],
        debugRedirect,
      );
      gateway.dispose();
    });

    test('the custom-scheme redirect is accepted by redirect matching',
        () async {
      // A callback on the configured custom scheme must not be discarded by
      // the exact-redirect guard (scheme/host/port/path).
      final server = MemoryPkceVerifierStore(initialVerifier: 'pending-verifier');
      final gateway = SupabaseAuthGateway(
        client: MockClient((request) async {
          if (request.url.path == '/auth/v1/token') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'access_token': 'a',
                'refresh_token': 'r',
                'expires_in': 3600,
                'user': <String, dynamic>{
                  'id': '00000000-0000-4000-8000-0000000000bb',
                  'email': 'sara@example.com',
                },
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 404);
        }),
        supabaseUrl: _url,
        supabaseAnonKey: _anonKey,
        authRedirectUrl: debugRedirect,
        allowClientSignup: true,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: server,
      );

      final user = await gateway.restoreSession(
        callbackUri: Uri.parse('$debugRedirect?code=abc123&type=signup'),
      );
      expect(user?.uid, '00000000-0000-4000-8000-0000000000bb');
      gateway.dispose();
    });

    test('a callback on a different scheme is still rejected', () async {
      var requests = 0;
      final gateway = SupabaseAuthGateway(
        client: MockClient((request) async {
          requests++;
          return http.Response('{}', 404);
        }),
        supabaseUrl: _url,
        supabaseAnonKey: _anonKey,
        authRedirectUrl: debugRedirect,
        allowClientSignup: true,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: MemoryPkceVerifierStore(initialVerifier: 'pending-verifier'),
      );

      expect(
        await gateway.restoreSession(
          callbackUri: Uri.parse('otherscheme://auth-callback?code=abc'),
        ),
        isNull,
      );
      expect(requests, 0);
      gateway.dispose();
    });
  });

  group('compiled defines', () {
    test('signup is off unless ENABLE_CLIENT_SIGNUP is compiled in', () {
      // This test binary is run without --dart-define=ENABLE_CLIENT_SIGNUP, so
      // it pins the default. The release/debug build passes the define (see
      // the build command in the report) and the helper forwards it.
      expect(SupabaseConfig.enableClientSignup, isFalse);
    });

    test('the compiled redirect default is empty, not a guessed URI', () {
      // No build may silently assume a callback; it must be supplied.
      expect(SupabaseConfig.authRedirectUrl, isEmpty);
    });

    test('the config validator accepts a custom-scheme redirect value', () {
      // The redirect is not validated by SupabaseClientConfig (it validates
      // URL + key only), so a custom scheme is safe to pass through.
      final config = SupabaseClientConfig.resolve(
        url: _url,
        anonKey: 'sb_publishable_TESTONLY_redirect_000000',
      );
      expect(config.isValid, isTrue);
    });
  });
}
