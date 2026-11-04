import 'package:flutter_test/flutter_test.dart';
import 'package:legalserviceapp/services/app_repository.dart';

import 'support/fakes.dart';

void main() {
  group('legal category repository', () {
    test('loads public categories through Supabase', () async {
      final api = testApiClient(handler: (request, _) async {
        return supabaseOk([
          {'id': 'family-law', 'name': 'Family law', 'slug': 'family-law'},
        ]);
      });

      final categories = await AppRepository(api).fetchCategories(search: 'family');

      expect(categories, hasLength(1));
      expect(categories.single.id, 'family-law');
      expect(categories.single.name, 'Family law');
      expect(categories.single.slug, 'family-law');
    });

    test('sends category selection as query parameter to Supabase', () async {
      Uri? seen;
      final api = testApiClient(handler: (request, _) async {
        seen = request.url;
        return supabaseOk([
          {'id': 'lawyer-1', 'category_id': 'family-law', 'name': 'Nour Hassan'}
        ], headers: {'content-range': '0-0/1'});
      });

      await AppRepository(api).fetchLawyerPage(
        categoryId: 'family-law',
      );

      expect(seen!.queryParameters['category_id'], 'eq.family-law');
    });
  });
}
