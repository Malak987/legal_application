import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legalserviceapp/models/samaha_catalog.dart';
import 'package:legalserviceapp/services/samaha_repository.dart';

import 'support/samaha_fixtures.dart';

// Inherits the REAL CachingAssetBundle.loadString implementation, including
// its failed-future cache, rather than overriding away that behavior.
class RecoverableCachingBundle extends CachingAssetBundle {
  final content = samahaAssetTexts();
  bool failTeam = false;
  final reads = <String, int>{};

  @override
  Future<ByteData> load(String key) async {
    reads[key] = (reads[key] ?? 0) + 1;
    if (failTeam && key.endsWith('team.json')) {
      throw StateError('Transient asset failure');
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(content[key]!)));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Matcher assetError(SamahaAssetError kind) => throwsA(
    isA<SamahaAssetException>().having((error) => error.kind, 'kind', kind),
  );

  test(
    'default production repository loads real registered Flutter assets',
    () async {
      final catalog = await SamahaRepository().fetchCatalog();
      expect(catalog.companies.length, 6);
      expect(catalog.divisions.length, 5);
      expect(catalog.find(SamahaEntryKind.service).length, 22);
      expect(catalog.find(SamahaEntryKind.person).length, 28);
      expect(catalog.find(SamahaEntryKind.branch).length, 1);
      expect(catalog.find(SamahaEntryKind.faq).length, 3);
      expect(catalog.find(SamahaEntryKind.contact).length, 12);
      expect(catalog.links.length, 10);
      expect(catalog.media.length, 26);
    },
  );

  test(
    'complete catalogue loads with all Dart HTTP access prohibited',
    () async {
      var networkAttempts = 0;
      await HttpOverrides.runZoned(
        () async {
          final catalog = await SamahaRepository().fetchCatalog();
          expect(catalog.entries.length, 66);
          expect(
            catalog.company('company_translation')!.description.ar,
            isNotEmpty,
          );
        },
        createHttpClient: (_) {
          networkAttempts++;
          throw StateError('No network is permitted for the directory');
        },
      );
      expect(networkAttempts, 0);
    },
  );

  test(
    'concurrent loads and subsequent reloads reuse one immutable snapshot',
    () async {
      final bundle = SamahaTestBundle();
      final repository = SamahaRepository(bundle: bundle);
      final results = await Future.wait([
        repository.fetchCatalog(),
        repository.fetchCatalog(),
      ]);
      expect(identical(results[0], results[1]), isTrue);
      final again = await repository.fetchCatalog();
      expect(identical(again, results[0]), isTrue);
      expect(bundle.reads.length, 9);
      expect(bundle.reads.toSet().length, 9);
      expect(
        bundle.reads.every((path) => path.startsWith('assets/data/samaha/')),
        isTrue,
      );
      expect(() => again.entries.clear(), throwsUnsupportedError);
    },
  );

  test(
    'an absent local asset fails honestly and can be retried after correction',
    () async {
      final bundle = SamahaTestBundle();
      const key = '${SamahaRepository.assetRoot}team.json';
      final original = bundle.content.remove(key)!;
      final repository = SamahaRepository(bundle: bundle);
      await expectLater(
        repository.fetchCatalog(),
        assetError(SamahaAssetError.missingAsset),
      );
      bundle.content[key] = original;
      expect(
        (await repository.fetchCatalog()).find(SamahaEntryKind.person).length,
        28,
      );
    },
  );

  test(
    'real CachingAssetBundle failed futures are evicted before retry',
    () async {
      final bundle = RecoverableCachingBundle()..failTeam = true;
      final repository = SamahaRepository(bundle: bundle);
      await expectLater(
        repository.fetchCatalog(),
        assetError(SamahaAssetError.missingAsset),
      );
      bundle.failTeam = false;
      expect((await repository.fetchCatalog()).entries.length, 66);
      expect(bundle.reads['${SamahaRepository.assetRoot}team.json'], 2);
    },
  );

  test(
    'real CachingAssetBundle malformed cached strings are also retryable',
    () async {
      final bundle = RecoverableCachingBundle();
      const key = '${SamahaRepository.assetRoot}team.json';
      final good = bundle.content[key]!;
      bundle.content[key] = '{';
      final repository = SamahaRepository(bundle: bundle);
      await expectLater(
        repository.fetchCatalog(),
        assetError(SamahaAssetError.invalidData),
      );
      bundle.content[key] = good;
      expect((await repository.fetchCatalog()).entries.length, 66);
      expect(bundle.reads[key], 2);
    },
  );

  test('corrupt JSON is not a remote or fixture fallback', () async {
    final bundle = SamahaTestBundle();
    bundle.content['${SamahaRepository.assetRoot}companies.json'] = '{';
    await expectLater(
      SamahaRepository(bundle: bundle).fetchCatalog(),
      assetError(SamahaAssetError.invalidData),
    );
  });

  final invalidDocuments = <String, void Function(SamahaTestBundle)>{
    'unsupported document schema':
        (bundle) =>
            bundle.update('team.json', (doc) => doc['schema_version'] = 2),
    'mixed asset release versions':
        (bundle) => bundle.update(
          'team.json',
          (doc) => doc['dataset_id'] = 'another-release',
        ),
    'count mismatch':
        (bundle) => bundle.update(
          'manifest.json',
          (doc) => doc['counts']['people'] = 12,
        ),
    'duplicate ID across collections':
        (bundle) => bundle.update(
          'team.json',
          (doc) => doc['people'][0]['id'] = 'company_legal',
        ),
    'orphan company relationship':
        (bundle) => bundle.update(
          'team.json',
          (doc) => doc['people'][0]['company_id'] = 'missing-company',
        ),
    'cross-company relationship':
        (bundle) => bundle.update(
          'relationships.json',
          (doc) =>
              doc['relationships'][0]['company_id'] = 'company_translation',
        ),
    'wrong entry kind in a collection':
        (bundle) => bundle.update(
          'team.json',
          (doc) => doc['people'][0]['kind'] = 'service',
        ),
    'malformed localized field':
        (bundle) =>
            bundle.update('team.json', (doc) => doc['people'][0]['title'] = 13),
    'missing provenance':
        (bundle) => bundle.update(
          'services.json',
          (doc) => doc['services'][0]['source_refs'] = [],
        ),
    'unreviewed content in a public asset':
        (bundle) => bundle.update(
          'team.json',
          (doc) => doc['people'][0]['publication_status'] = 'needs_review',
        ),
    'unpublished company with otherwise approved children':
        (bundle) => bundle.update(
          'companies.json',
          (doc) => doc['companies'][1]['publication_status'] = 'excluded',
        ),
    'unsafe official website target':
        (bundle) => bundle.update(
          'companies.json',
          (doc) => doc['companies'][1]['website_url'] = 'javascript:alert(1)',
        ),
    'invalid team category':
        (bundle) => bundle.update(
          'team.json',
          (doc) =>
              doc['people'][0]['details']['team_category'] =
                  'registered_lawyer',
        ),
    'orphan location contact':
        (bundle) => bundle.update(
          'contacts.json',
          (doc) => doc['contacts'][0]['parent_entry_id'] = 'missing-location',
        ),
  };
  for (final entry in invalidDocuments.entries) {
    test(
      '${entry.key} rejects the whole local release, not a partial graph',
      () async {
        final bundle = SamahaTestBundle();
        entry.value(bundle);
        await expectLater(
          SamahaRepository(bundle: bundle).fetchCatalog(),
          assetError(SamahaAssetError.invalidData),
        );
      },
    );
  }

  test(
    'asset registry cannot redirect loading to a URL or private review file',
    () async {
      final bundle = SamahaTestBundle();
      bundle.update(
        'manifest.json',
        (doc) => doc['files'][0] = 'https://example.invalid/private.json',
      );
      await expectLater(
        SamahaRepository(bundle: bundle).fetchCatalog(),
        assetError(SamahaAssetError.invalidData),
      );
      expect(
        bundle.reads.every(
          (path) => path.startsWith(SamahaRepository.assetRoot),
        ),
        isTrue,
      );
      expect(
        bundle.reads.any((path) => path.contains('record_decisions')),
        isFalse,
      );
    },
  );

  test('empty approved local release is an honest empty result', () async {
    final bundle = SamahaTestBundle();
    for (final entry in SamahaRepository.assetFiles.entries) {
      bundle.update(entry.key, (doc) => doc[entry.value] = []);
      bundle.update('manifest.json', (doc) => doc['counts'][entry.value] = 0);
    }
    expect(
      (await SamahaRepository(bundle: bundle).fetchCatalog()).companies,
      isEmpty,
    );
  });

  test(
    'remote image URLs cannot enter a permitted local media release',
    () async {
      final bundle = SamahaTestBundle();
      final media = samahaMediaFixture(samahaFixture());
      media['asset_path'] = 'https://example.invalid/photo.png';
      bundle.update('media.json', (doc) => doc['media'] = [media]);
      bundle.update('manifest.json', (doc) => doc['counts']['media'] = 1);
      await expectLater(
        SamahaRepository(bundle: bundle).fetchCatalog(),
        assetError(SamahaAssetError.invalidData),
      );
    },
  );

  test(
    'bundled Arabic font and its redistribution license are in the app',
    () async {
      final font = await rootBundle.load(
        'assets/fonts/samaha/DirectoryArabic-Regular.ttf',
      );
      final license = await rootBundle.loadString(
        'assets/fonts/samaha/OFL.txt',
      );
      expect(font.lengthInBytes, greaterThan(100000));
      expect(license, contains('SIL OPEN FONT LICENSE Version 1.1'));
      expect(license, contains('Copyright 2022 The Noto Project Authors'));
    },
  );

  test('directory imports do not cross the operational boundary', () {
    final imports = RegExp(
      r'''^import .*?(api_client|app_repository|session_|auth_service|product_model|supabase|http/|cached_network_image)''',
      multiLine: true,
    );
    final featureFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (file) => file.path.contains('samaha') && file.path.endsWith('.dart'),
        );
    for (final file in featureFiles) {
      expect(
        imports.hasMatch(file.readAsStringSync()),
        isFalse,
        reason: file.path,
      );
    }
    final operational =
        File('lib/services/app_repository.dart').readAsStringSync();
    expect(operational.toLowerCase(), isNot(contains('samaha')));
    final home = File('lib/views/home/homescreen.dart').readAsStringSync();
    expect(home, contains('repository.fetchLawyerPage('));
    expect(home, contains('repository.fetchCategories()'));
    expect(
      home,
      contains('SamahaRepository(bundle: DefaultAssetBundle.of(context))'),
    );
  });

  test(
    'only approved records, never accounts or private observations, are shipped',
    () {
      final documents = samahaAssetTexts().map(
        (key, value) => MapEntry(key, jsonDecode(value)),
      );
      const forbiddenKeys = {
        'uid',
        'user_id',
        'lawyer_id',
        'auth_user_id',
        'password',
        'access_token',
        'record_decisions',
        'raw_observation',
      };
      void check(dynamic value) {
        if (value is Map) {
          expect(value.keys.toSet().intersection(forbiddenKeys), isEmpty);
          if (value.containsKey('publication_status')) {
            expect(value['publication_status'], 'approved');
          }
          for (final child in value.values) {
            check(child);
          }
        } else if (value is List) {
          for (final child in value) {
            check(child);
          }
        }
      }

      for (final document in documents.values) {
        check(document);
      }
    },
  );
}
