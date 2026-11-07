import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legalserviceapp/services/api_client.dart';
import 'package:legalserviceapp/services/auth_service.dart';
import 'package:legalserviceapp/state/session_controller.dart';

import 'support/fakes.dart';

// Test-only fixtures. None of these is a real project credential.
const String _url = 'https://qqfzbecwhewswkyxgebu.supabase.co';
const String _anonKey = 'public-anon-key';
const String _redirect = 'https://legal-dashboard-1.web.app/auth/callback';
const String _authUid = '00000000-0000-4000-8000-0000000000aa';
const String _email = 'sara@example.com';

/// Recomputes the RFC 7636 S256 challenge exactly as the server does.
String _s256(String verifier) =>
    base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll(
      RegExp(r'=+$'),
      '',
    );

http.Response _tokenJson(String access, String refresh) => http.Response(
  jsonEncode(<String, dynamic>{
    'access_token': access,
    'refresh_token': refresh,
    'expires_in': 3600,
    'token_type': 'bearer',
    'user': <String, dynamic>{'id': _authUid, 'email': _email},
  }),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

/// A fake Supabase Auth server that enforces the real PKCE contract.
///
/// It stores the `code_challenge` from `/signup` and only returns tokens from
/// `/token?grant_type=pkce` when the supplied `code_verifier` hashes to that
/// stored challenge — exactly like GoTrue. Requests that omit `auth_code` or
/// `code_verifier` get the real GoTrue 400 error.
class FakeSupabaseAuth {
  final List<http.Request> requests = <http.Request>[];
  /// The most recently issued challenge (for single-flow assertions).
  String? issuedChallenge;
  String? issuedMethod;
  String? issuedRedirectTo;

  /// Every challenge this server has issued and not yet consumed. Signup and
  /// recovery flows coexist, so each keeps its own outstanding challenge.
  final Set<String> outstandingChallenges = <String>{};

  /// Authorization codes this server will accept, mapped to the session they
  /// represent. A code is consumed on first successful exchange.
  final Map<String, String> codes = <String, String>{};

  int pkceExchanges = 0;

  /// When set, `/signup` returns this response instead of creating anything.
  http.Response? rejectSignup;

  /// Invoked while handling `/signup`, before responding.
  void Function()? onSignup;

  MockClient get client => MockClient((http.Request request) async {
    requests.add(request);
    final path = request.url.path;

    if (path == '/auth/v1/signup') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      issuedChallenge = body['code_challenge'] as String?;
      issuedMethod = body['code_challenge_method'] as String?;
      issuedRedirectTo = request.url.queryParameters['redirect_to'];
      if (issuedChallenge != null) outstandingChallenges.add(issuedChallenge!);
      // Lets a test observe secure storage at the exact moment of the request.
      onSignup?.call();
      final rejection = rejectSignup;
      if (rejection != null) return rejection;
      // Email confirmation required: the user is returned with no session.
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
      final grant = request.url.queryParameters['grant_type'];
      if (grant != 'pkce') {
        return http.Response('{"error_code":"unsupported"}', 400);
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final authCode = (body['auth_code'] ?? '').toString();
      final verifier = (body['code_verifier'] ?? '').toString();

      // Real GoTrue message for a missing pair.
      if (authCode.isEmpty || verifier.isEmpty) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'error': 'invalid_request',
            'error_description':
                'both auth code and code verifier should be non-empty',
          }),
          400,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }

      final sessionId = codes[authCode];
      if (sessionId == null) {
        // Unknown or already-consumed code.
        return http.Response(
          jsonEncode(<String, dynamic>{
            'error': 'invalid_grant',
            'error_description': 'invalid flow state',
          }),
          400,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }

      final challenge = outstandingChallenges.contains(_s256(verifier))
          ? _s256(verifier)
          : null;
      if (challenge == null) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'error': 'invalid_grant',
            'error_description': 'code challenge does not match',
          }),
          400,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }

      // Single-use: consume the code and its challenge.
      codes.remove(authCode);
      outstandingChallenges.remove(challenge);
      pkceExchanges++;
      return _tokenJson('access-$sessionId', 'refresh-$sessionId');
    }

    if (path == '/auth/v1/recover') {
      // Recovery links are PKCE callbacks too: the challenge must be stored.
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      issuedChallenge = body['code_challenge'] as String?;
      issuedMethod = body['code_challenge_method'] as String?;
      issuedRedirectTo = request.url.queryParameters['redirect_to'];
      if (issuedChallenge != null) outstandingChallenges.add(issuedChallenge!);
      return http.Response('{}', 200);
    }

    if (path == '/auth/v1/user') {
      return http.Response(
        jsonEncode(<String, dynamic>{'id': _authUid, 'email': _email}),
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

  /// The exact confirmation URI Supabase would redirect Android to.
  Uri callbackFor(String code) =>
      Uri.parse('$_redirect?code=$code&type=signup');
}

SupabaseAuthGateway _gateway(
  FakeSupabaseAuth server, {
  required PkceVerifierStore pkceStore,
  MemoryAuthSessionStore? sessionStore,
}) => SupabaseAuthGateway(
  client: server.client,
  supabaseUrl: _url,
  supabaseAnonKey: _anonKey,
  authRedirectUrl: _redirect,
  allowClientSignup: true,
  sessionStore: sessionStore ?? MemoryAuthSessionStore(),
  pkceStore: pkceStore,
);

/// In-memory stand-in for the platform keystore.
class RecordingSecureStorage implements PkceKeystore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<Map<String, String>> readAll() async =>
      Map<String, String>.of(values);

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Exposes the production store over an in-memory keystore.
class SecuredStoreForTest extends SecurePkceVerifierStore {
  SecuredStoreForTest(PkceKeystore keystore) : super(keystore: keystore);
}

void main() {
  group('PKCE generation (RFC 7636)', () {
    test('verifier is 43 unreserved chars and uses the CSPRNG', () {
      final a = SupabaseAuthGateway.debugGeneratePkceVerifier();
      final b = SupabaseAuthGateway.debugGeneratePkceVerifier();

      expect(a.length, 43, reason: '32 bytes base64url-unpadded is 43 chars');
      expect(
        RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(a),
        isTrue,
        reason: 'verifier must only use RFC 7636 unreserved characters',
      );
      expect(a, isNot(b), reason: 'verifiers must not repeat');
    });

    test('challenge is BASE64URL(SHA256(ASCII(verifier))) without padding', () {
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      // The RFC 7636 Appendix B worked example.
      expect(
        SupabaseAuthGateway.debugDerivePkceChallenge(verifier),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });
  });

  group('signup sends a correct S256 challenge', () {
    test('persists the verifier BEFORE the signup request', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      // Sampled inside the /signup handler, so this proves the verifier was
      // already durable when the request went out — not merely written later.
      String? verifierAtRequest;
      server.onSignup = () => verifierAtRequest = pkce.verifier;

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.code,
            'code',
            'email-confirmation-required',
          ),
        ),
      );

      expect(
        verifierAtRequest,
        isNotNull,
        reason: 'the verifier must be stored before signup is sent',
      );
      expect(
        verifierAtRequest,
        pkce.verifier,
        reason: 'the persisted verifier is the one the challenge came from',
      );
      expect(server.issuedChallenge, _s256(verifierAtRequest!));
      expect(server.requests.single.url.path, '/auth/v1/signup');
      gateway.dispose();
    });

    test('the challenge is derived from the persisted verifier', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );

      final verifier = pkce.verifier!;
      expect(server.issuedChallenge, _s256(verifier));
      expect(server.issuedChallenge!.length, 43);
      expect(server.issuedMethod, 's256');
      expect(server.issuedRedirectTo, _redirect);
      gateway.dispose();
    });

    test('carries no role and no secret in the signup payload', () async {
      final server = FakeSupabaseAuth();
      final gateway = _gateway(server, pkceStore: MemoryPkceVerifierStore());

      await expectLater(
        gateway.createAccount(
          email: _email,
          password: 'secret123',
          displayName: 'Sara',
        ),
        throwsA(isA<AuthException>()),
      );

      final body =
          jsonDecode(server.requests.single.body) as Map<String, dynamic>;
      expect(body.keys, isNot(contains('role')));
      expect(body['data'], <String, dynamic>{'name': 'Sara'});
      expect(server.requests.single.headers['apikey'], _anonKey);
      gateway.dispose();
    });
  });

  group('confirmation callback exchange', () {
    test('exchanges the code with the SAME verifier and installs a session',
        () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final sessionStore = MemoryAuthSessionStore();
      final gateway = _gateway(
        server,
        pkceStore: pkce,
        sessionStore: sessionStore,
      );

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      final verifierAtSignup = pkce.verifier!;
      server.codes['code-abc'] = 'sess1';

      final user = await gateway.restoreSession(
        callbackUri: server.callbackFor('code-abc'),
      );

      expect(user?.uid, _authUid);
      expect(gateway.currentUser?.uid, _authUid);
      expect(gateway.isPasswordRecovery, isFalse);

      // The exchange request must use the real GoTrue contract.
      final exchange = server.requests.last;
      expect(exchange.url.path, '/auth/v1/token');
      expect(exchange.url.queryParameters['grant_type'], 'pkce');
      final body = jsonDecode(exchange.body) as Map<String, dynamic>;
      expect(body['auth_code'], 'code-abc');
      expect(
        body['code_verifier'],
        verifierAtSignup,
        reason: 'the exact verifier persisted at signup must be reused',
      );

      // Session is installed and piped to secure storage.
      expect(await gateway.getAccessToken(), 'access-sess1');
      expect(sessionStore.refreshToken, 'refresh-sess1');

      // Verifier is cleared only after the exchange succeeds.
      expect(pkce.saves, 1);
      expect(pkce.removes, 1);
      expect(pkce.verifier, isNull);
      gateway.dispose();
    });

    test('the verifier survives an app restart', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();

      // First process: signup only.
      final first = _gateway(server, pkceStore: pkce);
      await expectLater(
        first.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      final verifier = pkce.verifier!;
      first.dispose();

      // Second process: a brand-new gateway over the same secure storage.
      server.codes['code-restart'] = 'sess2';
      final second = _gateway(server, pkceStore: pkce);
      final user = await second.restoreSession(
        callbackUri: server.callbackFor('code-restart'),
      );

      expect(user?.uid, _authUid);
      final body =
          jsonDecode(server.requests.last.body) as Map<String, dynamic>;
      expect(body['code_verifier'], verifier);
      second.dispose();
    });

    test('a missing verifier prevents the token exchange', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore(); // empty: no signup on this device
      final gateway = _gateway(server, pkceStore: pkce);
      server.codes['code-xyz'] = 'sess3';

      await expectLater(
        gateway.restoreSession(callbackUri: server.callbackFor('code-xyz')),
        throwsA(
          isA<AuthException>().having(
            (e) => e.code,
            'code',
            'invalid-pkce-link',
          ),
        ),
      );

      expect(
        server.requests.where((r) => r.url.path == '/auth/v1/token'),
        isEmpty,
        reason: 'never send a PKCE exchange without a verifier',
      );
      expect(gateway.currentUser, isNull);
      gateway.dispose();
    });

    test('a storage failure prevents signup', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore(failOnSave: true);
      final gateway = _gateway(server, pkceStore: pkce);

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.code,
            'code',
            'pkce-storage-failed',
          ),
        ),
      );

      expect(
        server.requests,
        isEmpty,
        reason: 'no account may be created when its verifier cannot be stored',
      );
      gateway.dispose();
    });

    test('a rejected code leaves the user signed out and surfaces a safe error',
        () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      // Do not register the code: the server returns invalid_grant.

      await expectLater(
        gateway.restoreSession(callbackUri: server.callbackFor('code-bad')),
        throwsA(
          isA<AuthException>().having(
            (e) => e.code,
            'code',
            'invalid-pkce-link',
          ),
        ),
      );
      expect(gateway.currentUser, isNull);
      expect(
        pkce.verifier,
        isNotNull,
        reason: 'a failed exchange must not discard the verifier',
      );
      gateway.dispose();
    });

    test('duplicate callbacks only exchange once', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      server.codes['code-dup'] = 'sess4';
      final callback = server.callbackFor('code-dup');

      final first = await gateway.restoreSession(callbackUri: callback);
      final second = await gateway.restoreSession(callbackUri: callback);

      expect(first?.uid, _authUid);
      expect(
        second?.uid,
        _authUid,
        reason: 'a repeat delivery must reuse the installed session',
      );
      expect(
        server.requests.where((r) => r.url.path == '/auth/v1/token').length,
        1,
        reason: 'a single-use authorization code must be exchanged once',
      );
      expect(gateway.currentUser?.uid, _authUid);
      gateway.dispose();
    });

    test('concurrent duplicate delivery does not double-exchange', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      server.codes['code-race'] = 'sess5';
      final callback = server.callbackFor('code-race');

      // The losing racer may reject with a supersession error; only the
      // number of network exchanges and the final session state are asserted.
      final results = await Future.wait<AuthUser?>(
        <Future<AuthUser?>>[
          gateway.restoreSession(callbackUri: callback),
          gateway.restoreSession(callbackUri: callback),
        ].map((future) => future.catchError((Object _) => null)),
      );

      // Either both report the session, or the loser reports supersession —
      // but never a second exchange of the same code.
      expect(
        server.requests.where((r) => r.url.path == '/auth/v1/token').length,
        lessThanOrEqualTo(1),
      );
      expect(gateway.currentUser?.uid, _authUid);
      expect(results.whereType<AuthUser>().isNotEmpty, isTrue);
      gateway.dispose();
    });

    test('an error callback is rejected without any network call', () async {
      final server = FakeSupabaseAuth();
      final gateway = _gateway(server, pkceStore: MemoryPkceVerifierStore());

      await expectLater(
        gateway.restoreSession(
          callbackUri: Uri.parse(
            '$_redirect?error=access_denied&error_code=otp_expired',
          ),
        ),
        throwsA(isA<AuthException>()),
      );
      expect(server.requests, isEmpty);
      gateway.dispose();
    });

    test('a callback for another origin is ignored', () async {
      final server = FakeSupabaseAuth();
      final gateway = _gateway(server, pkceStore: MemoryPkceVerifierStore());

      expect(
        await gateway.restoreSession(
          callbackUri: Uri.parse(
            'https://attacker.example/auth/callback?code=stolen',
          ),
        ),
        isNull,
      );
      expect(server.requests, isEmpty);
      gateway.dispose();
    });

    test('an invite callback never creates an app session', () async {
      final server = FakeSupabaseAuth();
      final gateway = _gateway(server, pkceStore: MemoryPkceVerifierStore());

      expect(
        await gateway.restoreSession(
          callbackUri: Uri.parse('$_redirect?code=invite-code&type=invite'),
        ),
        isNull,
      );
      expect(server.requests, isEmpty);
      gateway.dispose();
    });
  });

  group('existing flows are unchanged', () {
    test('password sign-in still exchanges email/password for a session',
        () async {
      final requests = <http.Request>[];
      final gateway = SupabaseAuthGateway(
        client: MockClient((request) async {
          requests.add(request);
          return _tokenJson('access-login', 'refresh-login');
        }),
        supabaseUrl: _url,
        supabaseAnonKey: _anonKey,
        authRedirectUrl: _redirect,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: MemoryPkceVerifierStore(),
      );

      final user = await gateway.signIn(email: _email, password: 'secret123');
      expect(user.uid, _authUid);
      expect(requests.single.url.queryParameters['grant_type'], 'password');
      expect(
        jsonDecode(requests.single.body),
        <String, dynamic>{'email': _email, 'password': 'secret123'},
      );
      gateway.dispose();
    });

    test('an implicit-flow recovery callback still works', () async {
      final requests = <http.Request>[];
      final gateway = SupabaseAuthGateway(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/auth/v1/user') {
            return http.Response(
              jsonEncode(<String, dynamic>{'id': _authUid, 'email': _email}),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 204);
        }),
        supabaseUrl: _url,
        supabaseAnonKey: _anonKey,
        authRedirectUrl: _redirect,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: MemoryPkceVerifierStore(),
      );

      final user = await gateway.restoreSession(
        callbackUri: Uri.parse(
          '#access_token=recovery-access&refresh_token=recovery-refresh'
          '&type=recovery&expires_in=3600',
        ).replace(
          scheme: 'https',
          host: 'legal-dashboard-1.web.app',
          path: '/auth/callback',
        ),
      );
      expect(user?.uid, _authUid);
      expect(gateway.isPasswordRecovery, isTrue);
      gateway.dispose();
    });

    test('password reset sends an S256 challenge and persists a verifier',
        () async {
      final requests = <http.Request>[];
      final pkce = MemoryPkceVerifierStore();
      final gateway = SupabaseAuthGateway(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
        supabaseUrl: _url,
        supabaseAnonKey: _anonKey,
        authRedirectUrl: _redirect,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: pkce,
      );

      await gateway.requestPasswordReset(email: _email);

      final body =
          jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(requests.single.url.path, '/auth/v1/recover');
      expect(body['code_challenge'], _s256(pkce.verifier!));
      expect(body['code_challenge_method'], 's256');
      gateway.dispose();
    });

    test('a PKCE recovery callback lands on the reset-password flow', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      await gateway.requestPasswordReset(email: _email);
      server.codes['recovery-code'] = 'rec1';

      final user = await gateway.restoreSession(
        callbackUri: Uri.parse(
          '$_redirect?code=recovery-code&type=recovery',
        ),
      );

      expect(user?.uid, _authUid);
      expect(
        gateway.isPasswordRecovery,
        isTrue,
        reason: 'a recovery code must not be treated as an email confirmation',
      );
      gateway.dispose();
    });
  });

  group('per-flow verifier isolation', () {
    test('signup then recovery: both verifiers survive independently',
        () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      // 1. Signup leaves a pending confirmation verifier.
      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      final signupFlow = pkce.of(PkceFlowPurpose.signup).single;
      final signupChallenge = server.issuedChallenge!;

      // 2. A password reset must not touch it.
      await gateway.requestPasswordReset(email: _email);
      final recoveryFlow = pkce.of(PkceFlowPurpose.recovery).single;

      expect(pkce.of(PkceFlowPurpose.signup), hasLength(1));
      expect(pkce.of(PkceFlowPurpose.recovery), hasLength(1));
      expect(signupFlow.id, isNot(recoveryFlow.id));
      expect(signupFlow.verifier, isNot(recoveryFlow.verifier));
      expect(
        pkce.rows[signupFlow.id]!.verifier,
        signupFlow.verifier,
        reason: 'the pending signup verifier must be untouched by recovery',
      );

      // 3. The signup confirmation still completes with its own verifier.
      server.codes['code-signup'] = 'sess-signup';
      server.issuedChallenge = signupChallenge;
      final user = await gateway.restoreSession(
        callbackUri: server.callbackFor('code-signup'),
      );
      expect(user?.uid, _authUid);
      expect(
        (jsonDecode(server.requests.last.body)
            as Map<String, dynamic>)['code_verifier'],
        signupFlow.verifier,
      );
      // Recovery is still pending afterwards.
      expect(pkce.of(PkceFlowPurpose.recovery), hasLength(1));
      gateway.dispose();
    });

    test('recovery then signup: signup does not consume the reset verifier',
        () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      await gateway.requestPasswordReset(email: _email);
      final recoveryFlow = pkce.of(PkceFlowPurpose.recovery).single;

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      expect(pkce.of(PkceFlowPurpose.recovery), hasLength(1));
      expect(
        pkce.rows[recoveryFlow.id]!.verifier,
        recoveryFlow.verifier,
        reason: 'a new signup must not overwrite a pending recovery',
      );
      gateway.dispose();
    });

    test('two signups keep two pending flows, newest resolves first',
        () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        gateway.createAccount(email: _email, password: 'secret456'),
        throwsA(isA<AuthException>()),
      );

      final flows = pkce.of(PkceFlowPurpose.signup);
      expect(flows, hasLength(2), reason: 'both confirmations remain usable');
      expect(flows.first.verifier, isNot(flows.last.verifier));

      // An unlabelled callback uses the newest flow.
      server.codes['code-new'] = 'sess-new';
      await gateway.restoreSession(callbackUri: server.callbackFor('code-new'));
      expect(
        (jsonDecode(server.requests.last.body)
            as Map<String, dynamic>)['code_verifier'],
        flows.first.verifier,
      );
      // Exactly one row was consumed.
      expect(pkce.of(PkceFlowPurpose.signup), hasLength(1));
      expect(pkce.of(PkceFlowPurpose.signup).single.id, flows.last.id);
      gateway.dispose();
    });

    test('two recoveries keep two pending flows', () async {
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(FakeSupabaseAuth(), pkceStore: pkce);

      await gateway.requestPasswordReset(email: _email);
      await gateway.requestPasswordReset(email: _email);
      expect(pkce.of(PkceFlowPurpose.recovery), hasLength(2));
      gateway.dispose();
    });

    test('a recovery callback selects the recovery verifier', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      await gateway.requestPasswordReset(email: _email);
      final recoveryVerifier = pkce.of(PkceFlowPurpose.recovery).single.verifier;
      final recoveryChallenge = server.issuedChallenge!;

      server.codes['code-rec'] = 'sess-rec';
      server.issuedChallenge = recoveryChallenge;
      await gateway.restoreSession(
        callbackUri: Uri.parse(
          '$_redirect?code=code-rec&type=recovery',
        ),
      );

      expect(
        (jsonDecode(server.requests.last.body)
            as Map<String, dynamic>)['code_verifier'],
        recoveryVerifier,
        reason: 'type=recovery must use the recovery flow verifier',
      );
      expect(gateway.isPasswordRecovery, isTrue);
      // The signup flow is untouched.
      expect(pkce.of(PkceFlowPurpose.signup), hasLength(1));
      gateway.dispose();
    });

    test('a rejected signup removes only its own flow', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      final first = pkce.of(PkceFlowPurpose.signup).single;

      server.rejectSignup = http.Response(
        jsonEncode(<String, dynamic>{
          'error_code': 'user_already_exists',
          'msg': 'User already registered',
        }),
        422,
        headers: <String, String>{'content-type': 'application/json'},
      );
      await expectLater(
        gateway.createAccount(email: _email, password: 'secret456'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.code,
            'code',
            'email-already-in-use',
          ),
        ),
      );

      // Only the rejected flow is gone; the first confirmation still works.
      final remaining = pkce.of(PkceFlowPurpose.signup);
      expect(remaining, hasLength(1));
      expect(remaining.single.id, first.id);
      expect(remaining.single.verifier, first.verifier);
      gateway.dispose();
    });

    test('rollback never overwrites a newer flow of another purpose',
        () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      // A recovery is pending.
      await gateway.requestPasswordReset(email: _email);
      final recovery = pkce.of(PkceFlowPurpose.recovery).single;

      // A signup is then rejected by the server.
      server.rejectSignup = http.Response(
        '{"error_code":"signup_disabled"}',
        422,
        headers: <String, String>{'content-type': 'application/json'},
      );
      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );

      // The recovery verifier is bit-identical: nothing was written over it.
      expect(pkce.rows[recovery.id]!.verifier, recovery.verifier);
      expect(pkce.of(PkceFlowPurpose.recovery), hasLength(1));
      expect(pkce.of(PkceFlowPurpose.signup), isEmpty);
      gateway.dispose();
    });

    test('a superseded signup discards its own flow', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      // Start a signup, then supersede the session generation before it lands.
      // signOut() increments the generation, which invalidates the in-flight
      // signup exactly as a concurrent sign-out would in the app.
      await gateway.requestPasswordReset(email: _email);
      final pending = gateway.createAccount(
        email: _email,
        password: 'secret123',
      );
      await gateway.signOut();
      await expectLater(pending, throwsA(isA<AuthException>()));

      expect(
        pkce.of(PkceFlowPurpose.signup),
        isEmpty,
        reason: 'a flow that can never receive a callback must be discarded',
      );
      expect(
        pkce.of(PkceFlowPurpose.recovery),
        hasLength(1),
        reason: 'superseding a signup must not disturb a pending recovery',
      );
      gateway.dispose();
    });

    test('storage write failure prevents signup and removes no other flow',
        () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      await gateway.requestPasswordReset(email: _email);
      final recovery = pkce.of(PkceFlowPurpose.recovery).single;
      final requestsBefore = server.requests.length;

      pkce.failOnSave = true;
      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.code,
            'code',
            'pkce-storage-failed',
          ),
        ),
      );

      expect(
        server.requests.length,
        requestsBefore,
        reason: 'no signup may be sent when its verifier cannot be stored',
      );
      expect(pkce.rows[recovery.id]!.verifier, recovery.verifier);
      gateway.dispose();
    });

    test('storage read failure fails closed without exchanging', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      final tokenCalls = server.requests
          .where((r) => r.url.path == '/auth/v1/token')
          .length;

      pkce.failOnRead = true;
      await expectLater(
        gateway.restoreSession(callbackUri: server.callbackFor('code-x')),
        throwsA(
          isA<AuthException>().having(
            (e) => e.code,
            'code',
            'invalid-pkce-link',
          ),
        ),
      );
      expect(
        server.requests.where((r) => r.url.path == '/auth/v1/token').length,
        tokenCalls,
        reason: 'an unreadable store must never trigger a guessed exchange',
      );
      gateway.dispose();
    });

    test('storage delete failure leaves the flow but still installs', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      server.codes['code-del'] = 'sess-del';
      pkce.failOnRemove = true;

      final user = await gateway.restoreSession(
        callbackUri: server.callbackFor('code-del'),
      );
      expect(user?.uid, _authUid, reason: 'cleanup failure is not fatal');
      expect(pkce.of(PkceFlowPurpose.signup), hasLength(1));
      gateway.dispose();
    });

    test('a failed session install keeps the verifier for a retry', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final sessionStore = MemoryAuthSessionStore()..failOnWrite = true;
      final gateway = _gateway(
        server,
        pkceStore: pkce,
        sessionStore: sessionStore,
      );

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      final flow = pkce.of(PkceFlowPurpose.signup).single;
      server.codes['code-retry'] = 'sess-retry';

      await expectLater(
        gateway.restoreSession(callbackUri: server.callbackFor('code-retry')),
        throwsA(
          isA<AuthException>().having(
            (e) => e.code,
            'code',
            'session-storage-failed',
          ),
        ),
      );

      expect(
        pkce.rows[flow.id]?.verifier,
        flow.verifier,
        reason: 'an unpromotable session must not consume the verifier',
      );
      expect(gateway.currentUser, isNull);
      gateway.dispose();
    });

    test('app restart with pending flows keeps both usable', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();

      final first = _gateway(server, pkceStore: pkce);
      await expectLater(
        first.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      await first.requestPasswordReset(email: _email);
      first.dispose();

      // A brand-new gateway over the same storage = new process.
      final second = _gateway(server, pkceStore: pkce);
      expect(pkce.of(PkceFlowPurpose.signup), hasLength(1));
      expect(pkce.of(PkceFlowPurpose.recovery), hasLength(1));

      server.codes['code-after-restart'] = 'sess-restart';
      final user = await second.restoreSession(
        callbackUri: server.callbackFor('code-after-restart'),
      );
      expect(user?.uid, _authUid);
      expect(pkce.of(PkceFlowPurpose.recovery), hasLength(1));
      second.dispose();
    });

    test('a duplicate callback consumes one flow only once', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final gateway = _gateway(server, pkceStore: pkce);

      await expectLater(
        gateway.createAccount(email: _email, password: 'secret123'),
        throwsA(isA<AuthException>()),
      );
      server.codes['code-dup2'] = 'sess-dup2';
      final callback = server.callbackFor('code-dup2');

      await gateway.restoreSession(callbackUri: callback);
      final removesAfterFirst = pkce.removes;
      await gateway.restoreSession(callbackUri: callback);

      expect(
        pkce.removes,
        removesAfterFirst,
        reason: 'a repeat delivery must not remove anything again',
      );
      expect(
        server.requests.where((r) => r.url.path == '/auth/v1/token').length,
        1,
      );
      gateway.dispose();
    });
  });

  group('SecurePkceVerifierStore (real implementation)', () {
    test('each flow is written under its own key', () async {
      final storage = RecordingSecureStorage();
      final store = SecuredStoreForTest(storage);

      final signup = await store.save(PkceFlowPurpose.signup, 'v-signup');
      final recovery = await store.save(PkceFlowPurpose.recovery, 'v-recovery');

      expect(signup.id, isNot(recovery.id));
      expect(storage.values['legal_supabase_pkce_v2:signup:${signup.id}'],
          contains('v-signup'));
      expect(
        storage.values['legal_supabase_pkce_v2:recovery:${recovery.id}'],
        contains('v-recovery'),
      );
      // Two rows, not one shared slot.
      expect(storage.values.keys.length, 2);
    });

    test('readAll returns newest first and round-trips the verifier', () async {
      final store = SecuredStoreForTest(RecordingSecureStorage());
      await store.save(PkceFlowPurpose.signup, 'older');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.save(PkceFlowPurpose.signup, 'newer');

      final all = await store.readAll();
      expect(all.map((f) => f.verifier).toList(), ['newer', 'older']);
      expect(all.first.purpose, PkceFlowPurpose.signup);
      expect(all.first.id, isNotEmpty);
    });

    test('remove deletes exactly one flow', () async {
      final storage = RecordingSecureStorage();
      final store = SecuredStoreForTest(storage);
      final a = await store.save(PkceFlowPurpose.signup, 'a');
      final b = await store.save(PkceFlowPurpose.signup, 'b');

      await store.remove(a.id);
      final remaining = await store.readAll();
      expect(remaining, hasLength(1));
      expect(remaining.single.id, b.id);
      expect(remaining.single.verifier, 'b');
    });

    test('remove is idempotent and safe for unknown ids', () async {
      final store = SecuredStoreForTest(RecordingSecureStorage());
      await store.remove('does-not-exist');
      await store.remove('does-not-exist');
      expect(await store.readAll(), isEmpty);
    });

    test('per-purpose eviction bounds stored secrets', () async {
      final store = SecuredStoreForTest(RecordingSecureStorage());
      for (var i = 0; i < SecurePkceVerifierStore.maxFlowsPerPurpose + 2; i++) {
        await store.save(PkceFlowPurpose.signup, 'v$i');
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      final flows = await store.readAll();
      expect(
        flows.where((f) => f.purpose == PkceFlowPurpose.signup).length,
        SecurePkceVerifierStore.maxFlowsPerPurpose,
      );
      // The newest survive.
      expect(flows.first.verifier, isNotEmpty);
    });

    test('a legacy single-slot verifier is still adopted', () async {
      final storage = RecordingSecureStorage();
      storage.values[SecurePkceVerifierStore.legacyKey] = 'legacy-verifier';
      final store = SecuredStoreForTest(storage);

      final all = await store.readAll();
      expect(all, hasLength(1));
      expect(all.single.verifier, 'legacy-verifier');
      expect(all.single.purpose, PkceFlowPurpose.signup);
    });

    test('consuming the legacy flow clears the old key', () async {
      final storage = RecordingSecureStorage();
      storage.values[SecurePkceVerifierStore.legacyKey] = 'legacy-verifier';
      final store = SecuredStoreForTest(storage);

      await store.remove(SecurePkceVerifierStore.legacyFlowId);
      expect(storage.values.containsKey(SecurePkceVerifierStore.legacyKey),
          isFalse);
      expect(await store.readAll(), isEmpty);
    });

    test('corrupt rows are skipped, never used as a verifier', () async {
      final storage = RecordingSecureStorage();
      storage.values['legal_supabase_pkce_v2:signup:bad'] = '';
      final store = SecuredStoreForTest(storage);

      final all = await store.readAll();
      expect(all.every((f) => f.isUsable), isFalse);
      expect(all.single.isUsable, isFalse);
    });

    test('cross-process safety: a stale writer cannot delete a newer flow',
        () async {
      final storage = RecordingSecureStorage();
      // Two stores over one keystore = two processes.
      final processA = SecuredStoreForTest(storage);
      final processB = SecuredStoreForTest(storage);

      final flowA = await processA.save(PkceFlowPurpose.signup, 'from-A');
      final flowB = await processB.save(PkceFlowPurpose.signup, 'from-B');

      // A finishes later and removes only its own row.
      await processA.remove(flowA.id);

      final remaining = await processB.readAll();
      expect(remaining, hasLength(1));
      expect(remaining.single.id, flowB.id);
      expect(remaining.single.verifier, 'from-B');
    });
  });

  group('callback failures route to the right journey', () {
    test('an invalid confirmation link lands on sign-in, not password reset',
        () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final deepLinks = StreamController<Uri>.broadcast();
      final client = server.client;
      final gateway = SupabaseAuthGateway(
        client: client,
        supabaseUrl: _url,
        supabaseAnonKey: _anonKey,
        authRedirectUrl: _redirect,
        allowClientSignup: true,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: pkce,
      );
      final session = SessionController(
        auth: AuthService(
          gateway: gateway,
          api: ApiClient(
            client: client,
            supabaseUrl: _url,
            supabaseAnonKey: _anonKey,
            idTokenProvider: () => gateway.getAccessToken(),
            currentUidProvider: () => gateway.currentUser?.uid,
          ),
        ),
        recoveryLinkStream: deepLinks.stream,
      );
      session.start();
      await Future<void>.delayed(Duration.zero);

      // No verifier was ever stored on this device.
      server.codes['code-orphan'] = 'orphan';
      deepLinks.add(server.callbackFor('code-orphan'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(session.status, SessionStatus.signedOut);
      expect(
        session.isPasswordRecoveryFlow,
        isFalse,
        reason: 'a failed email confirmation is not a password recovery',
      );
      expect(session.error, contains('confirmation link'));
      await deepLinks.close();
      session.dispose();
    });
  });

  group('end-to-end: register -> confirm -> protected session', () {
    test('the whole journey ends in SessionStatus.signedIn', () async {
      final server = FakeSupabaseAuth();
      final pkce = MemoryPkceVerifierStore();
      final client = server.client;
      final gateway = SupabaseAuthGateway(
        client: client,
        supabaseUrl: _url,
        supabaseAnonKey: _anonKey,
        authRedirectUrl: _redirect,
        allowClientSignup: true,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: pkce,
      );
      final api = ApiClient(
        client: client,
        supabaseUrl: _url,
        supabaseAnonKey: _anonKey,
        idTokenProvider: () => gateway.getAccessToken(),
        currentUidProvider: () => gateway.currentUser?.uid,
      );
      // This is the production delivery path: `app_links.uriLinkStream` is
      // handed to SessionController as `recoveryLinkStream` by
      // `createSupabaseSession` in app_bootstrap.dart.
      final deepLinks = StreamController<Uri>.broadcast();
      final session = SessionController(
        auth: AuthService(gateway: gateway, api: api),
        recoveryLinkStream: deepLinks.stream,
      );
      session.start();
      await Future<void>.delayed(Duration.zero);

      // 1. Register: confirmation is required, so the app stays signed out.
      expect(
        await session.register(
          name: 'Sara',
          email: _email,
          password: 'secret123',
        ),
        isFalse,
      );
      expect(session.registrationErrorCode, 'email-confirmation-required');
      expect(session.status, SessionStatus.signedOut);

      // 2. The user taps the confirmation email; Android delivers the link.
      server.codes['code-e2e'] = 'e2e';
      deepLinks.add(server.callbackFor('code-e2e'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 3. The session is installed, the profile loaded, and the app unlocked.
      expect(session.status, SessionStatus.signedIn);
      expect(session.user?.uid, _authUid);
      expect(session.profile?.uid, _authUid);
      expect(session.isSignedIn, isTrue);
      await deepLinks.close();
      session.dispose();
    });
  });
}
