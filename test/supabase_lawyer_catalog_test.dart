import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legalserviceapp/services/api_client.dart';
import 'package:legalserviceapp/services/app_repository.dart';

import 'support/fakes.dart';

void main() {
  group('public lawyer catalogue Supabase slice', () {
    test('uses anonymous PostgREST, server filters, and snake-case row mapping',
        () async {
      final requests = <http.Request>[];
      final api = ApiClient(
        client: MockClient((request) async {
          requests.add(request);
          return supabaseOk(<Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'lawyer-1',
              'category_id': 'family-category',
              'name': 'Nour Hassan',
              'specialty': 'Family law',
              'price': 'EGP 1,000 / hour',
              'price_value': 1000,
              'image': 'lawyer.png',
              'rating': 4.8,
              'location': 'Sohag',
              'experience': '12 years',
              'bio': 'Family and civil matters',
              'is_popular': true,
              'is_top': false,
            },
          ]);
        }),
        supabaseUrl: 'https://project.example.test',
        supabaseAnonKey: 'public-test-key',
      );
      addTearDown(api.dispose);

      final lawyers = await AppRepository(api).fetchLawyers(
        search: 'Family, Law',
        isPopular: true,
        isTop: false,
      );

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'GET');
      expect(request.url.origin, 'https://project.example.test');
      expect(request.url.path, '/rest/v1/lawyers');
      expect(request.headers['apikey'], 'public-test-key');
      expect(request.headers['Prefer'], 'count=exact');
      expect(request.headers.containsKey('Authorization'), isFalse);

      expect(lawyers, hasLength(1));
      final lawyer = lawyers.single;
      expect(lawyer.id, 'lawyer-1');
      expect(lawyer.name, 'Nour Hassan');
      expect(lawyer.isPopular, isTrue);
      expect(lawyer.isTop, isFalse);
    });

    test('filters PostgREST lawyer results by the selected category', () async {
      late http.Request request;
      final api = ApiClient(
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(
            jsonEncode(<Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'lawyer-1',
                'category_id': 'family-category',
                'name': 'Nour Hassan',
              },
            ]),
            200,
            headers: <String, String>{
              'content-type': 'application/json',
              'content-range': '0-0/1',
            },
          );
        }),
        supabaseUrl: 'https://project.example.test',
        supabaseAnonKey: 'public-test-key',
      );
      addTearDown(api.dispose);

      final page = await AppRepository(api).fetchLawyerPage(
        categoryId: 'family-category',
      );

      expect(request.url.path, '/rest/v1/lawyers');
      expect(request.url.queryParameters['category_id'], 'eq.family-category');
      expect(page.items.single.categoryId, 'family-category');
    });
  });
}
