import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legalserviceapp/app_bootstrap.dart';
import 'package:legalserviceapp/config/supabase_client_config.dart';
import 'package:legalserviceapp/services/auth_service.dart';
import 'package:legalserviceapp/state/session_controller.dart';

import 'support/fakes.dart';

/// Exercises the two real OS delivery paths for an auth callback:
///
/// * **cold start** — `AppLinks.getInitialLink()` → `main()` →
///   `bootstrapApp(initialCallbackUri:)` → `SessionController.start(...)`.
/// * **warm start** — `AppLinks.uriLinkStream` → `createSupabaseSession(...,
///   recoveryLinkStream:)` → `SessionController` subscription.
///
/// The streams are driven directly here; the platform channel is not faked,
/// which is why `app_links` itself is not under test — the *wiring* is.
const String _url = 'https://qqfzbecwhewswkyxgebu.supabase.co';
const String _publishable = 'sb_publishable_TESTONLY_not_a_real_key_0000';
const String _redirect = 'legalserviceapp://auth-callback';
const String _authUid = '00000000-0000-4000-8000-0000000000cc';
const String _email = 'sara@example.com';

SupabaseClientConfig _config() =>
    SupabaseClientConfig.resolve(url: _url, anonKey: _publishable);

/// A Supabase emulator covering signup, PKCE exchange and the profile row.
class _Project {
  final List<http.Request> requests = <http.Request>[];
  String? issuedChallenge;
  final Set<String> outstanding = <String>{};
  final Set<String> codes = <String>{};
  int pkceExchanges = 0;

  MockClient get client => MockClient((request) async {
    requests.add(request);
    final path = request.url.path;

    if (path == '/auth/v1/signup') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      issuedChallenge = body['code_challenge'] as String?;
      if (issuedChallenge != null) outstanding.add(issuedChallenge!);
      return http.Response(
        jsonEncode(<String, dynamic>{
          'id': _authUid,
          'email': _email,
          'confirmation_sent_at': '2026-01-01T00:00:00Z',
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }

    if (path == '/auth/v1/token') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final code = (body['auth_code'] ?? '').toString();
      final verifier = (body['code_verifier'] ?? '').toString();
      if (!codes.contains(code) || verifier.isEmpty) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'error': 'invalid_grant',
            'error_description': 'invalid flow state',
          }),
          400,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      // The verifier must hash to a challenge this server issued.
      final challenge = outstanding.firstWhere(
        (candidate) => candidate == _s256(verifier),
        orElse: () => '',
      );
      if (challenge.isEmpty) {
        return http.Response('{"error":"invalid_grant"}', 400,
            headers: <String, String>{'content-type': 'application/json'});
      }
      outstanding.remove(challenge);
      codes.remove(code);
      pkceExchanges++;
      return http.Response(
        jsonEncode(<String, dynamic>{
          'access_token': 'access-pkce',
          'refresh_token': 'refresh-pkce',
          'expires_in': 3600,
          'user': <String, dynamic>{'id': _authUid, 'email': _email},
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }

    if (path == '/rest/v1/users') {
      return http.Response(
        jsonEncode(<Map<String, dynamic>>[
          profileJson(id: _authUid, email: _email),
        ]),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }

    return http.Response('{}', 404);
  });
}

String _s256(String verifier) {
  // Reimplemented via the gateway's own helper to keep this file dependency-free.
  return SupabaseAuthGateway.debugDerivePkceChallenge(verifier);
}

Uri callbackFor(String code) => Uri.parse('$_redirect?code=$code&type=signup');

Future<void> settle() => Future<void>.delayed(
  const Duration(milliseconds: 50),
);

void main() {
  group('cold start: getInitialLink -> bootstrapApp', () {
    test('a launch URI installs the session before the UI resolves', () async {
      final project = _Project();
      final pkce = MemoryPkceVerifierStore();
      final deepLinks = StreamController<Uri>.broadcast();

      // 1. The user registered earlier; a confirmation is pending.
      final session = createSupabaseSession(
        _config(),
        httpClient: project.client,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: pkce,
        recoveryLinkStream: deepLinks.stream,
        authRedirectUrl: _redirect,
        allowClientSignup: true,
      );
      expect(
        await session.register(
          name: 'Sara',
          email: _email,
          password: 'secret123',
        ),
        isFalse,
      );
      expect(session.registrationErrorCode, 'email-confirmation-required');

      // 2. The app is killed; Android relaunches it from the link.
      //    The Supabase project is the same server — only the app process
      //    restarts, carrying only what survived in secure storage.
      project.codes.add('code-cold');
      final relaunched = createSupabaseSession(
        _config(),
        httpClient: project.client,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: pkce,
        recoveryLinkStream: const Stream<Uri>.empty(),
        authRedirectUrl: _redirect,
        allowClientSignup: true,
      );

      // 3. main() hands getInitialLink()'s URI to bootstrapApp, which starts
      //    the session immediately.
      bootstrapApp(
        config: _config(),
        initialCallbackUri: callbackFor('code-cold'),
        createSession: (_) => relaunched,
        buildApp: (controller) => const MaterialApp(home: SizedBox()),
      );

      await settle();
      await settle();

      expect(
        relaunched.status,
        SessionStatus.signedIn,
        reason: relaunched.error ?? 'cold-start callback must sign the user in',
      );
      expect(relaunched.profile?.uid, _authUid);
      expect(project.pkceExchanges, 1);
      expect(
        project.requests
            .firstWhere((r) => r.url.path == '/auth/v1/token')
            .url
            .queryParameters['grant_type'],
        'pkce',
      );
      session.dispose();
      relaunched.dispose();
      await deepLinks.close();
    });

    test('no launch URI leaves the user signed out', () async {
      final project = _Project();
      final session = createSupabaseSession(
        _config(),
        httpClient: project.client,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: MemoryPkceVerifierStore(),
        authRedirectUrl: _redirect,
        allowClientSignup: true,
      );
      bootstrapApp(
        config: _config(),
        createSession: (_) => session,
        buildApp: (controller) => const MaterialApp(home: SizedBox()),
      );
      await settle();

      expect(session.status, SessionStatus.signedOut);
      expect(project.requests, isEmpty);
      session.dispose();
    });
  });

  group('warm start: uriLinkStream while the app is running', () {
    test('a link delivered mid-session signs the user in', () async {
      final project = _Project();
      final pkce = MemoryPkceVerifierStore();
      final deepLinks = StreamController<Uri>.broadcast();

      final session = createSupabaseSession(
        _config(),
        httpClient: project.client,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: pkce,
        recoveryLinkStream: deepLinks.stream,
        authRedirectUrl: _redirect,
        allowClientSignup: true,
      );
      session.start();
      await settle();
      expect(session.status, SessionStatus.signedOut);

      // Register, then receive the link without restarting the app.
      await session.register(
        name: 'Sara',
        email: _email,
        password: 'secret123',
      );
      project.codes.add('code-warm');
      deepLinks.add(callbackFor('code-warm'));
      await settle();

      expect(
        session.status,
        SessionStatus.signedIn,
        reason: session.error ?? 'warm-start callback must sign the user in',
      );
      expect(project.pkceExchanges, 1);
      session.dispose();
      await deepLinks.close();
    });

    test('a duplicate warm-start delivery does not re-exchange', () async {
      final project = _Project();
      final pkce = MemoryPkceVerifierStore();
      final deepLinks = StreamController<Uri>.broadcast();

      final session = createSupabaseSession(
        _config(),
        httpClient: project.client,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: pkce,
        recoveryLinkStream: deepLinks.stream,
        authRedirectUrl: _redirect,
        allowClientSignup: true,
      );
      session.start();
      await settle();
      await session.register(
        name: 'Sara',
        email: _email,
        password: 'secret123',
      );

      project.codes.add('code-twice');
      deepLinks.add(callbackFor('code-twice'));
      await settle();
      await settle();
      final exchangesAfterFirst = project.pkceExchanges;

      deepLinks.add(callbackFor('code-twice'));
      await settle();
      await settle();

      expect(project.pkceExchanges, exchangesAfterFirst);
      expect(exchangesAfterFirst, 1);
      expect(session.status, SessionStatus.signedIn);
      session.dispose();
      await deepLinks.close();
    });

    test('a link that arrives with no pending flow is rejected safely',
        () async {
      final project = _Project();
      final deepLinks = StreamController<Uri>.broadcast();
      final session = createSupabaseSession(
        _config(),
        httpClient: project.client,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: MemoryPkceVerifierStore(),
        recoveryLinkStream: deepLinks.stream,
        authRedirectUrl: _redirect,
        allowClientSignup: true,
      );
      session.start();
      await settle();

      deepLinks.add(callbackFor('code-orphan'));
      await settle();

      expect(project.pkceExchanges, 0);
      expect(session.status, SessionStatus.signedOut);
      expect(session.isPasswordRecoveryFlow, isFalse);
      session.dispose();
      await deepLinks.close();
    });
  });

  group('buildApp is never reached with an invalid config', () {
    testWidgets('invalid Supabase config shows the configuration screen',
        (tester) async {
      final invalid = SupabaseClientConfig.resolve(url: '', anonKey: '');
      var built = false;
      final widget = bootstrapApp(
        config: invalid,
        buildApp: (controller) {
          built = true;
          return const MaterialApp(home: SizedBox());
        },
      );
      await tester.pumpWidget(widget);
      expect(built, isFalse);
      expect(find.textContaining('Supabase'), findsWidgets);
    });
  });
}
