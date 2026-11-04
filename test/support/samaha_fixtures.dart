import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:legalserviceapp/services/samaha_repository.dart';

/// Tests exercise the same shipped JSON, not a duplicate fixture projection.
Map<String, String> samahaAssetTexts() => {
  for (final file in ['manifest.json', ...SamahaRepository.assetFiles.keys])
    '${SamahaRepository.assetRoot}$file':
        File('${SamahaRepository.assetRoot}$file').readAsStringSync(),
};

Map<String, dynamic> samahaFixture() {
  final documents = samahaAssetTexts().map(
    (path, text) => MapEntry(path.split('/').last, jsonDecode(text)),
  );
  return {
    'reviewed_at': documents['manifest.json']['original_content_reviewed_at'],
    'companies': documents['companies.json']['companies'],
    'entries': [
      for (final file in [
        'services.json',
        'team.json',
        'locations.json',
        'faqs.json',
        'contacts.json',
      ])
        ...documents[file][SamahaRepository.assetFiles[file]],
    ],
    'links': documents['relationships.json']['relationships'],
    'media': documents['media.json']['media'],
  };
}

class SamahaTestBundle extends CachingAssetBundle {
  SamahaTestBundle([Map<String, String>? content])
    : content = content ?? samahaAssetTexts();
  final Map<String, String> content;
  final List<String> reads = [];

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    if (!key.startsWith(SamahaRepository.assetRoot)) {
      return rootBundle.loadString(key, cache: cache);
    }
    reads.add(key);
    final text = content[key];
    if (text == null) throw StateError('Missing test asset: $key');
    return text;
  }

  @override
  Future<ByteData> load(String key) async {
    if (!key.startsWith(SamahaRepository.assetRoot)) {
      return rootBundle.load(key);
    }
    return ByteData.sublistView(
      Uint8List.fromList(utf8.encode(await loadString(key))),
    );
  }

  void update(String file, void Function(Map<String, dynamic>) mutate) {
    final key = '${SamahaRepository.assetRoot}$file';
    final document = jsonDecode(content[key]!) as Map<String, dynamic>;
    mutate(document);
    content[key] = jsonEncode(document);
  }
}

Map<String, dynamic> samahaMediaFixture(Map<String, dynamic> fixture) {
  final person = (fixture['entries'] as List).firstWhere(
    (row) => row['kind'] == 'person',
  );
  return {
    'id': 'test_media',
    'company_id': person['company_id'],
    'entry_id': person['id'],
    'asset_path': 'assets/images/samaha/unit-test-only.png',
    'alt_text': {'en': 'Unit test portrait', 'ar': 'صورة اختبار'},
    'media_role': 'portrait',
    'rights_status': 'permitted',
    'permission_evidence': 'Synthetic unit-test evidence, not a real license',
    'association_evidence': 'Synthetic unit-test subject association',
    'original_sha256': List.filled(64, 'a').join(),
    'publication_status': 'approved',
    'source_refs': person['source_refs'],
    'review_basis': 'Synthetic model test only; not in shipped content',
    'reviewed_at': fixture['reviewed_at'],
  };
}
