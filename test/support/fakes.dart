import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legalserviceapp/services/api_client.dart';
import 'package:legalserviceapp/services/auth_service.dart';

/// An in-memory secure-session store for testing token rotation/restoration.
class MemoryAuthSessionStore implements AuthSessionStore {
  String? refreshToken;

  @override
  Future<String?> readRefreshToken() async => refreshToken;

  @override
  Future<void> writeRefreshToken(String token) async {
    refreshToken = token;
  }

  @override
  Future<void> clear() async {
    refreshToken = null;
  }
}

/// An in-memory [AuthGateway] for lifecycle tests; no network or platform
/// storage is involved.
class FakeAuthGateway implements AuthGateway {
  FakeAuthGateway({AuthUser? initialUser}) : _current = initialUser;

  final StreamController<AuthUser?> _changes =
      StreamController<AuthUser?>.broadcast();
  final StreamController<AuthUser?> _sessionChanges =
      StreamController<AuthUser?>.broadcast();

  AuthUser? _current;

  /// Failures the next call should throw, or `null` for success.
  AuthException? createAccountError;
  AuthException? signInError;
  bool isRecovery = false;

  /// When false, sign-in/sign-up update [currentUser] but do not emit a stream
  /// event. Sign-out always emits, as the real gateway does.
  bool emitAuthEvents = true;

  int createAccountCalls = 0;
  int signInCalls = 0;
  int signOutCalls = 0;
  int changePasswordCalls = 0;
  int resetPasswordCalls = 0;
  int recoveryPasswordCalls = 0;

  /// Arguments of the last [changePassword] call, for assertions.
  String? lastCurrentPassword;
  String? lastNewPassword;
  String? lastResetEmail;

  /// Failure the next [changePassword] should throw, or `null` for success.
  AuthException? changePasswordError;
  AuthException? resetPasswordError;
  AuthException? recoveryPasswordError;

  @override
  Stream<AuthUser?> get authStateChanges => _changes.stream;

  @override
  Stream<AuthUser?> get sessionChanges => _sessionChanges.stream;

  @override
  AuthUser? get currentUser => _current;

  @override
  bool get isPasswordRecovery => isRecovery;

  @override
  Future<AuthUser?> restoreSession({Uri? callbackUri}) async => _current;

  @override
  Future<AuthUser> signIn({
    required String email,
    required String password,
  }) async {
    signInCalls++;
    final error = signInError;
    if (error != null) throw error;
    final user = AuthUser(uid: 'uid-${email.hashCode.abs()}', email: email);
    _set(user, emit: emitAuthEvents);
    return user;
  }

  @override
  Future<AuthUser> createAccount({
    required String email,
    required String password,
    String? displayName,
  }) async {
    createAccountCalls++;
    final error = createAccountError;
    if (error != null) throw error;
    final user = AuthUser(uid: 'uid-new', email: email);
    _set(user, emit: emitAuthEvents);
    return user;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    _set(null);
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    changePasswordCalls++;
    lastCurrentPassword = currentPassword;
    lastNewPassword = newPassword;
    final error = changePasswordError;
    if (error != null) throw error;
  }

  @override
  Future<void> requestPasswordReset({
    required String email,
    String? redirectTo,
  }) async {
    resetPasswordCalls++;
    lastResetEmail = email;
    final error = resetPasswordError;
    if (error != null) throw error;
  }

  @override
  Future<void> setPasswordFromRecovery(String newPassword) async {
    recoveryPasswordCalls++;
    final error = recoveryPasswordError;
    if (error != null) throw error;
    isRecovery = false;
  }

  @override
  void dispose() {
    if (!_changes.isClosed) _changes.close();
    if (!_sessionChanges.isClosed) _sessionChanges.close();
  }

  /// Emits an explicit auth change.
  void emit(AuthUser? user) => _set(user);

  void _set(AuthUser? user, {bool emit = true}) {
    _current = user;
    if (emit && !_changes.isClosed) _changes.add(user);
    if (!_sessionChanges.isClosed) _sessionChanges.add(user);
  }
}

/// A 200 response carrying the backend's `{ success, data }` envelope.
///
/// Use this only for legacy API compatibility tests. For Supabase-native
/// flows, use [supabaseOk] instead.
http.Response jsonOk(
  Object? data, {
  int status = 200,
  Map<String, String>? headers,
}) {
  return http.Response(
    jsonEncode(data),
    status,
    headers: {
      'content-type': 'application/json',
      if (headers != null) ...headers,
    },
  );
}

/// An error response in the same envelope, with a `message`.
http.Response jsonError(int status, String message) {
  return http.Response(
    jsonEncode({'success': false, 'message': message}),
    status,
    headers: {'content-type': 'application/json'},
  );
}

/// A Supabase-native PostgREST or RPC response (raw JSON).
http.Response supabaseOk(
  Object? data, {
  int status = 200,
  Map<String, String>? headers,
}) {
  return http.Response(
    jsonEncode(data),
    status,
    headers: {
      'content-type': 'application/json',
      if (headers != null) ...headers,
    },
  );
}

/// A Supabase-native error response.
http.Response supabaseError(int status, String message) {
  return http.Response(
    jsonEncode({'message': message, 'code': status.toString()}),
    status,
    headers: {'content-type': 'application/json'},
  );
}

/// An [ApiClient] wired to a [MockClient], so no socket is ever opened.
///
/// [handler] receives the request and the number of times that exact
/// method+path pair has been seen, which is how retry behaviour is asserted.
ApiClient testApiClient({
  required Future<http.Response> Function(http.Request request, int attempt)
  handler,
  String uid = 'uid-1',
  String? Function()? currentUidProvider,
  String token = 'test-token',
  Map<String, dynamic>? userProfile,
  Duration requestTimeout = ApiClient.defaultRequestTimeout,
}) {
  final counts = <String, int>{};
  final client = MockClient((request) async {
    if (userProfile != null &&
        request.url.path.contains('/rest/v1/users') &&
        request.method == 'GET') {
      return supabaseOk([userProfile]);
    }
    final key = '${request.method} ${request.url.path}';
    final attempt = (counts[key] ?? 0) + 1;
    counts[key] = attempt;
    final response = await handler(request, attempt);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          if (request.method == 'GET' &&
              decoded.containsKey('items') &&
              decoded['items'] is List) {
            final items = decoded['items'] as List;
            final total = (decoded['total'] as num?)?.toInt() ?? items.length;
            final start = 0;
            final end = (items.length - 1).clamp(0, total > 0 ? total - 1 : 0);
            return http.Response(
              jsonEncode(items),
              response.statusCode,
              headers: {
                'content-type': 'application/json',
                'content-range': '$start-$end/$total',
                ...response.headers,
              },
            );
          } else if (!decoded.containsKey('success') &&
              !decoded.containsKey('message') &&
              request.method == 'GET' &&
              request.url.path.contains('/rest/v1/')) {
            return supabaseOk(
              [decoded],
              status: response.statusCode,
              headers: response.headers,
            );
          }
        }
      } catch (_) {}
    }
    return response;
  });

  return ApiClient(
    client: client,
    idTokenProvider: () async => token,
    currentUidProvider: currentUidProvider ?? (() => uid),
    supabaseUrl: 'https://test.supabase.co',
    supabaseAnonKey: 'test-anon-key',
    requestTimeout: requestTimeout,
  );
}

/// Convenience: a profile document as `GET /api/users/:id` returns it.
Map<String, dynamic> profileJson({
  String id = 'uid-1',
  String? uid,
  String name = 'Sara Ali',
  String email = 'sara@example.com',
  String role = 'client',
  String? phone,
  String? address,
}) {
  final resolvedId = uid ?? id;
  return {
    'id': resolvedId,
    'uid': resolvedId,
    'name': name,
    'email': email,
    'role': role,
    if (phone != null) 'phone': phone,
    if (address != null) 'address': address,
  };
}
