import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:legalserviceapp/models/product_model.dart';
import 'package:legalserviceapp/services/auth_service.dart';
import 'package:legalserviceapp/services/app_repository.dart';
import 'package:legalserviceapp/state/session_controller.dart';
import 'package:legalserviceapp/state/session_scope.dart';
import 'package:legalserviceapp/views/home/details.dart';
import 'package:legalserviceapp/views/popularlawyers/popularlawyers.dart';
import 'package:legalserviceapp/views/search/search_screen.dart';

import 'support/fakes.dart';

Map<String, dynamic> _lawyer(String id, String name) => <String, dynamic>{
  'id': id,
  'name': name,
  'price': 'EGP 500 / hour',
  'rating': 4.6,
  'location': 'Sohag',
  'specialty': 'Family law',
};

Map<String, dynamic> _page(
  List<Map<String, dynamic>> items, {
  required int page,
  required int total,
  int limit = 20,
  int? totalPages,
}) => <String, dynamic>{
  'items': items,
  'page': page,
  'limit': limit,
  'total': total,
  'totalPages': totalPages ?? (total == 0 ? 1 : ((total + limit - 1) ~/ limit)),
};

Future<void> _pumpWithApi(
  WidgetTester tester,
  Widget child, {
  required Future<http.Response> Function(http.Request request) handler,
}) async {
  final api = testApiClient(
    handler: (request, _) async {
      if (request.url.path == '/rest/v1/legal_categories') {
        return supabaseOk(<Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'family-law',
            'name': 'Family law',
            'slug': 'family-law',
          },
        ]);
      }
      return handler(request);
    },
  );
  final gateway = FakeAuthGateway();
  final session = SessionController(
    auth: AuthService(gateway: gateway, api: api),
  );
  addTearDown(api.dispose);
  addTearDown(session.dispose);
  addTearDown(gateway.dispose);

  await tester.pumpWidget(
    SessionScope(controller: session, child: MaterialApp(home: child)),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SearchScreen catalogue pagination', () {
    testWidgets('debounces search and loads the next page for that query', (
      tester,
    ) async {
      final requests = <http.Request>[];
      await _pumpWithApi(
        tester,
        const SearchScreen(),
        handler: (request) async {
          requests.add(request);
          final searchFilter = request.url.queryParameters['or'] ?? '';
          final query = searchFilter.contains('Nour') ? 'Nour' : '';
          final offset = int.parse(
            request.url.queryParameters['offset'] ?? '0',
          );
          final page = offset ~/ AppRepository.lawyerPageSize + 1;
          if (query == 'Nour') {
            return jsonOk(
              _page(
                <Map<String, dynamic>>[
                  _lawyer('nour-$page', page == 1 ? 'Nour Hassan' : 'Nour Ali'),
                ],
                page: page,
                total: 21,
              ),
            );
          }
          return jsonOk(
            _page(
              <Map<String, dynamic>>[_lawyer('initial-1', 'Initial Lawyer')],
              page: 1,
              total: 1,
            ),
          );
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('Initial Lawyer'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Nour');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Nour Hassan'), findsOneWidget);
      expect(find.text('Load more'), findsOneWidget);

      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();

      expect(find.text('Nour Ali'), findsOneWidget);
      expect(requests.map((request) => request.url.queryParameters['offset']), [
        '0',
        '0',
        '20',
      ]);
      expect(requests.last.url.queryParameters['or'], contains('Nour'));
    });

    testWidgets('filters lawyers when a category chip is selected', (
      tester,
    ) async {
      final lawyerRequests = <http.Request>[];
      await _pumpWithApi(
        tester,
        const SearchScreen(),
        handler: (request) async {
          lawyerRequests.add(request);
          final categoryId = request.url.queryParameters['category_id']
              ?.replaceFirst('eq.', '');
          final items =
              categoryId == 'family-law'
                  ? <Map<String, dynamic>>[
                    _lawyer('family-lawyer', 'Filtered family lawyer'),
                  ]
                  : <Map<String, dynamic>>[
                    _lawyer('general-lawyer', 'General lawyer'),
                  ];
          return jsonOk(_page(items, page: 1, total: items.length));
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('General lawyer'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Family law'));
      await tester.pumpAndSettle();

      expect(find.text('Filtered family lawyer'), findsOneWidget);
      expect(
        lawyerRequests.last.url.queryParameters['category_id'],
        'eq.family-law',
      );
    });

    testWidgets('renders loading, empty and retryable error states', (
      tester,
    ) async {
      final pending = Completer<http.Response>();
      var requests = 0;
      await _pumpWithApi(
        tester,
        const SearchScreen(),
        handler: (request) async {
          requests++;
          if (requests == 1) return pending.future;
          if ((request.url.queryParameters['or'] ?? '').contains('broken') &&
              requests == 2) {
            return jsonError(403, 'Catalogue access denied.');
          }
          return jsonOk(_page(<Map<String, dynamic>>[], page: 1, total: 0));
        },
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      pending.complete(
        jsonOk(_page(<Map<String, dynamic>>[], page: 1, total: 0)),
      );
      await tester.pumpAndSettle();
      expect(find.text('No lawyers listed yet'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'broken');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Search failed'), findsOneWidget);
      expect(find.text('Catalogue access denied.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('No lawyers found'), findsOneWidget);
    });
  });

  group('PopularLawyersScreen pagination', () {
    testWidgets('keeps the popular filter while loading another page', (
      tester,
    ) async {
      final requests = <http.Request>[];
      await _pumpWithApi(
        tester,
        const PopularLawyersScreen(),
        handler: (request) async {
          requests.add(request);
          final offset = int.parse(
            request.url.queryParameters['offset'] ?? '0',
          );
          final page = offset ~/ AppRepository.lawyerPageSize + 1;
          return jsonOk(
            _page(
              <Map<String, dynamic>>[
                _lawyer(
                  'popular-$page',
                  page == 1 ? 'Popular One' : 'Popular Two',
                ),
              ],
              page: page,
              total: 21,
            ),
          );
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Popular One'), findsOneWidget);
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();

      expect(find.text('Popular Two'), findsOneWidget);
      expect(requests.map((request) => request.url.queryParameters['offset']), [
        '0',
        '20',
      ]);
      expect(
        requests.every(
          (request) => request.url.queryParameters['is_popular'] == 'eq.true',
        ),
        isTrue,
      );
    });

    testWidgets('keeps the top-rated filter while loading another page', (
      tester,
    ) async {
      final requests = <http.Request>[];
      await _pumpWithApi(
        tester,
        const PopularLawyersScreen(onlyTop: true, title: 'Top Lawyers'),
        handler: (request) async {
          requests.add(request);
          final offset = int.parse(
            request.url.queryParameters['offset'] ?? '0',
          );
          final page = offset ~/ AppRepository.lawyerPageSize + 1;
          return jsonOk(
            _page(
              <Map<String, dynamic>>[
                _lawyer('top-$page', page == 1 ? 'Top One' : 'Top Two'),
              ],
              page: page,
              total: 21,
            ),
          );
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Top One'), findsOneWidget);
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();

      expect(find.text('Top Two'), findsOneWidget);
      expect(
        requests.every(
          (request) => request.url.queryParameters['is_top'] == 'eq.true',
        ),
        isTrue,
      );
      expect(
        requests.every(
          (request) => !request.url.queryParameters.containsKey('is_popular'),
        ),
        isTrue,
      );
    });
  });

  testWidgets('a missing detail does not keep rendering its passed list item', (
    tester,
  ) async {
    final lawyerRequests = <http.Request>[];
    await _pumpWithApi(
      tester,
      LegalServiceDetailsScreen(
        lawyer: Product(
          id: 'removed-lawyer',
          imagePath: '',
          name: 'Stale list entry',
          price: 'EGP 500 / hour',
        ),
        lawyerId: 'removed-lawyer',
      ),
      handler: (request) async {
        if (request.url.path == '/rest/v1/lawyers') {
          lawyerRequests.add(request);
          return supabaseOk(<Map<String, dynamic>>[]);
        }
        return jsonOk(<Map<String, dynamic>>[]);
      },
    );
    await tester.pumpAndSettle();

    expect(lawyerRequests, hasLength(1));
    expect(find.text('This lawyer is no longer available.'), findsOneWidget);
    expect(find.text('Stale list entry'), findsNothing);
  });
}
