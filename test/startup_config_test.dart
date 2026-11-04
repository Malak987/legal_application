import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legalserviceapp/app_bootstrap.dart';
import 'package:legalserviceapp/config/supabase_client_config.dart';
import 'package:legalserviceapp/services/api_client.dart';
import 'package:legalserviceapp/services/auth_service.dart';
import 'package:legalserviceapp/state/session_controller.dart';

import 'support/fakes.dart';

// Test-only fixtures. None of these is a real project credential.
const _url = 'https://qqfzbecwhewswkyxgebu.supabase.co';
const _publishable = 'sb_publishable_TESTONLY_not_a_real_key_0000';
const _authUid = '00000000-0000-4000-8000-000000000099';

SupabaseClientConfig _valid() =>
    SupabaseClientConfig.resolve(url: _url, anonKey: _publishable);

/// Records the order in which startup touches the auth layer.
class _RecordingGateway extends FakeAuthGateway {
  _RecordingGateway(this.events);

  final List<String> events;

  @override
  Future<AuthUser?> restoreSession({Uri? callbackUri}) {
    events.add('restore');
    return super.restoreSession(callbackUri: callbackUri);
  }
}

/// A Supabase project emulated over HTTP: Auth token/refresh endpoints and the
/// caller's `public.users` profile row. Every request is recorded.
MockClient _supabaseProject(List<http.Request> requests) {
  return MockClient((request) async {
    requests.add(request);
    if (request.url.path == '/auth/v1/token') {
      final grant = request.url.queryParameters['grant_type'];
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (grant == 'password' && body['password'] == 'wrong') {
        return http.Response(
          jsonEncode({
            'error_code': 'invalid_credentials',
            'msg': 'Invalid login credentials',
          }),
          400,
        );
      }
      return http.Response(
        jsonEncode({
          'access_token': 'access-$grant',
          'refresh_token': 'refresh-$grant',
          'expires_in': 3600,
          'user': {'id': _authUid, 'email': 'sara@example.com'},
        }),
        200,
      );
    }
    if (request.url.path == '/rest/v1/users') {
      return supabaseOk([profileJson(id: _authUid)]);
    }
    return http.Response('{}', 404);
  });
}

void main() {
  group('startup ordering', () {
    testWidgets(
      'invalid config: no session is created, actionable screen shown',
      (tester) async {
        var created = 0;
        var built = 0;
        final app = bootstrapApp(
          buildApp: (_) {
            built++;
            return const SizedBox();
          },
          config: SupabaseClientConfig.resolve(url: _url, anonKey: ''),
          createSession: (_) {
            created++;
            return SessionController(
              auth: AuthService(
                gateway: FakeAuthGateway(),
                api: testApiClient(
                  handler: (_, __) async => supabaseOk(const []),
                ),
              ),
            );
          },
        );
        await tester.pumpWidget(app);

        expect(created, 0);
        expect(built, 0);
        expect(find.byKey(const Key('supabase-config-error')), findsOneWidget);
        expect(
          find.textContaining('SUPABASE_ANON_KEY is empty'),
          findsOneWidget,
        );
        expect(
          find.textContaining('--dart-define-from-file=supabase.local.json'),
          findsOneWidget,
        );
      },
    );

    testWidgets('valid config: one session is created, then restore starts', (
      tester,
    ) async {
      final config = _valid();
      final events = <String>[];
      SupabaseClientConfig? received;
      final app = bootstrapApp(
        buildApp: (_) => const SizedBox(key: Key('bootstrap-test-app')),
        config: config,
        createSession: (c) {
          events.add('create');
          received = c;
          return SessionController(
            auth: AuthService(
              gateway: _RecordingGateway(events),
              api: testApiClient(
                handler: (_, __) async => supabaseOk(const []),
              ),
            ),
          );
        },
      );

      expect(events, [
        'create',
        'restore',
      ], reason: 'validated before creation; restore after creation');
      expect(identical(received, config), isTrue);

      await tester.pumpWidget(app);
      expect(find.byKey(const Key('bootstrap-test-app')), findsOneWidget);
      expect(find.byKey(const Key('supabase-config-error')), findsNothing);
      expect(find.textContaining('not configured'), findsNothing);
      // Let the splash animation/timers finish so the test ends cleanly.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });

  group('one validated config for Auth and data', () {
    test('gateway and API client share the identical config', () {
      final config = _valid();
      final session = createSupabaseSession(
        config,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        sessionStore: MemoryAuthSessionStore(),
      );
      final gateway = session.authService.gateway as SupabaseAuthGateway;
      expect(identical(gateway.config, config), isTrue);
      expect(identical(session.authService.api.config, config), isTrue);
      expect(gateway.isConfigured, isTrue);
      expect(session.authService.api.usesSupabase, isTrue);
      session.dispose();
    });

    test(
      'invalid config fails fast with an actionable error and no request',
      () async {
        final requests = <http.Request>[];
        final config = SupabaseClientConfig.resolve(url: _url, anonKey: '');
        final gateway = SupabaseAuthGateway(
          config: config,
          client: _supabaseProject(requests),
          sessionStore: MemoryAuthSessionStore()..refreshToken = 'stored',
        );
        final api = ApiClient(
          config: config,
          client: _supabaseProject(requests),
          idTokenProvider: () async => 'token',
          currentUidProvider: () => 'uid-1',
        );

        for (final call in <Future<Object?> Function()>[
          () => gateway.restoreSession(),
          () => gateway.signIn(email: 'sara@example.com', password: 'pw'),
        ]) {
          await expectLater(
            call(),
            throwsA(
              isA<AuthException>()
                  .having((e) => e.code, 'code', 'auth-not-configured')
                  .having(
                    (e) => e.message,
                    'message',
                    contains('SUPABASE_ANON_KEY'),
                  ),
            ),
          );
        }
        await expectLater(
          api.getMyProfile(),
          throwsA(
            isA<ApiException>()
                .having((e) => e.statusCode, 'status', 503)
                .having(
                  (e) => e.message,
                  'message',
                  contains('SUPABASE_ANON_KEY'),
                ),
          ),
        );
        expect(requests, isEmpty);
        gateway.dispose();
        api.dispose();
      },
    );
  });

  group('session restoration and login use the configured client', () {
    test(
      'a stored refresh token is restored against the configured project',
      () async {
        final requests = <http.Request>[];
        final store = MemoryAuthSessionStore()..refreshToken = 'stored-refresh';
        final session = createSupabaseSession(
          _valid(),
          httpClient: _supabaseProject(requests),
          sessionStore: store,
        );

        session.start();
        while (session.isResolving) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(
          session.status,
          SessionStatus.signedIn,
          reason: '${session.error}',
        );
        expect(session.profile?.uid, _authUid);
        expect(requests.map((r) => '${r.method} ${r.url.path}'), [
          'POST /auth/v1/token',
          'GET /rest/v1/users',
        ]);
        expect(
          requests.first.url.queryParameters['grant_type'],
          'refresh_token',
        );
        for (final request in requests) {
          expect(request.url.origin, _url);
          expect(request.headers['apikey'] == _publishable, isTrue);
        }
        expect(
          requests.last.headers['authorization'],
          'Bearer access-refresh_token',
        );
        expect(store.refreshToken, 'refresh-refresh_token', reason: 'rotated');
        session.dispose();
      },
    );

    test(
      'password login and profile load go to the configured project',
      () async {
        final requests = <http.Request>[];
        final session = createSupabaseSession(
          _valid(),
          httpClient: _supabaseProject(requests),
          sessionStore: MemoryAuthSessionStore(),
        );
        session.start();
        while (session.isResolving) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(session.status, SessionStatus.signedOut);
        expect(
          session.error,
          isNull,
          reason: 'no stored session is not an error',
        );
        expect(requests, isEmpty);

        expect(
          await session.signIn(email: 'sara@example.com', password: 'wrong'),
          isFalse,
        );
        expect(session.error, isNot(contains('not configured')));

        expect(
          await session.signIn(email: 'sara@example.com', password: 'secret'),
          isTrue,
        );
        expect(session.status, SessionStatus.signedIn);
        final login = requests.where(
          (r) =>
              r.url.path == '/auth/v1/token' &&
              r.url.queryParameters['grant_type'] == 'password',
        );
        expect(login, hasLength(2));
        expect(requests.last.url.path, '/rest/v1/users');
        for (final request in requests) {
          expect(request.url.origin, _url);
          expect(request.headers['apikey'] == _publishable, isTrue);
        }
        session.dispose();
      },
    );
  });
}
