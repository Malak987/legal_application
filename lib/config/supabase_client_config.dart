import 'dart:convert';

import 'supabase_config.dart';

// Pure Dart (no Flutter imports) so `tool/supabase_flutter.dart` can validate
// define files with exactly the same rules the app applies at startup.

/// A specific reason why the compiled Supabase configuration is unusable.
enum SupabaseConfigIssue {
  missingUrl,
  malformedUrl,
  insecureUrl,
  missingKey,
  malformedKey,
  secretKey,
  projectMismatch,
}

/// The single, validated Supabase client configuration for the mobile app.
///
/// [SupabaseConfig] holds the raw compile-time Dart defines. This class
/// validates them once ([environment]) and `main()` hands that one instance to
/// both [SupabaseAuthGateway] (sign-in, session restore, password flows) and
/// [ApiClient] (PostgREST, RPC, Storage, Edge Functions).
///
/// The key is never included in [errorMessage], [issueDescriptions] or
/// [toString]; diagnostics use [redactedKey].
class SupabaseClientConfig {
  SupabaseClientConfig._({
    required this.url,
    required this.anonKey,
    required List<SupabaseConfigIssue> issues,
  }) : issues = List.unmodifiable(issues);

  /// Validates raw values.
  ///
  /// [requireKnownKeyFormat] rejects anything that is neither a publishable
  /// key (`sb_publishable_…`) nor a legacy anon JWT, catching copied
  /// placeholders before a request is made. It is relaxed only for values
  /// injected explicitly by tests. Secret/service-role keys are always rejected.
  factory SupabaseClientConfig.resolve({
    required String url,
    required String anonKey,
    bool requireKnownKeyFormat = true,
  }) {
    final normalizedUrl = _normalizeUrl(url);
    final key = anonKey.trim();
    final issues = <SupabaseConfigIssue>[];

    if (normalizedUrl.isEmpty) {
      issues.add(SupabaseConfigIssue.missingUrl);
    } else {
      final urlIssue = _validateUrl(normalizedUrl);
      if (urlIssue != null) issues.add(urlIssue);
    }

    final claims = _jwtClaims(key);
    if (key.isEmpty) {
      issues.add(SupabaseConfigIssue.missingKey);
    } else if (key.startsWith('sb_secret_') ||
        claims?['role'] == 'service_role') {
      issues.add(SupabaseConfigIssue.secretKey);
    } else if (requireKnownKeyFormat && !_isKnownPublicKey(key, claims)) {
      issues.add(SupabaseConfigIssue.malformedKey);
    }

    final ref = claims?['ref'];
    final host = Uri.tryParse(normalizedUrl)?.host ?? '';
    if (ref is String &&
        ref.isNotEmpty &&
        host.endsWith('.supabase.co') &&
        host.split('.').first != ref) {
      issues.add(SupabaseConfigIssue.projectMismatch);
    }

    return SupabaseClientConfig._(
      url: normalizedUrl,
      anonKey: key,
      issues: issues,
    );
  }

  /// Chooses the configuration for a service: an explicit [config] wins;
  /// explicit [url]/[anonKey] overrides (tests with fake HTTP clients) are
  /// validated without the key-format check; otherwise [environment].
  factory SupabaseClientConfig.select({
    SupabaseClientConfig? config,
    String? url,
    String? anonKey,
  }) {
    if (config != null) return config;
    if (url == null && anonKey == null) return environment;
    return SupabaseClientConfig.resolve(
      url: url ?? SupabaseConfig.supabaseUrl,
      anonKey: anonKey ?? SupabaseConfig.supabaseAnonKey,
      requireKnownKeyFormat: false,
    );
  }

  /// Compile-time configuration, validated exactly once per app process.
  static final SupabaseClientConfig environment = SupabaseClientConfig.resolve(
    url: SupabaseConfig.supabaseUrl,
    anonKey: SupabaseConfig.supabaseAnonKey,
  );

  static const String urlDefine = 'SUPABASE_URL';
  static const String keyDefine = 'SUPABASE_ANON_KEY';

  /// Git-ignored local file accepted by `--dart-define-from-file`.
  static const String localDefinesFile = 'supabase.local.json';

  /// Project base URL without a trailing slash.
  final String url;

  /// Public anon/publishable key. Never log or display this value.
  final String anonKey;

  final List<SupabaseConfigIssue> issues;

  bool get isValid => issues.isEmpty;

  /// A non-secret description such as `sb_publishable_… (46 chars)`.
  String get redactedKey => redactKey(anonKey);

  static String redactKey(String key) {
    if (key.isEmpty) return '(missing)';
    for (final prefix in const ['sb_publishable_', 'sb_secret_']) {
      if (key.startsWith(prefix)) return '$prefix… (${key.length} chars)';
    }
    if (_jwtClaims(key) != null) return 'JWT … (${key.length} chars)';
    return '… (${key.length} chars)';
  }

  /// One sentence per issue. Never contains the key value.
  List<String> get issueDescriptions =>
      issues.map(describeIssue).toList(growable: false);

  static String describeIssue(SupabaseConfigIssue issue) {
    switch (issue) {
      case SupabaseConfigIssue.missingUrl:
        return '$urlDefine is empty.';
      case SupabaseConfigIssue.malformedUrl:
        return '$urlDefine must be the project base URL, for example '
            'https://<project-ref>.supabase.co, with no path such as '
            '/rest/v1 or /auth/v1, query string or credentials.';
      case SupabaseConfigIssue.insecureUrl:
        return '$urlDefine must use https (http is only allowed for a local '
            'Supabase stack on localhost, 127.0.0.1 or the Android emulator '
            'host 10.0.2.2).';
      case SupabaseConfigIssue.missingKey:
        return '$keyDefine is empty: the public anon/publishable key was not '
            'compiled into this build.';
      case SupabaseConfigIssue.malformedKey:
        return '$keyDefine is not a Supabase public key. Use the project '
            'publishable key (sb_publishable_…) or legacy anon key, not a '
            'placeholder.';
      case SupabaseConfigIssue.secretKey:
        return '$keyDefine contains a secret/service-role key. Only the public '
            'anon/publishable key may be used in the mobile app.';
      case SupabaseConfigIssue.projectMismatch:
        return '$keyDefine belongs to a different Supabase project than '
            '$urlDefine.';
    }
  }

  /// Developer-facing commands with placeholders only.
  static const String runCommandHint =
      'flutter run --dart-define-from-file=$localDefinesFile';
  static const String explicitDefinesHint =
      '--dart-define=$urlDefine=https://<project-ref>.supabase.co '
      '--dart-define=$keyDefine=<public anon/publishable key>';

  /// Actionable error for logs and the UI. Never contains the key value.
  String get errorMessage {
    if (isValid) return '';
    return 'Supabase authentication is not configured for this build. '
        '${issueDescriptions.join(' ')} '
        'Rebuild with the public values as Dart defines: $runCommandHint '
        '(or $explicitDefinesHint), and pass the same flags to every flutter '
        'build apk/appbundle/ipa/web command. Defines are compiled into the '
        'app: stop and relaunch after changing them (hot restart does not '
        'apply them), and builds started directly from Xcode or Gradle reuse '
        'the defines of the last flutter command.';
  }

  @override
  String toString() =>
      'SupabaseClientConfig(url: $url, key: $redactedKey, issues: '
      '${issues.map((issue) => issue.name).join(', ')})';

  static String _normalizeUrl(String raw) {
    var value = raw.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static SupabaseConfigIssue? _validateUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        value.contains(RegExp(r'\s'))) {
      return SupabaseConfigIssue.malformedUrl;
    }
    if (uri.scheme == 'http' && !_localHosts.contains(uri.host)) {
      return SupabaseConfigIssue.insecureUrl;
    }
    return null;
  }

  /// Local development hosts; 10.0.2.2 is the Android emulator's alias for
  /// the developer machine. Release Android builds block cleartext anyway.
  static const Set<String> _localHosts = {
    'localhost',
    '127.0.0.1',
    '::1',
    '10.0.2.2',
  };

  static const String _legacyPlaceholderKey =
      'ci-public-anon-key-for-build-only';

  static bool _isKnownPublicKey(String key, Map<String, Object?>? claims) {
    if (key == _legacyPlaceholderKey) return false;
    if (key.startsWith('sb_publishable_')) {
      return RegExp(r'^sb_publishable_[A-Za-z0-9_-]{10,}$').hasMatch(key);
    }
    return claims != null && claims['role'] == 'anon';
  }

  static Map<String, Object?>? _jwtClaims(String key) {
    final parts = key.split('.');
    if (parts.length != 3 || parts.any((part) => part.isEmpty)) return null;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
