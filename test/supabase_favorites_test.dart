import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:legalserviceapp/services/app_repository.dart';

import 'support/fakes.dart';

void main() {
  group('authenticated Supabase favorites slice', () {
    test('reads only the session owner and joins public lawyer data', () async {
      final requests = <http.Request>[];
      final api = testApiClient(
        handler: (request, _) async {
          requests.add(request);
          if (request.url.path.contains('users')) {
            return supabaseOk(<Map<String, dynamic>>[
              profileJson(id: 'profile-1', uid: 'profile-1'),
            ]);
          }
          if (request.url.path.contains('favorites')) {
            return supabaseOk(
              <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'favorite-1',
                  'user_id': 'profile-1',
                  'lawyer_id': 'lawyer-1',
                  'created_at': '2026-10-23T12:00:00Z',
                },
              ],
              headers: {'content-range': '0-0/1'},
            );
          }
          if (request.url.path.contains('lawyers')) {
            return supabaseOk(<Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'lawyer-1',
                'name': 'Nour Hassan',
                'specialty': 'Family law',
                'price': 'EGP 1,000 / hour',
                'price_value': 1000,
                'rating': 4.8,
                'location': 'Sohag',
              },
            ]);
          }
          return supabaseError(500, 'unexpected request');
        },
        uid: 'profile-1',
      );
      addTearDown(api.dispose);

      final entries = await AppRepository(api).fetchMyFavorites();

      expect(entries, hasLength(1));
      expect(entries.single.favoriteId, 'favorite-1');
      expect(entries.single.lawyer.id, 'lawyer-1');
      expect(entries.single.lawyer.name, 'Nour Hassan');
      expect(requests, hasLength(4));

      final favoritesRequest = requests[2];
      expect(favoritesRequest.method, 'GET');
      expect(favoritesRequest.url.path, contains('favorites'));
      expect(
        favoritesRequest.url.queryParameters['select'],
        'id,user_id,lawyer_id,created_at',
      );
      expect(favoritesRequest.url.queryParameters['order'], 'id.asc');
      expect(favoritesRequest.headers['apikey'], 'test-anon-key');
      expect(favoritesRequest.headers['Authorization'], 'Bearer test-token');
    });

    test(
      'adds with the authenticated RPC and never sends an owner ID',
      () async {
        late http.Request request;
        final api = testApiClient(
          handler: (incoming, _) async {
            request = incoming;
            return supabaseOk(<String, dynamic>{
              'id': 'favorite-1',
              'user_id': 'profile-1',
              'lawyer_id': 'lawyer-1',
            });
          },
          uid: 'profile-1',
        );
        addTearDown(api.dispose);

        final favoriteId = await AppRepository(api).addFavorite(' lawyer-1 ');

        expect(favoriteId, 'favorite-1');
        expect(request.method, 'POST');
        expect(request.url.path, contains('rpc/rpc_favorite_add'));
        expect(jsonDecode(request.body), <String, dynamic>{
          'p_lawyer_id': 'lawyer-1',
        });
        expect(request.headers['apikey'], 'test-anon-key');
        expect(request.headers['Authorization'], 'Bearer test-token');
      },
    );

    test(
      'deletes by favorite ID and relies on RLS for owner authorization',
      () async {
        late http.Request request;
        final api = testApiClient(
          handler: (incoming, _) async {
            request = incoming;
            return supabaseOk(<Map<String, dynamic>>[
              <String, dynamic>{'id': 'favorite-1'},
            ]);
          },
          uid: 'profile-1',
        );
        addTearDown(api.dispose);

        await AppRepository(api).removeFavorite('favorite-1');

        expect(request.method, 'DELETE');
        expect(request.url.path, contains('favorites'));
        expect(request.url.queryParameters['id'], 'eq.favorite-1');
        expect(request.headers['Prefer'], 'return=representation');
        expect(request.headers['Authorization'], 'Bearer test-token');
      },
    );
  });
}
