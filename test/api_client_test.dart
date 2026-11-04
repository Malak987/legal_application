import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legalserviceapp/services/api_client.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Supabase ApiClient configuration', () {
    test('is configured when URL and anon key are present', () {
      final client = ApiClient(
        supabaseUrl: 'https://project.supabase.co',
        supabaseAnonKey: 'anon-key',
        client: MockClient((_) async => supabaseOk(const [])),
      );
      expect(client.usesSupabase, isTrue);
    });

    test('throws 503 when Supabase is not configured', () async {
      final client = ApiClient(
        supabaseUrl: '',
        supabaseAnonKey: '',
        client: MockClient((_) async => supabaseOk(const [])),
        currentUidProvider: () => 'uid-1',
        idTokenProvider: () async => 'token',
      );
      await expectLater(
        client.getMyProfile(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    });
  });

  group('Supabase requests', () {
    test('sends apikey, bearer token, and correct headers', () async {
      Uri? seen;
      Map<String, String>? headers;
      final api = testApiClient(
        handler: (request, _) async {
          seen = request.url;
          headers = request.headers;
          return supabaseOk([profileJson()]);
        },
      );

      await api.getMyProfile();

      expect(seen.toString(), contains('/rest/v1/users'));
      expect(headers!['apikey'], 'test-anon-key');
      expect(headers!['Authorization'], 'Bearer test-token');
    });

    test(
      'normalizes HTTP transport failures into typed network errors',
      () async {
        final api = testApiClient(
          handler: (_, __) async {
            throw http.ClientException('socket is unavailable');
          },
        );

        await expectLater(
          api.getSupabasePublicResource('lawyers', query: {}),
          throwsA(
            isA<ApiException>()
                .having((error) => error.kind, 'kind', ApiErrorKind.network)
                .having((error) => error.statusCode, 'statusCode', 0)
                .having((error) => error.isTransient, 'isTransient', isTrue),
          ),
        );
      },
    );

    test('a 401 is retried once with a refreshed token', () async {
      var tokenCalls = 0;
      var requestCalls = 0;
      final api = ApiClient(
        supabaseUrl: 'https://test.supabase.co',
        supabaseAnonKey: 'test-anon-key',
        client: MockClient((request) async {
          requestCalls++;
          if (request.headers['Authorization'] == 'Bearer fresh') {
            return supabaseOk([profileJson()]);
          }
          return supabaseError(401, 'Unauthorized');
        }),
        idTokenProvider: () async => ++tokenCalls == 1 ? 'stale' : 'fresh',
        currentUidProvider: () => 'uid-1',
      );

      final profile = await api.getMyProfile();

      expect(requestCalls, 2);
      expect(tokenCalls, 2);
      expect(profile.uid, 'uid-1');
    });

    test(
      'authenticated pages expose exact totals from Content-Range',
      () async {
        http.Request? seen;
        final api = ApiClient(
          supabaseUrl: 'https://test.supabase.co',
          supabaseAnonKey: 'test-anon-key',
          client: MockClient((request) async {
            seen = request;
            return supabaseOk(
              [
                {'id': 'chat-21'},
                {'id': 'chat-22'},
              ],
              headers: {'content-range': '20-21/42'},
            );
          }),
          idTokenProvider: () async => 'token-a',
          currentUidProvider: () => 'uid-a',
        );

        final page = await api.getSupabaseAuthenticatedPage(
          'chats',
          query: const {'order': 'id.asc'},
          page: 2,
          limit: 20,
        );

        expect(seen!.url.path, '/rest/v1/chats');
        expect(seen!.url.queryParameters['offset'], '20');
        expect(seen!.headers['Prefer'], 'count=exact');
        expect(page.exactTotal, 42);
        expect(page.total, 42);
        expect(page.totalPages, 3);
        expect(page.hasMore, isTrue);
        expect(page.map((row) => row['id']).exactTotal, 42);
        api.dispose();
      },
    );

    test(
      'an account switch prevents a pending old-user token from being sent',
      () async {
        var uid = 'uid-a';
        final oldToken = Completer<String?>();
        var requests = 0;
        var tokenCalls = 0;
        final seenAuthorization = <String?>[];
        final api = ApiClient(
          supabaseUrl: 'https://test.supabase.co',
          supabaseAnonKey: 'test-anon-key',
          client: MockClient((request) async {
            requests++;
            seenAuthorization.add(request.headers['Authorization']);
            return supabaseOk([]);
          }),
          idTokenProvider: () {
            if (tokenCalls++ == 0) return oldToken.future;
            return Future.value('token-for-$uid');
          },
          currentUidProvider: () => uid,
        );

        final pending = api.getSupabaseAuthenticatedResource(
          'rest/v1/chats',
          query: const {},
        );
        await Future<void>.delayed(Duration.zero);
        uid = 'uid-b';
        oldToken.complete('token-for-uid-a');

        await expectLater(
          pending,
          throwsA(
            isA<ApiException>().having(
              (error) => error.statusCode,
              'statusCode',
              401,
            ),
          ),
        );
        expect(requests, 0);
        expect(await api.freshAccessToken(expectedUid: 'uid-a'), isNull);
        await api.getSupabaseAuthenticatedResource(
          'rest/v1/chats',
          query: const {},
        );
        expect(requests, 1);
        expect(seenAuthorization, ['Bearer token-for-uid-b']);
        api.dispose();
      },
    );
  });
}
