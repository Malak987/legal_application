// Regression tests for the production booking/chat authentication failure.
//
// THE FAILURE
// -----------
// Opening a lawyer's availability screen showed
//
//     Could not load availability
//     AUTHENTICATION REQUIRED
//     Try again
//
// and the chat screens failed the same way. The live database proved why: a
// client profile is provisioned with `role = 'user'` (public
// `link_migrated_auth_user`), the app accepts that as a client
// (`AppProfile.isClient`), but `private.current_app_user_id()` only resolved
// client|lawyer|admin|owner. So `auth.uid()` was present while the actor was
// NULL and every guarded RPC raised `42501 AUTHENTICATION_REQUIRED`.
// The database side is fixed by
// `supabase/migrations/20261107093000_resolve_user_role_actor.sql` and guarded
// by `supabase/tests/actor_role_resolution_test.sql`.
//
// WHAT THESE TESTS PIN (client side)
// ----------------------------------
//  * an authenticated request always carries `Authorization: Bearer <token>`
//    and the public `apikey`; it never falls back to an anonymous request;
//  * a 401 is retried exactly once, with a refreshed token;
//  * a refresh that cannot produce a new token is not replayed: the caller gets
//    an explicit session-expired error instead;
//  * concurrent 401s share one refresh-token rotation (Supabase rotates refresh
//    tokens, so a second rotation can invalidate the session);
//  * a failed refresh ends the session instead of continuing anonymously;
//  * the raw `AUTHENTICATION_REQUIRED` machine code is never shown to a user;
//  * the app's role contract treats `user` as a client, matching the database
//    fix;
//  * loading/sending chat messages uses the session identity only — the client
//    never sends a sender id.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legalserviceapp/models/app_profile.dart';
import 'package:legalserviceapp/services/api_client.dart';
import 'package:legalserviceapp/services/app_repository.dart';
import 'package:legalserviceapp/services/auth_service.dart';

import 'support/fakes.dart';

const String _supabaseUrl = 'https://test.supabase.co';
const String _anonKey = 'test-anon-key';
const String _uid = 'uid-1';

http.Response _json(Object? body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

/// One captured request, reduced to what these tests assert about.
class _Seen {
  _Seen(http.Request request)
    : path = request.url.path,
      authorization = request.headers['Authorization'],
      apikey = request.headers['apikey'],
      body = request.body;

  final String path;
  final String? authorization;
  final String? apikey;
  final String body;

  Map<String, dynamic> get json =>
      body.isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(body) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('access token lifecycle', () {
    test('a 401 is retried once with the refreshed token', () async {
      final seen = <_Seen>[];
      var tokenCalls = 0;
      final api = ApiClient(
        client: MockClient((request) async {
          seen.add(_Seen(request));
          return request.headers['Authorization'] == 'Bearer fresh'
              ? supabaseOk([profileJson()])
              : supabaseError(401, 'JWT expired');
        }),
        supabaseUrl: _supabaseUrl,
        supabaseAnonKey: _anonKey,
        currentUidProvider: () => _uid,
        // First call: the token the server just rejected. Second call: the
        // token that the refresh produced.
        idTokenProvider: () async => ++tokenCalls == 1 ? 'expired' : 'fresh',
      );

      final profile = await api.getMyProfile();

      expect(profile.uid, _uid);
      expect(seen.length, 2, reason: 'exactly one retry');
      expect(tokenCalls, 2);
      expect(
        seen.map((request) => request.authorization),
        ['Bearer expired', 'Bearer fresh'],
      );
      // Neither attempt is anonymous and both carry the public key.
      for (final request in seen) {
        expect(request.apikey, _anonKey);
        expect(request.authorization, startsWith('Bearer '));
      }
      api.dispose();
    });

    test(
      'a refresh that returns the rejected token is not replayed',
      () async {
        final seen = <_Seen>[];
        final api = ApiClient(
          client: MockClient((request) async {
            seen.add(_Seen(request));
            return supabaseError(401, 'JWT expired');
          }),
          supabaseUrl: _supabaseUrl,
          supabaseAnonKey: _anonKey,
          currentUidProvider: () => _uid,
          idTokenProvider: () async => 'expired',
          forceRefreshTokenProvider: (_) async => 'expired',
        );

        await expectLater(
          api.getMyProfile(),
          throwsA(
            isA<ApiException>()
                .having((error) => error.statusCode, 'statusCode', 401)
                .having(
                  (error) => error.kind,
                  'kind',
                  ApiErrorKind.unauthorized,
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('session has expired'),
                ),
          ),
        );

        expect(seen.length, 1, reason: 'the stale token must not be replayed');
        api.dispose();
      },
    );

    test('a missing token sends no request at all', () async {
      var requests = 0;
      final api = ApiClient(
        client: MockClient((_) async {
          requests++;
          return supabaseOk([profileJson()]);
        }),
        supabaseUrl: _supabaseUrl,
        supabaseAnonKey: _anonKey,
        currentUidProvider: () => _uid,
        idTokenProvider: () async => null,
      );

      await expectLater(
        api.getMyProfile(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      expect(requests, 0, reason: 'never silently anonymous');
      api.dispose();
    });

    test('two concurrent 401s rotate the refresh token exactly once', () async {
      var refreshCalls = 0;
      final gateway = SupabaseAuthGateway(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/token')) {
            final grant = request.url.queryParameters['grant_type'];
            if (grant == 'password') {
              return _json({
                'access_token': 'access-1',
                'refresh_token': 'refresh-1',
                'expires_in': 3600,
                'user': {'id': _uid, 'email': 'sara@example.com'},
              }, 200);
            }
            refreshCalls++;
            return _json({
              'access_token': 'access-2',
              'refresh_token': 'refresh-2',
              'expires_in': 3600,
              'user': {'id': _uid, 'email': 'sara@example.com'},
            }, 200);
          }
          return _json(const <String, dynamic>{}, 404);
        }),
        supabaseUrl: _supabaseUrl,
        supabaseAnonKey: _anonKey,
        sessionStore: MemoryAuthSessionStore(),
        pkceStore: MemoryPkceVerifierStore(),
      );

      await gateway.signIn(email: 'sara@example.com', password: 'secret123');

      final tokens = await Future.wait(<Future<String?>>[
        gateway.getAccessToken(forceRefresh: true, staleToken: 'access-1'),
        gateway.getAccessToken(forceRefresh: true, staleToken: 'access-1'),
      ]);

      expect(tokens, ['access-2', 'access-2']);
      expect(refreshCalls, 1, reason: 'one rotation for two rejected requests');

      // A late 401 that carries the token from *before* the refresh must reuse
      // the already-refreshed session rather than rotating again.
      expect(
        await gateway.getAccessToken(forceRefresh: true, staleToken: 'access-1'),
        'access-2',
      );
      expect(refreshCalls, 1);

      gateway.dispose();
    });

    test('a failed refresh ends the session instead of going anonymous', () async {
      final store = MemoryAuthSessionStore();
      final gateway = SupabaseAuthGateway(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/token')) {
            final grant = request.url.queryParameters['grant_type'];
            if (grant == 'password') {
              return _json({
                'access_token': 'access-1',
                'refresh_token': 'refresh-1',
                'expires_in': 3600,
                'user': {'id': _uid, 'email': 'sara@example.com'},
              }, 200);
            }
            return _json({
              'error': 'invalid_grant',
              'error_description': 'Invalid Refresh Token: Already Used',
            }, 400);
          }
          if (request.url.path.endsWith('/auth/v1/logout')) {
            return http.Response('', 204);
          }
          return _json(const <String, dynamic>{}, 404);
        }),
        supabaseUrl: _supabaseUrl,
        supabaseAnonKey: _anonKey,
        sessionStore: store,
        pkceStore: MemoryPkceVerifierStore(),
      );

      await gateway.signIn(email: 'sara@example.com', password: 'secret123');
      expect(await gateway.getAccessToken(), 'access-1');

      expect(
        await gateway.getAccessToken(forceRefresh: true, staleToken: 'access-1'),
        isNull,
      );
      expect(gateway.currentUser, isNull, reason: 'session ended, not anonymous');
      expect(store.refreshToken, isNull);

      gateway.dispose();
    });
  });

  group('role contract shared with the database', () {
    test('the signup role user is a client profile in the app', () {
      // The database provisioning trigger writes `role = 'user'`, and the
      // migration resolves that role to the caller's profile id. If this ever
      // stops being true, clients are rejected with AUTHENTICATION_REQUIRED
      // again.
      expect(AppProfile.fromJson({'id': _uid, 'role': 'user'}).isClient, isTrue);
      expect(
        AppProfile.fromJson({'id': _uid, 'role': 'client'}).isClient,
        isTrue,
      );
      expect(
        AppProfile.fromJson({'id': _uid, 'role': 'user'}).hasValidRole,
        isTrue,
      );
      expect(AppProfile.fromJson({'id': _uid, 'role': ''}).isClient, isFalse);
      expect(AppProfile.fromJson({'id': _uid, 'role': 'user'}).isLawyer, isFalse);
      expect(AppProfile.fromJson({'id': _uid, 'role': 'user'}).isAdmin, isFalse);
    });

    test('an RPC authorisation failure is explained, not echoed', () async {
      final api = testApiClient(
        handler: (request, _) async {
          expect(request.url.path, '/rest/v1/rpc/rpc_refresh_lawyer_availability');
          return _json({'code': '42501', 'message': 'AUTHENTICATION_REQUIRED'}, 403);
        },
      );

      await expectLater(
        AppRepository(api).fetchAvailability('lawyer-1'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'statusCode', 403)
              .having((error) => error.code, 'code', '42501')
              .having(
                (error) => error.message,
                'message',
                allOf(
                  isNot('AUTHENTICATION_REQUIRED'),
                  contains('Sign out and sign in again'),
                ),
              ),
        ),
      );
      api.dispose();
    });
  });

  group('booking requests', () {
    test('availability and booking send the session token and public key', () async {
      final seen = <_Seen>[];
      final api = testApiClient(
        handler: (request, _) async {
          seen.add(_Seen(request));
          if (request.url.path.endsWith('/rpc_refresh_lawyer_availability')) {
            return supabaseOk({
              'items': [
                {
                  'id': 'av-1',
                  'lawyer_id': 'lawyer-1',
                  'date': '2030-01-02',
                  'slots': ['10:00'],
                },
              ],
            });
          }
          if (request.url.path.endsWith('/rpc_create_booking')) {
            return supabaseOk({
              'booking': {
                'id': 'booking-1',
                'lawyer_id': 'lawyer-1',
                'date': '2030-01-02',
                'time': '10:00',
                'hours': 1,
                'status': 'Pending',
                'total_price': 250,
              },
            });
          }
          return _json(const <String, dynamic>{'message': 'unexpected'}, 500);
        },
      );
      final repository = AppRepository(api);

      final availability = await repository.fetchAvailability('lawyer-1');
      expect(availability.single.slots, [600]);

      final booking = await repository.createBooking(
        lawyerId: 'lawyer-1',
        lawyerName: 'Mona Fahmy',
        date: '2030-01-02',
        time: '10:00',
        hours: 1,
        idempotencyKey: 'idem-key-0001',
      );
      expect(booking['id'], 'booking-1');

      expect(seen.map((request) => request.path), [
        '/rest/v1/rpc/rpc_refresh_lawyer_availability',
        '/rest/v1/rpc/rpc_create_booking',
      ]);
      for (final request in seen) {
        expect(request.authorization, 'Bearer test-token');
        expect(request.apikey, _anonKey);
        expect(request.authorization, isNot(contains('sb_secret')));
        expect(request.apikey, isNot(contains('service_role')));
      }
      // The booking never names another user: the RPC derives the owner from
      // the verified JWT (requirement: a client books only as themselves).
      expect(seen.last.json['p_user_id'], isNull);
      expect(seen.last.json['p_idempotency_key'], 'idem-key-0001');
      api.dispose();
    });
  });

  group('chat requests', () {
    test('conversation load and message send use the session only', () async {
      final seen = <_Seen>[];
      final api = testApiClient(
        handler: (request, _) async {
          seen.add(_Seen(request));
          if (request.url.path == '/rest/v1/chats') {
            return supabaseOk([
              {
                'id': 'chat-1',
                'participants': [_uid, 'lawyer-uid'],
                'participant_names': {
                  _uid: 'Sara Ali',
                  'lawyer-uid': 'Mona Fahmy',
                },
                'last_message': 'hello',
                'created_at': '2030-01-01T10:00:00+00:00',
                'updated_at': '2030-01-01T10:05:00+00:00',
              },
            ]);
          }
          if (request.url.path.endsWith('/rpc_chat_messages_page')) {
            return supabaseOk({
              'items': [
                {
                  'id': 'msg-1',
                  'chat_id': 'chat-1',
                  'sender_id': 'lawyer-uid',
                  'sender_name': 'Mona Fahmy',
                  'text': 'hello',
                  'created_at': '2030-01-01T10:00:00+00:00',
                },
              ],
              'has_more': false,
              'next_before_created_at': '2030-01-01T10:00:00+00:00',
              'next_before_id': 'msg-1',
            });
          }
          if (request.url.path.endsWith('/rpc_chat_send_message')) {
            return supabaseOk({
              'id': 'msg-2',
              'chat_id': 'chat-1',
              'sender_id': _uid,
              'sender_name': 'Sara Ali',
              'text': 'hi there',
              'created_at': '2030-01-01T10:06:00+00:00',
              'replayed': false,
            });
          }
          return _json(const <String, dynamic>{'message': 'unexpected'}, 500);
        },
      );
      final repository = AppRepository(api);

      final chat = await repository.fetchChatMessages('chat-1');
      expect((chat['messages'] as List).length, 1);

      final sent = await repository.sendMessage(
        chatId: 'chat-1',
        text: 'hi there',
        clientMessageId: 'client-msg-0002',
      );
      expect(sent['id'], 'msg-2');

      for (final request in seen) {
        expect(request.authorization, 'Bearer test-token');
        expect(request.apikey, _anonKey);
      }

      final sendBody = seen.last.json;
      expect(sendBody.keys.toSet(), {
        'p_chat_id',
        'p_text',
        'p_client_message_id',
      }, reason: 'the sender identity comes from the session, never the client');
      expect(sendBody['p_chat_id'], 'chat-1');
      expect(sendBody['p_client_message_id'], 'client-msg-0002');
      api.dispose();
    });
  });
}
