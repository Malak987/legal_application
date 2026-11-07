import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/supabase_client_config.dart';
import '../config/supabase_config.dart';
import '../models/app_profile.dart';
import 'api_client.dart';
import 'user_cache_service.dart';

/// The signed-in Supabase Auth account. Its UUID is the canonical identity;
/// public profile fields and roles are always loaded from `public.users`.
class AuthUser {
  const AuthUser({required this.uid, this.email});

  final String uid;
  final String? email;

  String get emailOrEmpty => email ?? '';
}

/// A Supabase Auth failure with a safe message suitable for the UI.
class AuthException implements Exception {
  AuthException(this.message, {this.code, this.accountCreated = false});

  final String message;
  final String? code;

  /// The Auth account was created, but confirmation/profile/session setup is
  /// incomplete. The UI must not suggest that the user register again.
  final bool accountCreated;

  @override
  String toString() => message;
}

/// Secure persistence for the rotating Supabase refresh token.
///
/// Access tokens remain in memory only. Implementations used by tests should be
/// ephemeral; production uses the platform secure-storage/keychain facility.
abstract interface class AuthSessionStore {
  Future<String?> readRefreshToken();
  Future<void> writeRefreshToken(String token);
  Future<void> clear();
}

class SecureAuthSessionStore implements AuthSessionStore {
  SecureAuthSessionStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String _key = 'legal_supabase_refresh_token_v1';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> readRefreshToken() => _storage.read(key: _key);

  @override
  Future<void> writeRefreshToken(String token) =>
      _storage.write(key: _key, value: token);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// Storage for the PKCE `code_verifier` that must survive the gap between
/// `POST /auth/v1/signup` and the email-confirmation callback.
///
/// The verifier is a bearer-equivalent secret for the duration of the flow:
/// anybody who has it *and* the authorization code can exchange that code for
/// the user's session. It is therefore kept in the platform keystore rather
/// than `SharedPreferences`, and it is removed only after a successful token
/// exchange (or when a new signup supersedes it).
/// The narrow keystore surface [SecurePkceVerifierStore] needs.
///
/// Exists so the isolation logic can be exercised against an in-memory
/// implementation without mocking all of `flutter_secure_storage`.
abstract interface class PkceKeystore {
  Future<Map<String, String>> readAll();
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class _FlutterPkceKeystore implements PkceKeystore {
  const _FlutterPkceKeystore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// The authorization request a PKCE verifier belongs to.
///
/// Signup and password recovery are independent flows: a pending email
/// confirmation and a pending password reset must be able to coexist, because
/// neither can be completed without its own verifier.
enum PkceFlowPurpose { signup, recovery }

/// One pending authorization request and the verifier that completes it.
///
/// [id] is unique per [PkceVerifierStore.save] call, which is what makes
/// removal *ownership-conditional*: an operation can only ever delete the row
/// it created, never a newer one belonging to a different operation.
class PendingPkceFlow {
  const PendingPkceFlow({
    required this.id,
    required this.purpose,
    required this.verifier,
    this.createdAtMs = 0,
  });

  final String id;
  final PkceFlowPurpose purpose;

  /// The `code_verifier`. Empty when the stored value was corrupt or
  /// unreadable; such a flow is skipped rather than used as a guess.
  final String verifier;

  /// Ordering only: the newest flow is the most likely match for a callback.
  final int createdAtMs;

  bool get isUsable => verifier.isNotEmpty;

  @override
  String toString() =>
      'PendingPkceFlow(${purpose.name}, usable: $isUsable)'; // never the value
}

/// Storage for pending PKCE `code_verifier` values.
///
/// Contract, and why it is shaped this way:
///
/// * **One row per flow, never one shared slot.** A valid `code_verifier` is
///   bearer-equivalent for as long as its authorization code lives. Keeping
///   signup and recovery in separate rows means starting one flow cannot
///   destroy the other's ability to finish.
/// * **`save` returns the created row.** The caller keeps [PendingPkceFlow.id]
///   and rolls back with exactly that id, so a rollback can never overwrite a
///   newer flow written by another operation.
/// * **`remove` takes an id and is idempotent.** No "clear everything" verb is
///   exposed, so no code path can mass-delete another flow's verifier.
/// * **`readAll` may throw.** Callers must fail closed and never fabricate a
///   verifier when storage is unreadable.
abstract interface class PkceVerifierStore {
  /// Every pending flow, newest first. May throw if storage is unreadable.
  Future<List<PendingPkceFlow>> readAll();

  /// Persists [verifier] under a fresh unique id for [purpose].
  Future<PendingPkceFlow> save(PkceFlowPurpose purpose, String verifier);

  /// Removes exactly one flow. No-op when the id is already gone.
  Future<void> remove(String id);
}

/// Keystore-backed [PkceVerifierStore].
///
/// Each flow is a separate entry under [keyPrefix], so writers of different
/// flows never share a key and therefore cannot clobber each other — including
/// across processes. Values are JSON so the timestamp used for newest-first
/// ordering travels with the verifier.
///
/// Limitations (deliberate, see docs/AUTH_PKCE_ARCHITECTURE.md):
/// * No cross-process mutex. Instead, correctness comes from per-flow keys and
///   id-scoped removal, which are safe under concurrent writers.
/// * Per-purpose count is bounded ([maxFlowsPerPurpose]) so a device cannot
///   accumulate secrets indefinitely; the oldest flow of that purpose is
///   evicted. A verifier older than that many same-purpose requests may be
///   missing when its link is finally tapped.
/// * No TTL: a confirmation email may legitimately be opened days later.
class SecurePkceVerifierStore implements PkceVerifierStore {
  SecurePkceVerifierStore({PkceKeystore? keystore})
    : _storage = keystore ?? const _FlutterPkceKeystore();

  static const String keyPrefix = 'legal_supabase_pkce_v2';

  /// Pre-scoped single-slot key from the previous implementation. Read once so
  /// a device mid-flight across the upgrade can still finish its confirmation.
  static const String legacyKey = 'legal_supabase_pkce_verifier_v1';

  static const String legacyFlowId = 'legacy-v1';

  /// Oldest-evicting bound, per purpose.
  static const int maxFlowsPerPurpose = 5;

  final PkceKeystore _storage;

  static String _keyFor(PkceFlowPurpose purpose, String id) =>
      '$keyPrefix:${purpose.name}:$id';

  @override
  Future<List<PendingPkceFlow>> readAll() async {
    final all = await _storage.readAll();
    final flows = <PendingPkceFlow>[];

    for (final entry in all.entries) {
      if (!entry.key.startsWith('$keyPrefix:')) continue;
      final parts = entry.key.split(':');
      if (parts.length != 3) continue;
      final purpose = PkceFlowPurpose.values.firstWhere(
        (value) => value.name == parts[1],
        orElse: () => PkceFlowPurpose.signup,
      );
      final parsed = _decode(entry.value);
      flows.add(
        PendingPkceFlow(
          id: parts[2],
          purpose: purpose,
          verifier: parsed.verifier,
          createdAtMs: parsed.createdAtMs,
        ),
      );
    }

    // Adopt the pre-scoped slot as a signup flow so an upgrade does not strand
    // a confirmation that was already requested.
    final legacy = (all[legacyKey] ?? '').trim();
    if (legacy.isNotEmpty) {
      flows.add(
        PendingPkceFlow(
          id: legacyFlowId,
          purpose: PkceFlowPurpose.signup,
          verifier: legacy,
        ),
      );
    }

    flows.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return flows;
  }

  @override
  Future<PendingPkceFlow> save(
    PkceFlowPurpose purpose,
    String verifier,
  ) async {
    final flow = PendingPkceFlow(
      id: _randomId(),
      purpose: purpose,
      verifier: verifier,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _storage.write(
      _keyFor(purpose, flow.id),
      jsonEncode(<String, dynamic>{
        'verifier': verifier,
        'created_at': flow.createdAtMs,
      }),
    );
    await _prune(purpose);
    return flow;
  }

  @override
  Future<void> remove(String id) async {
    if (id == legacyFlowId || id.isEmpty) {
      // Also clear the legacy slot when it is the flow being consumed.
      await _storage.delete(legacyKey);
      return;
    }
    for (final purpose in PkceFlowPurpose.values) {
      await _storage.delete(_keyFor(purpose, id));
    }
  }

  /// Evicts the oldest flows of [purpose] beyond [maxFlowsPerPurpose].
  Future<void> _prune(PkceFlowPurpose purpose) async {
    final sameFlow = (await readAll())
        .where((flow) => flow.purpose == purpose && flow.id != legacyFlowId)
        .toList(growable: false);
    if (sameFlow.length <= maxFlowsPerPurpose) return;
    for (final flow in sameFlow.skip(maxFlowsPerPurpose)) {
      await _storage.delete(_keyFor(purpose, flow.id));
    }
  }

  static _DecodedVerifier _decode(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return const _DecodedVerifier('', 0);
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        final verifier = (decoded['verifier'] ?? '').toString().trim();
        final createdAt = int.tryParse('${decoded['created_at']}') ?? 0;
        return _DecodedVerifier(verifier, createdAt);
      }
    } catch (_) {
      // Not JSON: treat the whole value as the verifier (defensive).
    }
    return _DecodedVerifier(value, 0);
  }

  static final math.Random _idRandom = math.Random.secure();

  static String _randomId() {
    final bytes = Uint8List(9);
    for (var index = 0; index < bytes.length; index++) {
      bytes[index] = _idRandom.nextInt(256);
    }
    return base64Url.encode(bytes).replaceAll(RegExp(r'=+$'), '');
  }
}

class _DecodedVerifier {
  const _DecodedVerifier(this.verifier, this.createdAtMs);

  final String verifier;
  final int createdAtMs;
}


/// Auth operations used by the application/session controller.
abstract interface class AuthGateway {
  /// Emits explicit sign-in/sign-out changes. Implementations do not emit an
  /// initial `null`; startup restoration is performed by [restoreSession].
  Stream<AuthUser?> get authStateChanges;

  /// Emits whenever the usable access token or authenticated account changes,
  /// including silent refresh-token rotation. This stream is for clients such
  /// as Realtime that must refresh credentials without reloading the profile.
  Stream<AuthUser?> get sessionChanges;

  AuthUser? get currentUser;

  Future<AuthUser?> restoreSession({Uri? callbackUri});

  Future<AuthUser> signIn({required String email, required String password});

  /// Creates a public client account only. No role is accepted from the caller.
  Future<AuthUser> createAccount({
    required String email,
    required String password,
    String? displayName,
  });

  Future<void> requestPasswordReset({
    required String email,
    String? redirectTo,
  });

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  });

  /// Sets a new password after the Supabase recovery callback has established
  /// a short-lived recovery session.
  Future<void> setPasswordFromRecovery(String newPassword);

  Future<void> signOut();

  bool get isPasswordRecovery;
  void dispose();
}

/// Supabase Auth REST gateway with rotating, securely persisted refresh-token
/// sessions. Only the public anon/publishable key is accepted by this client.
class SupabaseAuthGateway implements AuthGateway {
  /// [config] is the startup-validated configuration shared with [ApiClient].
  /// [supabaseUrl]/[supabaseAnonKey] remain as test overrides.
  SupabaseAuthGateway({
    SupabaseClientConfig? config,
    http.Client? client,
    String? supabaseUrl,
    String? supabaseAnonKey,
    AuthSessionStore? sessionStore,
    PkceVerifierStore? pkceStore,
    String? authRedirectUrl,
    bool? allowClientSignup,
  }) : _client = client ?? http.Client(),
       _allowClientSignup =
           allowClientSignup ?? SupabaseConfig.enableClientSignup,
       _ownsClient = client == null,
       _config = SupabaseClientConfig.select(
         config: config,
         url: supabaseUrl,
         anonKey: supabaseAnonKey,
       ),
       _sessionStore = sessionStore ?? SecureAuthSessionStore(),
       // The PKCE verifier lives in the platform keystore, never in
       // SharedPreferences (world-readable on a rooted/unlocked device).
       _pkceStore = pkceStore ?? SecurePkceVerifierStore(),
       _authRedirectUrl =
           (authRedirectUrl ?? SupabaseConfig.authRedirectUrl).trim();

  static const Duration _requestTimeout = Duration(seconds: 20);
  static const Duration _refreshSkew = Duration(seconds: 60);

  final http.Client _client;
  final bool _allowClientSignup;
  final bool _ownsClient;
  final SupabaseClientConfig _config;
  final AuthSessionStore _sessionStore;
  final PkceVerifierStore _pkceStore;
  final String _authRedirectUrl;
  final StreamController<AuthUser?> _authController =
      StreamController<AuthUser?>.broadcast();
  final StreamController<AuthUser?> _sessionController =
      StreamController<AuthUser?>.broadcast();

  AuthUser? _currentUser;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _accessTokenExpiresAt;
  Future<void>? _refreshInFlight;
  String? _refreshInFlightToken;
  int? _refreshInFlightGeneration;
  Future<void> _sessionStoreQueue = Future<void>.value();
  int _sessionGeneration = 0;
  bool _isPasswordRecovery = false;
  bool _disposed = false;

  /// RFC 7636 §4.2 requires 43–128 chars from the unreserved set. 32 CSPRNG
  /// bytes base64url-encoded without padding is exactly 43 chars.
  static const int _pkceVerifierBytes = 32;

  /// Bounded memory of authorization codes already exchanged, so a duplicated
  /// deep-link delivery cannot trigger a second token exchange. Supabase
  /// authorization codes are single-use; the second exchange would fail and
  /// could otherwise tear down a healthy session.
  final LinkedHashSet<String> _consumedPkceCodes = LinkedHashSet<String>();
  static const int _maxTrackedCodes = 16;

  /// Generates a cryptographically secure PKCE `code_verifier`.
  ///
  /// One [math.Random.secure] source — the platform CSPRNG — produces every
  /// byte of the verifier; the generator is never re-seeded or re-created per
  /// byte, and no non-cryptographic fallback exists. The 32 bytes are
  /// base64url-encoded without padding, giving exactly 43 characters within
  /// RFC 7636's 43–128 window.
  static String _generatePkceVerifier() {
    final random = math.Random.secure();
    final bytes = Uint8List(_pkceVerifierBytes);
    for (var index = 0; index < bytes.length; index++) {
      bytes[index] = random.nextInt(256);
    }
    return _base64UrlNoPadding(bytes);
  }

  /// Derives the S256 `code_challenge` from the exact verifier:
  /// `BASE64URL(SHA256(ASCII(code_verifier)))`, no padding.
  static String _generatePkceChallenge(String codeVerifier) {
    final digestBytes = sha256.convert(utf8.encode(codeVerifier)).bytes;
    return _base64UrlNoPadding(digestBytes);
  }

  static String _base64UrlNoPadding(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll(RegExp(r'=+$'), '');

  /// Exposed for the PKCE contract tests only; production code derives the
  /// challenge inside [createAccount] from the verifier it just persisted.
  @visibleForTesting
  static String debugDerivePkceChallenge(String verifier) =>
      _generatePkceChallenge(verifier);

  @visibleForTesting
  static String debugGeneratePkceVerifier() => _generatePkceVerifier();

  /// The validated configuration used for every Auth request.
  SupabaseClientConfig get config => _config;

  bool get isConfigured => _config.isValid;

  String get _supabaseUrl => _config.url;
  String get _supabaseAnonKey => _config.anonKey;

  @override
  Stream<AuthUser?> get authStateChanges => _authController.stream;

  @override
  Stream<AuthUser?> get sessionChanges => _sessionController.stream;

  @override
  AuthUser? get currentUser => _currentUser;

  @override
  bool get isPasswordRecovery => _isPasswordRecovery;

  /// Current bearer token, refreshed before expiry or on an explicit 401 retry.
  ///
  /// [staleToken] is the token a request already sent when the server rejected
  /// it with `401`. It is what makes the retry path concurrency-safe:
  ///
  /// * if the session already holds a *different* token, another in-flight
  ///   request refreshed it first and that token is returned as-is;
  /// * otherwise the refresh is performed through [_refreshSession], which
  ///   shares one in-flight request per (refresh token, session generation),
  ///   so simultaneous 401s rotate the refresh token exactly once.
  ///
  /// Without this, two parallel requests could each rotate a rotating refresh
  /// token; Supabase accepts a replayed token only for its short reuse window,
  /// after which the losing request signs the whole session out.
  Future<String?> getAccessToken({
    bool forceRefresh = false,
    String? staleToken,
  }) async {
    final current = _accessToken;
    final alreadyRefreshed =
        staleToken != null &&
        staleToken.isNotEmpty &&
        current != null &&
        current != staleToken;
    if (forceRefresh && alreadyRefreshed) return current;

    final expiresAt = _accessTokenExpiresAt;
    final stillFresh =
        _accessToken != null &&
        (expiresAt == null ||
            DateTime.now().add(_refreshSkew).isBefore(expiresAt));
    if (!forceRefresh && stillFresh) return _accessToken;

    final generation = _sessionGeneration;
    final refreshToken =
        _refreshToken ?? await _sessionStore.readRefreshToken();
    if (generation != _sessionGeneration) return _accessToken;
    if (refreshToken == null || refreshToken.isEmpty) return _accessToken;

    try {
      await _refreshSession(refreshToken, expectedGeneration: generation);
    } on AuthException catch (error) {
      if (generation == _sessionGeneration && _isInvalidRefreshToken(error)) {
        await _clearSession(notify: true);
      }
      // Preserve the last access token on transient network/server errors. The
      // caller's request may still succeed; a 401 retry can force another try.
    } catch (_) {
      // A secure-storage/network plugin error must not crash a widget build.
    }
    return _accessToken;
  }

  @override
  Future<AuthUser?> restoreSession({Uri? callbackUri}) async {
    _ensureConfigured();
    if (callbackUri != null) {
      final callbackUser = await _restoreCallbackSession(callbackUri);
      if (callbackUser != null) return callbackUser;
    }

    if (_currentUser != null) return _currentUser;
    final generation = _sessionGeneration;
    final storedRefreshToken = await _sessionStore.readRefreshToken();
    if (generation != _sessionGeneration) return _currentUser;
    if (storedRefreshToken == null || storedRefreshToken.isEmpty) return null;

    try {
      await _refreshSession(storedRefreshToken, expectedGeneration: generation);
      return _currentUser;
    } on AuthException catch (error) {
      if (_isInvalidRefreshToken(error)) {
        await _clearSession(notify: true);
        return null;
      }
      rethrow;
    }
  }

  Future<AuthUser?> _restoreCallbackSession(Uri callbackUri) async {
    final callback = <String, String>{...callbackUri.queryParameters};
    if (callbackUri.fragment.isNotEmpty) {
      Map<String, String> fragment;
      try {
        fragment = Uri.splitQueryString(callbackUri.fragment);
      } catch (_) {
        throw _invalidRecoveryLink();
      }
      for (final entry in fragment.entries) {
        // Query parameters win: the verifier link puts the real outcome in
        // the query string, and a stale fragment must not overwrite it.
        callback.putIfAbsent(entry.key, () => entry.value);
      }
    }

    final type = (callback['type'] ?? '').toLowerCase();

    // Lawyer invitations are accepted on the web dashboard only. If an invite
    // link is ever delivered to the app, ignore it here so the browser can
    // handle activation; the app never establishes an invitation session.
    if (type == 'invite') return null;

    if (!_matchesConfiguredRedirect(callbackUri)) return null;

    // Do not let a cached callback mode authorize a malformed or superseding
    // callback while this callback is being validated.
    _isPasswordRecovery = false;

    // Supabase returns error details in callback parameters for expired,
    // reused, or otherwise invalid links. Never surface the raw URL or tokens.
    if ((callback['error_code'] ?? callback['error'] ?? '').isNotEmpty) {
      throw _invalidRecoveryLink();
    }

    final accessToken = (callback['access_token'] ?? '').trim();
    final refreshToken = (callback['refresh_token'] ?? '').trim();

    // PKCE flow: an email-confirmation / magic-link callback carries a `code`
    // and no tokens. Exchange it before anything else looks at the tokens.
    final code = (callback['code'] ?? '').trim();
    if (code.isNotEmpty && (accessToken.isEmpty || refreshToken.isEmpty)) {
      return _handlePkceCode(code, callbackUri, isRecovery: type == 'recovery');
    }

    if (accessToken.isEmpty || refreshToken.isEmpty) {
      // Only a recovery link is expected to carry implicit tokens. An email
      // confirmation that lost its `code` is a broken link, and telling the
      // user to "request a new password-reset link" would be misleading.
      throw type == 'recovery' ? _invalidRecoveryLink() : _invalidPkceLink();
    }
    final expiresIn = int.tryParse(callback['expires_in'] ?? '');
    final expiresAt = int.tryParse(callback['expires_at'] ?? '');
    if ((expiresIn != null && expiresIn <= 0) ||
        (expiresAt != null &&
            expiresAt <= DateTime.now().millisecondsSinceEpoch ~/ 1000) ||
        _jwtIsExpired(accessToken)) {
      throw _invalidRecoveryLink();
    }

    final sessionGeneration = ++_sessionGeneration;
    final response = await _send(
      'GET',
      _authUri('user'),
      bearerToken: accessToken,
    );
    if (sessionGeneration != _sessionGeneration) {
      throw _supersededSessionOperation();
    }
    final decoded = _decodeJson(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 400 ||
          response.statusCode == 401 ||
          response.statusCode == 403) {
        throw _invalidRecoveryLink();
      }
      throw _mapSupabaseError(decoded, response.statusCode);
    }

    final user = _extractUser(decoded);
    _isPasswordRecovery = type == 'recovery';
    return _installSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: user,
      expiresIn: expiresIn,
      emit: true,
      persistenceRequired: true,
      accountCreated: false,
      expectedGeneration: sessionGeneration,
    );
  }

  /// Exchanges an email-confirmation / magic-link `code` for a session.
  ///
  /// Supabase's PKCE grant is `POST /auth/v1/token?grant_type=pkce` with the
  /// JSON body `{"auth_code": <code>, "code_verifier": <verifier>}`. Both are
  /// required; GoTrue answers 400
  /// `both auth code and code verifier should be non-empty` when either is
  /// missing. The verifier must be the *same* value that produced the
  /// `code_challenge` sent with `POST /auth/v1/signup`.
  Future<AuthUser?> _handlePkceCode(
    String code,
    Uri callbackUri, {
    bool isRecovery = false,
  }) async {
    _ensureConfigured();

    // A repeated delivery of the same link (warm-start + cold-start, or a
    // double tap in the browser) must not attempt a second exchange: the
    // authorization code is single-use, and the second attempt would either
    // fail loudly or needlessly destroy a session that already succeeded.
    if (_consumedPkceCodes.contains(code)) {
      return _currentUser;
    }

    final sessionGeneration = ++_sessionGeneration;

    // Pick the verifier that belongs to THIS flow. A callback's `type` tells
    // us which; without one we accept either purpose, newest first, because
    // Supabase does not always label confirmation callbacks.
    final PendingPkceFlow flow;
    try {
      final pending = await _pkceStore.readAll();
      final expected =
          isRecovery ? PkceFlowPurpose.recovery : PkceFlowPurpose.signup;
      final matching = pending
          .where((candidate) => candidate.isUsable)
          .toList(growable: false);
      // Prefer the flow purpose implied by the callback, then any usable flow
      // (oldest links may predate a purpose change on the server side).
      flow = matching.firstWhere(
        (candidate) => candidate.purpose == expected,
        orElse:
            () => matching.isEmpty
                ? const PendingPkceFlow(
                  id: '',
                  purpose: PkceFlowPurpose.signup,
                  verifier: '',
                )
                : matching.first,
      );
    } catch (_) {
      // Storage could be unavailable (device locked, keystore reset). The
      // exchange cannot proceed, but the session state is untouched.
      throw _invalidPkceLink();
    }
    if (sessionGeneration != _sessionGeneration) {
      throw _supersededSessionOperation();
    }
    if (!flow.isUsable) {
      // No verifier: the user registered on another device, cleared app data,
      // or the link is forged/expired. Never exchange without it.
      throw _invalidPkceLink();
    }
    final storedVerifier = flow.verifier;

    final response = await _send(
      'POST',
      _authUri('token', const <String, String>{'grant_type': 'pkce'}),
      body: <String, dynamic>{
        'auth_code': code,
        'code_verifier': storedVerifier,
      },
    );
    if (sessionGeneration != _sessionGeneration) {
      throw _supersededSessionOperation();
    }
    final decoded = _decodeJson(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 400 ||
          response.statusCode == 401 ||
          response.statusCode == 403) {
        // Expired (default 5 minute window), reused, or verifier mismatch.
        // The verifier is deliberately kept: a transient server rejection must
        // not destroy a flow the user may still complete.
        throw _invalidPkceLink();
      }
      throw _mapSupabaseError(decoded, response.statusCode);
    }
    final accessToken = (decoded['access_token'] ?? '').toString().trim();
    final refreshToken = (decoded['refresh_token'] ?? '').toString().trim();
    if (accessToken.isEmpty || refreshToken.isEmpty) {
      throw _invalidPkceLink();
    }
    final expiresIn = int.tryParse((decoded['expires_in'] ?? '').toString());
    final user = _extractUser(decoded);
    // A PKCE recovery callback must land on the reset-password screen; an
    // email-confirmation / magic-link callback must not.
    _isPasswordRecovery = isRecovery;

    // Install first, then forget the verifier: clearing it before the session
    // is durable would make a transient install failure unrecoverable. If the
    // install fails the verifier is kept, so the user can retry.
    final AuthUser installed;
    try {
      installed = await _installSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: user,
      expiresIn: expiresIn,
      emit: true,
      persistenceRequired: true,
        accountCreated: false,
        expectedGeneration: sessionGeneration,
      );
    } on AuthException {
      // Session could not be persisted (e.g. keystore failure). Keep the
      // verifier: it is the only way to complete this flow later.
      rethrow;
    }

    _rememberConsumedCode(code);
    try {
      // Only this flow's row: a concurrent pending flow keeps its verifier.
      await _pkceStore.remove(flow.id);
    } catch (_) {
      // A leftover verifier is harmless once its authorization code has been
      // consumed, and it is bounded by the store's eviction policy.
    }
    return installed;
  }

  /// Abandons exactly the flow this operation created, and nothing else.
  ///
  /// This replaces the previous "restore the old verifier" rollback, which was
  /// unsafe: writing a remembered value back could overwrite a *newer* flow
  /// created by another operation while this one was in flight. Because each
  /// flow owns its own storage row, discarding by id is inherently
  /// ownership-conditional — no read-compare-write window exists, and it is
  /// safe across processes.
  ///
  /// Best effort: the caller is already reporting the original failure, and a
  /// rollback error must not replace it.
  Future<void> _discardFlow(PendingPkceFlow flow) async {
    try {
      await _pkceStore.remove(flow.id);
    } catch (_) {}
  }

  void _rememberConsumedCode(String code) {
    if (code.isEmpty) return;
    _consumedPkceCodes.add(code);
    while (_consumedPkceCodes.length > _maxTrackedCodes) {
      _consumedPkceCodes.remove(_consumedPkceCodes.first);
    }
  }

  AuthException _invalidPkceLink() => AuthException(
    'This email-confirmation link is invalid or has expired. Request a new link.',
    code: 'invalid-pkce-link',
  );

  bool _matchesConfiguredRedirect(Uri callbackUri) {
    final expected = Uri.tryParse(_authRedirectUrl);
    return expected != null &&
        expected.hasScheme &&
        callbackUri.scheme == expected.scheme &&
        callbackUri.host == expected.host &&
        callbackUri.port == expected.port &&
        callbackUri.path == expected.path;
  }

  int? _jwtExpirySeconds(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final exp = (jsonDecode(payload) as Map<String, dynamic>)['exp'];
      return exp is int ? exp : int.tryParse('$exp');
    } catch (_) {
      return null;
    }
  }

  bool _jwtIsExpired(String token) {
    final expiry = _jwtExpirySeconds(token);
    return expiry != null &&
        expiry <= DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  AuthException _invalidRecoveryLink() => AuthException(
    'This password-reset link is invalid or has expired. Request a new link.',
    code: 'invalid-recovery-link',
  );

  @override
  Future<AuthUser> signIn({
    required String email,
    required String password,
  }) async {
    _ensureConfigured();
    final sessionGeneration = ++_sessionGeneration;
    final response = await _send(
      'POST',
      _authUri('token', const <String, String>{'grant_type': 'password'}),
      body: <String, dynamic>{'email': email.trim(), 'password': password},
    );
    if (sessionGeneration != _sessionGeneration) {
      throw _supersededSessionOperation();
    }
    final decoded = _decodeJson(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _mapSupabaseError(decoded, response.statusCode);
    }
    _isPasswordRecovery = false;
    return _installTokenResponse(
      decoded,
      fallbackEmail: email.trim(),
      emit: true,
      persistenceRequired: true,
      accountCreated: false,
      expectedGeneration: sessionGeneration,
    );
  }

  @override
  Future<AuthUser> createAccount({
    required String email,
    required String password,
    String? displayName,
  }) async {
    _ensureConfigured();
    if (!_allowClientSignup) {
      throw AuthException(
        'Client registration is paused until secure profile linking is deployed and verified.',
        code: 'signup-not-enabled',
      );
    }
    final redirect = _authRedirectUrl;
    if (redirect.isEmpty) {
      throw AuthException(
        'Email confirmation is enabled, but this build has no allowed auth redirect. Configure SUPABASE_AUTH_REDIRECT_URL and the project redirect allow-list before registering.',
        code: 'auth-redirect-not-configured',
      );
    }
    final sessionGeneration = ++_sessionGeneration;

    // PKCE: generate the verifier, derive the S256 challenge from that exact
    // verifier, and persist the verifier BEFORE the signup request. If the
    // verifier cannot be persisted, signup must not happen — otherwise the
    // confirmation link arrives with no way to complete the exchange and the
    // account is stranded unconfirmed.
    final codeVerifier = _generatePkceVerifier();
    final codeChallenge = _generatePkceChallenge(codeVerifier);
    final PendingPkceFlow flow;
    try {
      // A brand-new row, owned by this call. No other flow's verifier is
      // read, replaced, or removed here — starting a signup cannot break a
      // pending password reset (or an earlier confirmation).
      flow = await _pkceStore.save(PkceFlowPurpose.signup, codeVerifier);
      final stored = await _pkceStore.readAll();
      final mine = stored.where((candidate) => candidate.id == flow.id);
      if (mine.isEmpty || mine.first.verifier != codeVerifier) {
        await _discardFlow(flow);
        throw const FormatException('PKCE verifier did not persist.');
      }
    } catch (_) {
      throw AuthException(
        'Secure storage is unavailable, so email confirmation cannot be completed on this device. Please retry, or free up storage and try again.',
        code: 'pkce-storage-failed',
      );
    }

    final response = await _send(
      'POST',
      _authUri(
        'signup',
        redirect.isEmpty ? null : <String, String>{'redirect_to': redirect},
      ),
      body: <String, dynamic>{
        'email': email.trim(),
        'password': password,
        // This is untrusted profile display data only. The client sends no role;
        // the trusted database Auth lifecycle creates the fixed `client` role.
        'data': <String, dynamic>{
          if (displayName?.trim().isNotEmpty == true)
            'name': displayName!.trim(),
        },
        // PKCE parameters:
        'code_challenge': codeChallenge,
        'code_challenge_method': 's256',
      },
    );

    if (sessionGeneration != _sessionGeneration) {
      // Another auth operation superseded this one; this flow cannot complete.
      await _discardFlow(flow);
      throw _supersededSessionOperation();
    }
    final decoded = _decodeJson(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // The account was not created, so this flow will never receive a
      // callback: discard exactly this row. Untouched flows (another signup,
      // a pending recovery) keep their verifiers.
      await _discardFlow(flow);
      throw _mapSupabaseError(decoded, response.statusCode);
    }

    final accessToken = (decoded['access_token'] ?? '').toString().trim();
    final refreshToken = (decoded['refresh_token'] ?? '').toString().trim();
    if (accessToken.isEmpty || refreshToken.isEmpty) {
      // Supabase is configured to require email confirmation. A user object may
      // be returned, but without a session the app must not enter protected UI.
      // This IS a live pending confirmation, so the new verifier stays.
      await _clearSession(notify: true);
      throw AuthException(
        'Your account was created. Check your email to confirm it, then sign in.',
        code: 'email-confirmation-required',
        accountCreated: true,
      );
    }

    _isPasswordRecovery = false;
    return _installTokenResponse(
      decoded,
      fallbackEmail: email.trim(),
      emit: true,
      persistenceRequired: true,
      accountCreated: true,
      expectedGeneration: sessionGeneration,
    );
  }

  @override
  Future<void> requestPasswordReset({
    required String email,
    String? redirectTo,
  }) async {
    _ensureConfigured();
    final redirect = (redirectTo ?? _authRedirectUrl).trim();
    if (redirect.isEmpty) {
      throw AuthException(
        'Password recovery is not configured for this build. Set SUPABASE_AUTH_REDIRECT_URL and allow it in the Supabase Auth settings.',
        code: 'auth-redirect-not-configured',
      );
    }
    // The recovery link is delivered as a PKCE callback (`?code=…`). Without a
    // stored verifier the app could not exchange it, so the same
    // persist-before-send rule as signup applies.
    final codeVerifier = _generatePkceVerifier();
    final codeChallenge = _generatePkceChallenge(codeVerifier);
    final PendingPkceFlow flow;
    try {
      // Recovery gets its own row, so requesting a reset never destroys a
      // pending signup confirmation (and vice versa).
      flow = await _pkceStore.save(PkceFlowPurpose.recovery, codeVerifier);
    } catch (_) {
      throw AuthException(
        'Secure storage is unavailable, so the password-reset link cannot be completed on this device. Please retry.',
        code: 'pkce-storage-failed',
      );
    }

    final response = await _send(
      'POST',
      _authUri(
        'recover',
        redirect.isEmpty ? null : <String, String>{'redirect_to': redirect},
      ),
      body: <String, dynamic>{
        'email': email.trim(),
        'code_challenge': codeChallenge,
        'code_challenge_method': 's256',
      },
    );
    final decoded = _decodeJson(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // No recovery email was sent, so this flow will never be completed.
      await _discardFlow(flow);
      throw _mapSupabaseError(decoded, response.statusCode);
    }
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _currentUser;
    if (user == null) throw AuthException('You are not signed in.');
    final email = user.email;
    if (email == null || email.isEmpty) {
      throw AuthException('This account has no email address.');
    }

    // Supabase Auth does not expose Firebase-style reauthenticate. A fresh
    // password grant is the reauthentication step and rotates this session.
    await signIn(email: email, password: currentPassword);
    await _putPassword(newPassword);
  }

  @override
  Future<void> setPasswordFromRecovery(String newPassword) async {
    if (!_isPasswordRecovery || _currentUser == null) {
      throw AuthException(
        'Open the password-reset link from your email first.',
      );
    }
    await _putPassword(newPassword);
    _isPasswordRecovery = false;
  }

  Future<void> _putPassword(String newPassword) async {
    final token = await getAccessToken();
    if (token == null || token.isEmpty) {
      throw AuthException(
        'Your session expired. Request a new password-reset link.',
      );
    }
    final response = await _send(
      'PUT',
      _authUri('user'),
      bearerToken: token,
      body: <String, dynamic>{'password': newPassword},
    );
    final decoded = _decodeJson(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _mapSupabaseError(decoded, response.statusCode);
    }
  }

  Future<AuthUser> _installTokenResponse(
    Map<String, dynamic> response, {
    required String fallbackEmail,
    required bool emit,
    required bool persistenceRequired,
    required bool accountCreated,
    int? expectedGeneration,
  }) async {
    final accessToken = (response['access_token'] ?? '').toString().trim();
    final refreshToken = (response['refresh_token'] ?? '').toString().trim();
    if (accessToken.isEmpty || refreshToken.isEmpty) {
      throw AuthException(
        'Authentication failed: no active session was returned.',
      );
    }
    final user = _extractUser(response, fallbackEmail: fallbackEmail);
    return _installSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: user,
      expiresIn: int.tryParse((response['expires_in'] ?? '').toString()),
      emit: emit,
      persistenceRequired: persistenceRequired,
      accountCreated: accountCreated,
      expectedGeneration: expectedGeneration,
    );
  }

  Future<void> _enqueueSessionStoreMutation(Future<void> Function() mutation) {
    final completed = Completer<void>();
    _sessionStoreQueue = _sessionStoreQueue.then((_) async {
      try {
        await mutation();
        completed.complete();
      } catch (error, stackTrace) {
        completed.completeError(error, stackTrace);
      }
    });
    return completed.future;
  }

  AuthException _supersededSessionOperation() => AuthException(
    'This authentication attempt was superseded. Please retry.',
    code: 'session-operation-superseded',
  );

  Future<AuthUser> _installSession({
    required String accessToken,
    required String refreshToken,
    required AuthUser user,
    required bool emit,
    required bool persistenceRequired,
    required bool accountCreated,
    int? expiresIn,
    int? expectedGeneration,
    bool emitSessionChange = true,
  }) async {
    final generation = expectedGeneration ?? _sessionGeneration;
    if (generation != _sessionGeneration) {
      throw _supersededSessionOperation();
    }

    try {
      await _enqueueSessionStoreMutation(
        () => _sessionStore.writeRefreshToken(refreshToken),
      );
    } catch (_) {
      if (persistenceRequired) {
        await _bestEffortLogout(accessToken);
        await _clearSession(notify: false);
        throw AuthException(
          'Could not securely save this session on the device. Please retry.',
          code: 'session-storage-failed',
          accountCreated: accountCreated,
        );
      }
    }

    // Sign-out or another account operation may have superseded the storage
    // write. Store mutations are serialized so the winning operation's token
    // cannot be overwritten by this late response.
    if (generation != _sessionGeneration) {
      throw _supersededSessionOperation();
    }

    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _currentUser = user;
    _accessTokenExpiresAt =
        expiresIn == null
            ? null
            : DateTime.now().add(Duration(seconds: expiresIn));
    _sessionGeneration++;
    if (emit && !_authController.isClosed) _authController.add(user);
    if (emitSessionChange && !_sessionController.isClosed) {
      _sessionController.add(user);
    }
    return user;
  }

  Future<void> _refreshSession(String refreshToken, {int? expectedGeneration}) {
    final generation = expectedGeneration ?? _sessionGeneration;
    if (generation != _sessionGeneration) return Future<void>.value();

    final existing = _refreshInFlight;
    if (existing != null &&
        _refreshInFlightToken == refreshToken &&
        _refreshInFlightGeneration == generation) {
      return existing;
    }

    final pending = _performRefresh(refreshToken, generation);
    _refreshInFlight = pending;
    _refreshInFlightToken = refreshToken;
    _refreshInFlightGeneration = generation;
    return pending.whenComplete(() {
      if (identical(_refreshInFlight, pending)) {
        _refreshInFlight = null;
        _refreshInFlightToken = null;
        _refreshInFlightGeneration = null;
      }
    });
  }

  Future<void> _performRefresh(
    String refreshToken,
    int expectedGeneration,
  ) async {
    _ensureConfigured();
    final previousUser = _currentUser;
    final response = await _send(
      'POST',
      _authUri('token', const <String, String>{'grant_type': 'refresh_token'}),
      body: <String, dynamic>{'refresh_token': refreshToken},
    );
    if (expectedGeneration != _sessionGeneration) return;

    final decoded = _decodeJson(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _mapSupabaseError(decoded, response.statusCode);
    }

    final accessToken = (decoded['access_token'] ?? '').toString().trim();
    final rotatedRefreshToken =
        (decoded['refresh_token'] ?? '').toString().trim();
    if (accessToken.isEmpty || rotatedRefreshToken.isEmpty) {
      throw AuthException(
        'Authentication failed: no active session was returned.',
      );
    }
    final renewedUser = _extractUser(
      decoded,
      fallbackEmail: previousUser?.email ?? '',
    );
    if (previousUser != null && previousUser.uid != renewedUser.uid) {
      if (expectedGeneration == _sessionGeneration) {
        await _clearSession(notify: true);
      }
      throw AuthException(
        'The refreshed session belongs to a different account.',
      );
    }

    await _installSession(
      accessToken: accessToken,
      refreshToken: rotatedRefreshToken,
      user: renewedUser,
      expiresIn: int.tryParse((decoded['expires_in'] ?? '').toString()),
      emit: false,
      emitSessionChange: true,
      persistenceRequired: false,
      accountCreated: false,
      expectedGeneration: expectedGeneration,
    );
  }

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Object? body,
    String? bearerToken,
  }) async {
    final request = http.Request(method, uri)
      ..headers.addAll(<String, String>{
        'apikey': _supabaseAnonKey,
        'Content-Type': 'application/json',
        if (bearerToken != null && bearerToken.isNotEmpty)
          'Authorization': 'Bearer $bearerToken',
      });
    if (body != null) request.body = jsonEncode(body);

    try {
      final streamed = await _client.send(request).timeout(_requestTimeout);
      return await http.Response.fromStream(streamed).timeout(_requestTimeout);
    } on TimeoutException {
      throw AuthException(
        'The authentication service took too long to respond. Try again.',
        code: 'network-request-failed',
      );
    } on AuthException {
      rethrow;
    } catch (_) {
      throw AuthException(
        'Network error. Check your connection and try again.',
        code: 'network-request-failed',
      );
    }
  }

  Future<void> _bestEffortLogout(String token) async {
    try {
      await _send('POST', _authUri('logout'), bearerToken: token);
    } catch (_) {}
  }

  Future<void> _clearSession({required bool notify}) async {
    _sessionGeneration++;
    _currentUser = null;
    _accessToken = null;
    _refreshToken = null;
    _accessTokenExpiresAt = null;
    _isPasswordRecovery = false;
    if (notify && !_authController.isClosed) _authController.add(null);
    if (!_sessionController.isClosed) _sessionController.add(null);
    try {
      await _enqueueSessionStoreMutation(_sessionStore.clear);
    } catch (_) {}
  }

  bool _isInvalidRefreshToken(AuthException error) {
    final code = (error.code ?? '').toLowerCase();
    final message = error.message.toLowerCase();
    return code.contains('invalid_grant') ||
        code.contains('refresh_token_not_found') ||
        message.contains('invalid refresh token') ||
        message.contains('refresh token not found');
  }

  void _ensureConfigured() {
    if (!_config.isValid) {
      throw AuthException(_config.errorMessage, code: 'auth-not-configured');
    }
  }

  Uri _authUri(String path, [Map<String, String>? query]) {
    final base =
        _supabaseUrl.endsWith('/')
            ? _supabaseUrl.substring(0, _supabaseUrl.length - 1)
            : _supabaseUrl;
    final clean = path.startsWith('/') ? path.substring(1) : path;
    return Uri.parse(
      '$base/auth/v1/$clean',
    ).replace(queryParameters: query == null || query.isEmpty ? null : query);
  }

  static Map<String, dynamic> _decodeJson(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map) return Map<String, dynamic>.from(parsed);
    } catch (_) {}
    return <String, dynamic>{};
  }

  static AuthUser _extractUser(
    Map<String, dynamic> response, {
    String fallbackEmail = '',
  }) {
    final rawUser = response['user'] is Map ? response['user'] : response;
    final user = Map<String, dynamic>.from(rawUser as Map);
    final uid = (user['id'] ?? '').toString().trim();
    if (uid.isEmpty) {
      throw AuthException('Authentication failed: no user id returned.');
    }
    final email = (user['email'] ?? fallbackEmail).toString().trim();
    return AuthUser(uid: uid, email: email.isEmpty ? null : email);
  }

  static AuthException _mapSupabaseError(
    Map<String, dynamic> body,
    int statusCode,
  ) {
    final code =
        (body['error_code'] ?? body['code'] ?? body['error'] ?? '')
            .toString()
            .toLowerCase();
    final message =
        (body['msg'] ?? body['error_description'] ?? body['message'] ?? '')
            .toString();
    final combined = '$code ${message.toLowerCase()}';

    if (combined.contains('user_already_exists') ||
        combined.contains('already registered') ||
        combined.contains('already exists')) {
      return AuthException(
        'An account with this email already exists. Try signing in.',
        code: 'email-already-in-use',
      );
    }
    if (combined.contains('invalid_credentials') ||
        combined.contains('invalid login credentials')) {
      return AuthException(
        'Incorrect email or password.',
        code: 'invalid-credential',
      );
    }
    if (combined.contains('weak_password') ||
        combined.contains('password should be at least')) {
      return AuthException(
        'Choose a stronger password (at least 8 characters).',
        code: 'weak-password',
      );
    }
    if (combined.contains('invalid email') ||
        combined.contains('email address is invalid')) {
      return AuthException(
        'Please enter a valid email address.',
        code: 'invalid-email',
      );
    }
    if (combined.contains('refresh token') &&
        (combined.contains('invalid') || combined.contains('not found'))) {
      return AuthException(
        'This session has expired. Please sign in again.',
        code: 'refresh_token_not_found',
      );
    }
    if (statusCode == 429 || combined.contains('over_request_rate_limit')) {
      return AuthException(
        'Too many attempts. Please wait a moment and try again.',
        code: 'too-many-requests',
      );
    }
    if (combined.contains('email_not_confirmed') ||
        combined.contains('email not confirmed')) {
      return AuthException(
        'Confirm your email before signing in.',
        code: 'email-not-confirmed',
      );
    }
    // Unknown backend messages may contain implementation details. Do not
    // expose them in UI errors, even if Supabase included a message field.
    return AuthException(
      'Authentication failed. Please try again.',
      code: code.isEmpty ? null : code,
    );
  }

  @override
  Future<void> signOut() async {
    final token = _accessToken;
    await _clearSession(notify: true);
    if (token != null && token.isNotEmpty && _config.isValid) {
      try {
        await _send('POST', _authUri('logout'), bearerToken: token);
      } catch (_) {
        // Local and secure-storage state is already cleared.
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _authController.close();
    _sessionController.close();
    if (_ownsClient) _client.close();
  }
}

/// Supabase-only sign-in, registration and profile loading rules.
class AuthService {
  AuthService({
    required this.gateway,
    required this.api,
    UserCacheService? userCache,
  }) : _userCache = userCache;

  final AuthGateway gateway;
  final ApiClient api;
  final UserCacheService? _userCache;

  Stream<AuthUser?> get authStateChanges => gateway.authStateChanges;
  Stream<AuthUser?> get sessionChanges => gateway.sessionChanges;
  AuthUser? get currentUser => gateway.currentUser;
  bool get isPasswordRecovery => gateway.isPasswordRecovery;

  /// Restores a persisted Supabase session and, when possible, consumes the
  /// callback URI supplied by the web URL or native app-link stream.
  Future<AuthUser?> restoreSession({Uri? callbackUri}) => gateway
      .restoreSession(callbackUri: callbackUri ?? (kIsWeb ? Uri.base : null));

  /// Returns the cached profile for [uid] as an [AppProfile], or null if absent.
  AppProfile? getCachedProfile(String uid) {
    final map = _userCache?.get(uid);
    if (map == null) return null;
    return AppProfile.fromJson(map);
  }

  /// Saves essential profile fields to the local cache.
  ///
  /// Only non-sensitive display and role fields are persisted; avatar, phone,
  /// address, and tokens are intentionally omitted.
  void _cacheProfile(AppProfile profile) {
    if (_userCache != null && profile.uid.trim().isNotEmpty) {
      final map = <String, dynamic>{
        'uid': profile.uid,
        'name': profile.name,
        'email': profile.email,
        'role': profile.role,
        'onboardingStatus': profile.onboardingStatus,
      };
      _userCache.set(profile.uid, map);
    }
  }

  /// Public alias used by [SessionController] to update the cache after a
  /// profile refresh or edit. Delegates to [_cacheProfile].
  void cacheProfile(AppProfile profile) => _cacheProfile(profile);

  /// Removes the cached profile for [uid]. Called by [SessionController]
  /// during sign-out so the next user sees a clean state.
  Future<void> clearCachedProfile(String uid) =>
      _userCache?.clear(uid) ?? Future.value();

  Future<AppProfile> signIn({
    required String email,
    required String password,
  }) async {
    await gateway.signIn(email: email, password: password);
    final profile = await loadProfile();
    _cacheProfile(profile);
    return profile;
  }

  /// Creates a public client account only. The role is never supplied by the
  /// UI or Auth user metadata; a trusted server/database flow must provision it.
  Future<AppProfile> register({
    required String name,
    required String email,
    required String password,
  }) async {
    await gateway.createAccount(
      email: email,
      password: password,
      displayName: name.trim(),
    );

    final user = gateway.currentUser;
    if (user == null) {
      throw AuthException(
        'Your account was created. Confirm your email before signing in.',
        code: 'email-confirmation-required',
        accountCreated: true,
      );
    }
    try {
      final profile = await loadProfile();
      // Registration must not silently accept an old, privileged, or wrongly
      // provisioned role. Existing legacy clients can still sign in normally.
      if (profile.role != 'user') {
        await _clearRejectedSession();
        throw AuthException('The registration profile could not be verified.');
      }
      _cacheProfile(profile);
      return profile;
    } catch (_) {
      throw AuthException(
        'Your account was created, but its client profile is not ready. '
        'Retry sign-in later or contact support; do not register again.',
        code: 'profile-provisioning-failed',
        accountCreated: true,
      );
    }
  }

  Future<AppProfile> loadProfile() async {
    if (gateway.currentUser == null) {
      throw AuthException('You are not signed in.');
    }

    late final AppProfile profile;
    try {
      profile = await api.getMyProfile();
    } on ApiException catch (error) {
      if (error.statusCode == 404) {
        await _clearRejectedSession();
        throw AuthException(
          'No application profile is linked to this Auth account. Access is denied; ask support to verify the account.',
          code: 'profile-not-found',
        );
      }
      rethrow;
    }

    final user = gateway.currentUser;
    if (user == null) throw AuthException('You are not signed in.');
    final authorizedRole =
        profile.isClient ||
        (profile.isLawyer &&
            profile.onboardingStatus == 'active' &&
            user.email?.trim().toLowerCase() ==
                profile.email.trim().toLowerCase());
    if (!profile.hasValidRole || !authorizedRole) {
      await _clearRejectedSession();
      throw AuthException(
        'This account has no active client or lawyer profile.',
        code: 'role-not-authorized',
      );
    }
    if (profile.uid.trim().isEmpty) {
      await _clearRejectedSession();
      throw AuthException(
        'The application profile has no valid identity. Access is denied.',
        code: 'profile-invalid',
      );
    }
    return profile;
  }

  Future<void> _clearRejectedSession() async {
    api.clearApplicationUid();
    try {
      await gateway.signOut();
    } catch (_) {
      // Local Auth state is cleared by the gateway even when logout is offline.
    }
  }

  Future<void> requestPasswordReset(String email) =>
      gateway.requestPasswordReset(email: email);

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) => gateway.changePassword(
    currentPassword: currentPassword,
    newPassword: newPassword,
  );

  Future<void> setPasswordFromRecovery(String newPassword) =>
      gateway.setPasswordFromRecovery(newPassword);

  Future<void> signOut() async {
    await gateway.signOut();
    api.clearApplicationUid();
    // Clear cached user profile for the current user.
    final user = gateway.currentUser;
    if (user != null) {
      _userCache?.clear(user.uid);
    }
  }

  void dispose() {
    gateway.dispose();
    api.dispose();
  }
}
