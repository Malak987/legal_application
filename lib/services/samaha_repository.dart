import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/samaha_catalog.dart';

enum SamahaAssetError { missingAsset, invalidData }

/// A packaging/read error, never an authentication or connectivity error.
class SamahaAssetException implements Exception {
  const SamahaAssetException(this.kind, this.asset);
  final SamahaAssetError kind;
  final String asset;

  @override
  String toString() => 'SamahaAssetException(${kind.name}, $asset)';
}

/// Standalone, asset-only directory. It has no ApiClient, session, token,
/// registered-lawyer repository, remote fallback, network image or DB import.
/// A successful immutable snapshot is cached for this repository's lifetime.
class SamahaRepository {
  SamahaRepository({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  Future<SamahaCatalog>? _snapshot;

  static const assetRoot = 'assets/data/samaha/';
  static const assetFiles = <String, String>{
    'companies.json': 'companies',
    'services.json': 'services',
    'team.json': 'people',
    'locations.json': 'locations',
    'faqs.json': 'faqs',
    'contacts.json': 'contacts',
    'relationships.json': 'relationships',
    'media.json': 'media',
  };
  static const _entryKinds = <String, String>{
    'services': 'service',
    'people': 'person',
    'locations': 'branch',
    'faqs': 'faq',
    'contacts': 'contact',
  };

  Future<SamahaCatalog> fetchCatalog() =>
      _snapshot ??= _load().onError((Object error, StackTrace stack) {
        // A failed asset load is retryable; never cache an incomplete catalogue.
        _snapshot = null;
        Error.throwWithStackTrace(error, stack);
      });

  Future<Map<String, dynamic>> _read(String file) async {
    final path = '$assetRoot$file';
    final String text;
    try {
      text = await _bundle.loadString(path);
    } catch (_) {
      // CachingAssetBundle caches failed loadString futures too. Evict only
      // this feature's failed key so a real retry can recover after a read error.
      _bundle.evict(path);
      throw SamahaAssetException(SamahaAssetError.missingAsset, path);
    }
    try {
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic> ||
          value['schema_version'] is! int ||
          value['schema_version'] != 1 ||
          value['dataset_id'] is! String ||
          (value['dataset_id'] as String).isEmpty) {
        throw const FormatException('Unsupported asset document');
      }
      return value;
    } on FormatException {
      _bundle.evict(path);
      throw SamahaAssetException(SamahaAssetError.invalidData, path);
    }
  }

  void _evictInvalidRelease() {
    for (final file in ['manifest.json', ...assetFiles.keys]) {
      _bundle.evict('$assetRoot$file');
    }
  }

  Future<SamahaCatalog> _load() async {
    final manifest = await _read('manifest.json');
    final documents = await Future.wait(assetFiles.keys.map(_read));
    try {
      final listedFiles = manifest['files'];
      if (listedFiles is! List ||
          listedFiles.length != assetFiles.length ||
          listedFiles.toSet().length != assetFiles.length ||
          !listedFiles.toSet().containsAll(assetFiles.keys)) {
        throw const FormatException('Asset registry mismatch');
      }
      final collections = <String, List<Map<String, dynamic>>>{};
      for (var i = 0; i < documents.length; i++) {
        final document = documents[i];
        final key = assetFiles.values.elementAt(i);
        final rows = document[key];
        if (document['dataset_id'] != manifest['dataset_id'] ||
            rows is! List ||
            rows.any((row) => row is! Map<String, dynamic>)) {
          throw const FormatException('Mixed or malformed asset release');
        }
        final records = rows.cast<Map<String, dynamic>>();
        if (_entryKinds.containsKey(key) &&
            records.any((row) => row['kind'] != _entryKinds[key])) {
          throw const FormatException('Incorrect record kind');
        }
        collections[key] = records;
      }
      final counts = manifest['counts'];
      if (counts is! Map ||
          counts.length != collections.length ||
          collections.entries.any(
            (entry) =>
                counts[entry.key] is! int ||
                counts[entry.key] != entry.value.length,
          )) {
        throw const FormatException('Incomplete asset release');
      }
      final companies = collections['companies']!;
      final entries = [
        for (final key in _entryKinds.keys) ...collections[key]!,
      ];
      final links = collections['relationships']!;
      final media = collections['media']!;
      final all = [...companies, ...entries, ...links, ...media];
      if (all.map((row) => row['id']).toSet().length != all.length ||
          companies.any(
            (row) =>
                row['website_url'] != null &&
                (row['website_url'] is! String ||
                    samahaWebUri(row['website_url'] as String) == null),
          )) {
        throw const FormatException('Duplicate ID or unsafe company website');
      }
      final catalog = SamahaCatalog.fromJson({
        'companies': companies,
        'entries': entries,
        'links': links,
        'media': media,
      });
      // The model hides unsafe/unreviewed/orphan records defensively. Bundled
      // releases must be complete, so reject rather than silently ship a subset.
      if (catalog.companies.length != companies.length ||
          catalog.entries.length != entries.length ||
          catalog.links.length != links.length ||
          catalog.media.length != media.length) {
        throw const FormatException('Unreviewed or inconsistent asset graph');
      }
      return catalog;
    } on FormatException {
      _evictInvalidRelease();
      throw const SamahaAssetException(
        SamahaAssetError.invalidData,
        '${assetRoot}manifest.json',
      );
    } on TypeError {
      _evictInvalidRelease();
      throw const SamahaAssetException(
        SamahaAssetError.invalidData,
        '${assetRoot}manifest.json',
      );
    }
  }
}
