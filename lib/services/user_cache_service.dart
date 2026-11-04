import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_profile.dart';

/// Encapsulates SharedPreferences-based caching for essential user profile data.
///
/// Stores only non-sensitive, display-oriented, role-determination fields:
///   - uid: Profile identifier (needed for cache key and API calls)
///   - name: Display name
///   - email: For email-based lookups and role validation
///   - role: client/lawyer/admin (essential for navigation)
///   - onboardingStatus: For lawyer validation
///
/// NEVER caches: password, avatar (large binary), phone, address, tokens.
/// These are fetched from Supabase on demand or from server-validated sources.
///
/// Serves as the first-read layer before hitting Supabase, reducing latency
/// and providing offline access to essential user data.
class UserCacheService {
  UserCacheService({
    SharedPreferences? preferences,
  }) : _prefs = preferences ??
            (throw ArgumentError.notNull('shared_preferences'));

  static const String _cachePrefix = 'user_cache_';
  static const List<String> _cachedFields = [
    'uid',
    'name',
    'email',
    'role',
    'onboardingStatus',
  ];

  final SharedPreferences _prefs;

  /// Cache key for a given user UID.
  String _keyFor(String uid) => '$_cachePrefix$uid';

  /// Returns the cached profile fields for [uid], or null if absent / expired.
  /// Only returns essential non-sensitive fields — never avatar or contact details.
  Map<String, dynamic>? get(String uid) {
    final json = _prefs.getString(_keyFor(uid));
    if (json == null) return null;
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      // Validate that required fields exist and are not sensitive.
      if (!map.containsKey('uid') || !map.containsKey('role')) {
        _prefs.remove(_keyFor(uid));
        return null;
      }
      return map;
    } on FormatException {
      // Stale cache entry — remove it.
      _prefs.remove(_keyFor(uid));
      return null;
    }
  }

  /// Persists essential profile fields under [uid]. Overwrites any prior entry.
  /// Only stores: uid, name, email, role, onboardingStatus.
  Future<void> set(String uid, Map<String, dynamic> profile) async {
    // Create a sanitized cache entry with only essential fields
    final cached = <String, dynamic>{};
    for (final key in _cachedFields) {
      final value = profile[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        cached[key] = value.toString().trim();
      }
    }
    // Always include uid as cache key
    if (!cached.containsKey('uid') && profile.containsKey('uid')) {
      cached['uid'] = profile['uid'];
    }
    final json = jsonEncode(cached);
    await _prefs.setString(_keyFor(uid), json);
  }

  /// Removes the cached profile for [uid].
  Future<void> clear(String uid) async {
    await _prefs.remove(_keyFor(uid));
  }

  /// Returns true if a cached profile exists for [uid].
  bool contains(String uid) => _prefs.containsKey(_keyFor(uid));
}
