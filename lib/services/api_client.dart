import 'dart:async' show TimeoutException;
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/supabase_client_config.dart';
import '../models/app_profile.dart';
import '../models/paginated_result.dart';

/// Supplies the signed-in Supabase Auth access token.
typedef IdTokenProvider = Future<String?> Function();

/// Supabase-only HTTP client for Auth-backed PostgREST, RPC, Storage and Edge
/// Function requests. Resource paths are never sent to an application API
/// server; authorization remains in Postgres RLS or trusted Edge Functions.
class ApiClient {
  ApiClient({
    http.Client? client,
    IdTokenProvider? idTokenProvider,
    IdTokenProvider? forceRefreshTokenProvider,
    String? Function()? currentUidProvider,
    SupabaseClientConfig? config,
    String? supabaseUrl,
    String? supabaseAnonKey,
    Duration requestTimeout = defaultRequestTimeout,
  }) : _client = client ?? http.Client(),
       _idTokenProvider = idTokenProvider,
       _forceRefreshTokenProvider = forceRefreshTokenProvider,
       _currentUidProvider = currentUidProvider,
       config = SupabaseClientConfig.select(
         config: config,
         url: supabaseUrl,
         anonKey: supabaseAnonKey,
       ),
       _requestTimeout = requestTimeout;

  static const Duration defaultRequestTimeout = Duration(seconds: 20);
  static const Duration defaultEdgeFunctionTimeout = Duration(seconds: 120);

  final http.Client _client;
  final IdTokenProvider? _idTokenProvider;
  final IdTokenProvider? _forceRefreshTokenProvider;
  final String? Function()? _currentUidProvider;

  /// Validated configuration shared with [SupabaseAuthGateway].
  final SupabaseClientConfig config;

  String get _supabaseUrl => config.url;
  String get _supabaseAnonKey => config.anonKey;
  final Duration _requestTimeout;

  String? _applicationUid;
  String? _applicationAuthUid;
  AppProfile? _lastSupabaseProfile;

  /// Supabase is the only configured data platform for this client.
  bool get usesSupabase => config.isValid;

  /// Compatibility aliases for screens that still describe the data slice.
  bool get usesSupabaseLawyerCatalog => usesSupabase;
  bool get usesSupabaseFavorites => usesSupabase;
  bool get usesSupabaseProfile => usesSupabase;

  /// Last token this client saw. Diagnostics only — never logged or stored.
  String? _token;
  String? _tokenUid;
  String? get token => _token;

  /// A current access token for the Realtime channel handshake. The token is
  /// obtained from the same rotating provider used by authenticated REST calls;
  /// it is never persisted or embedded in a URL. When supplied, [expectedUid]
  /// prevents a late request from returning a token for a switched account.
  Future<String?> freshAccessToken({String? expectedUid}) =>
      _freshToken(expectedUid: expectedUid);

  /// Application user ID after the RLS-scoped profile read, otherwise the Auth
  /// UUID until the explicit legacy-ID mapping has been loaded.
  String? get currentUid {
    final authUid = _authUid;
    if (_tokenUid != authUid) {
      _token = null;
      _tokenUid = authUid;
    }
    final appUid = _applicationUid;
    if (appUid != null && appUid.isNotEmpty && _applicationAuthUid == authUid) {
      return appUid;
    }
    if (appUid != null) clearApplicationUid();
    return authUid;
  }

  String? get _authUid => _currentUidProvider?.call();

  void clearApplicationUid() {
    _applicationUid = null;
    _applicationAuthUid = null;
    _lastSupabaseProfile = null;
  }

  Future<String?> _freshToken({bool force = false, String? expectedUid}) async {
    final uid = _authUid;
    if (expectedUid != null && uid != expectedUid) return null;
    if (_tokenUid != uid) {
      _token = null;
      _tokenUid = uid;
    }

    final custom =
        force
            ? _forceRefreshTokenProvider ?? _idTokenProvider
            : _idTokenProvider;
    if (custom != null) {
      try {
        final supplied = await custom();
        if (_authUid != uid ||
            (expectedUid != null && _authUid != expectedUid)) {
          return null;
        }
        _token = supplied;
        _tokenUid = uid;
        return supplied;
      } catch (_) {
        if (_authUid != uid) return null;
        return _token;
      }
    }
    return _authUid == uid ? _token : null;
  }

  Uri _supabaseResourceUri(String resource, {Map<String, String>? query}) {
    final base =
        _supabaseUrl.endsWith('/')
            ? _supabaseUrl.substring(0, _supabaseUrl.length - 1)
            : _supabaseUrl;
    return Uri.parse(
      '$base/$resource',
    ).replace(queryParameters: query == null || query.isEmpty ? null : query);
  }

  Uri _supabaseUsersUri(Map<String, String> query) =>
      _supabaseResourceUri('rest/v1/users', query: query);

  Future<dynamic> _supabaseRequest(
    String method,
    Uri uri, {
    Object? body,
    bool returnRepresentation = false,
  }) async {
    if (!usesSupabase) {
      throw ApiException(config.errorMessage, 503);
    }

    final requestUid = _authUid;
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await _freshToken(
        force: attempt == 1,
        expectedUid: requestUid,
      );
      if (_authUid != requestUid) {
        throw ApiException('Your session changed. Please retry.', 401);
      }
      if (token == null || token.isEmpty) {
        throw ApiException('You are not signed in.', 401);
      }
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'apikey': _supabaseAnonKey,
        'Authorization': 'Bearer $token',
        if (returnRepresentation) 'Prefer': 'return=representation',
      };
      final encoded = body == null ? null : jsonEncode(body);
      http.Response response;
      try {
        Future<http.Response> call() {
          switch (method) {
            case 'PATCH':
              return _client.patch(uri, headers: headers, body: encoded);
            case 'POST':
              return _client.post(uri, headers: headers, body: encoded);
            default:
              return _client.get(uri, headers: headers);
          }
        }

        response = await call().timeout(_requestTimeout);
      } on TimeoutException {
        throw ApiException.timeout(
          'Supabase took too long to respond. Please check your connection and try again.',
        );
      } catch (_) {
        throw ApiException.network(
          'Could not reach Supabase. Check your connection and try again.',
        );
      }

      if (_authUid != requestUid) {
        throw ApiException('Your session changed. Please retry.', 401);
      }
      if (response.statusCode == 401 && attempt == 0) continue;
      final decoded = _decodeSupabaseResponse(response);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return decoded;
      }
      throw _supabaseResponseError(response, decoded);
    }
    throw ApiException('Your session has expired. Please sign in again.', 401);
  }

  Future<AppProfile> _readSupabaseProfile(Map<String, String> query) async {
    final data = await _supabaseRequest('GET', _supabaseUsersUri(query));
    if (data is! List || data.isEmpty || data.first is! Map) {
      throw ApiException('No profile is linked to this Auth account yet.', 404);
    }
    final profile = AppProfile.fromJson(
      Map<String, dynamic>.from(data.first as Map),
    );
    if (profile.uid.isEmpty) {
      throw ApiException(
        'Supabase returned a profile without an application ID.',
        0,
      );
    }
    _applicationUid = profile.uid;
    _applicationAuthUid = _authUid;
    _lastSupabaseProfile = profile;
    return profile;
  }

  // ------------------------------------------------------------------
  // Profile
  // ------------------------------------------------------------------

  Future<AppProfile> getMyProfile() async {
    final authUid = _authUid;
    if (authUid == null || authUid.isEmpty) {
      throw ApiException('You are not signed in.', 401);
    }
    return _readSupabaseProfile(<String, String>{
      'or': '(id.eq.$authUid,auth_user_id.eq.$authUid)',
      'select': 'id,uid,name,email,phone,role,avatar,address,onboarding_status',
      'limit': '1',
    });
  }

  Future<AppProfile> getProfile(String uid) async {
    if (uid.trim().isEmpty) throw ApiException('Profile ID is required.', 400);
    return _readSupabaseProfile(<String, String>{
      'id': 'eq.${uid.trim()}',
      'select': 'id,uid,name,email,phone,role,avatar,address,onboarding_status',
      'limit': '1',
    });
  }

  /// Confirmed profiles are created by the Auth database trigger. Clients do
  /// not receive a users-table INSERT grant and cannot select their role.
  Future<AppProfile> provisionProfile({required String name}) => getMyProfile();

  Future<AppProfile> updateMyProfile({
    required String name,
    required String email,
    String? phone,
    String? address,
    String? avatar,
  }) async {
    final authUid = _authUid;
    if (authUid == null || authUid.isEmpty) {
      throw ApiException('You are not signed in.', 401);
    }
    if (_applicationAuthUid != authUid) clearApplicationUid();
    final existing = _lastSupabaseProfile ?? await getMyProfile();
    if (email.trim().toLowerCase() != existing.email.trim().toLowerCase()) {
      throw ApiException(
        'Email changes require the verified Supabase Auth email-update flow.',
        403,
      );
    }
    final data = await _supabaseRequest(
      'PATCH',
      _supabaseUsersUri(<String, String>{
        'id': 'eq.${existing.uid}',
        'select': 'id,uid,name,email,phone,role,avatar,address,onboarding_status',
      }),
      body: <String, dynamic>{
        'name': name.trim(),
        if (phone != null) 'phone': phone.trim(),
        if (address != null) 'address': address.trim(),
        if (avatar != null) 'avatar': avatar.trim(),
      },
      returnRepresentation: true,
    );
    if (data is! List || data.isEmpty || data.first is! Map) {
      throw ApiException('Profile update returned no row.', 404);
    }
    final profile = AppProfile.fromJson(
      Map<String, dynamic>.from(data.first as Map),
    );
    _applicationUid = profile.uid;
    _applicationAuthUid = _authUid;
    _lastSupabaseProfile = profile;
    return profile;
  }

  /// Public catalog reads intentionally omit Authorization, selecting `anon`
  /// so the public grants and RLS policies are tested on every request.
  Future<dynamic> getSupabasePublicResource(
    String table, {
    required Map<String, String> query,
  }) async {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(table)) {
      throw ApiException('Invalid Supabase table name.', 400);
    }
    if (!usesSupabase) {
      throw ApiException(config.errorMessage, 503);
    }
    final uri = _supabaseResourceUri('rest/v1/$table', query: query);
    http.Response response;
    try {
      response = await _client
          .get(
            uri,
            headers: <String, String>{
              'apikey': _supabaseAnonKey,
              'Accept': 'application/json',
            },
          )
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw ApiException.timeout(
        'Supabase took too long to respond. Please try again.',
      );
    } catch (_) {
      throw ApiException.network(
        'Could not reach Supabase. Check your connection and try again.',
      );
    }
    final decoded = _decodeSupabaseResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _supabaseResponseError(response, decoded);
    }
    if (decoded is! List) {
      throw ApiException.invalidResponse(
        'Supabase returned an unexpected catalogue.',
      );
    }
    return decoded;
  }

  Future<PaginatedResult<Map<String, dynamic>>> getSupabasePublicPage(
    String table, {
    required Map<String, String> query,
    required int page,
    required int limit,
  }) async {
    final result = await _getSupabasePage(
      table,
      query: query,
      page: page,
      limit: limit,
      publicRead: true,
    );
    return result;
  }

  Future<List<Map<String, dynamic>>> getSupabasePublicLawyers({
    required Map<String, String> query,
  }) async {
    final data = await getSupabasePublicResource('lawyers', query: query);
    return _mapRows(data, 'lawyer catalogue');
  }

  Future<PaginatedResult<Map<String, dynamic>>> getSupabasePublicLawyerPage({
    required Map<String, String> query,
    required int page,
    required int limit,
  }) =>
      getSupabasePublicPage('lawyers', query: query, page: page, limit: limit);

  // ------------------------------------------------------------------
  // PostgREST resources and pagination
  // ------------------------------------------------------------------

  Future<dynamic> _supabaseAuthenticatedRestRequest(
    String method,
    String resource, {
    required Map<String, String> query,
    Object? body,
    bool returnRepresentation = false,
    String? prefer,
  }) async {
    if (!RegExp(r'^rest/v1/[A-Za-z0-9_/]+$').hasMatch(resource) ||
        resource.contains('..')) {
      throw ApiException('Invalid Supabase REST resource.', 400);
    }
    final uri = _supabaseResourceUri(resource, query: query);
    final response = await _supabaseAuthenticatedCall(
      method,
      uri,
      contentType: 'application/json',
      body: body == null ? null : jsonEncode(body),
      extraHeaders: <String, String>{
        'Accept': 'application/json',
        if (prefer != null)
          'Prefer': prefer
        else if (returnRepresentation)
          'Prefer': 'return=representation',
      },
    );
    final decoded = _decodeSupabaseResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _supabaseResponseError(response, decoded);
    }
    return decoded;
  }

  Future<dynamic> getSupabaseAuthenticatedResource(
    String resource, {
    required Map<String, String> query,
  }) => _supabaseAuthenticatedRestRequest('GET', resource, query: query);

  Future<dynamic> postSupabaseAuthenticatedResource(
    String resource, {
    required Map<String, String> query,
    required Object body,
    bool returnRepresentation = true,
  }) => _supabaseAuthenticatedRestRequest(
    'POST',
    resource,
    query: query,
    body: body,
    returnRepresentation: returnRepresentation,
  );

  Future<dynamic> patchSupabaseAuthenticatedResource(
    String resource, {
    required Map<String, String> query,
    required Object body,
    bool returnRepresentation = true,
  }) => _supabaseAuthenticatedRestRequest(
    'PATCH',
    resource,
    query: query,
    body: body,
    returnRepresentation: returnRepresentation,
  );

  Future<dynamic> invokeSupabaseRpc(
    String functionName,
    Map<String, dynamic> body,
  ) {
    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(functionName)) {
      throw ApiException('Invalid Supabase RPC name.', 400);
    }
    return _supabaseAuthenticatedRestRequest(
      'POST',
      'rest/v1/rpc/$functionName',
      query: const <String, String>{},
      body: body,
    );
  }

  Future<dynamic> deleteSupabaseAuthenticatedResource(
    String resource, {
    required Map<String, String> query,
    bool returnRepresentation = false,
  }) => _supabaseAuthenticatedRestRequest(
    'DELETE',
    resource,
    query: query,
    returnRepresentation: returnRepresentation,
  );

  Future<PaginatedResult<Map<String, dynamic>>> getSupabaseAuthenticatedPage(
    String resource, {
    required Map<String, String> query,
    required int page,
    required int limit,
  }) => _getSupabasePage(
    resource,
    query: query,
    page: page,
    limit: limit,
    publicRead: false,
  );

  Future<PaginatedResult<Map<String, dynamic>>> _getSupabasePage(
    String table, {
    required Map<String, String> query,
    required int page,
    required int limit,
    required bool publicRead,
  }) async {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(table)) {
      throw ApiException('Invalid Supabase table name.', 400);
    }
    if (page < 1 || limit < 1 || limit > 100) {
      throw ApiException('Invalid page request.', 400);
    }
    if (!usesSupabase) {
      throw ApiException(config.errorMessage, 503);
    }
    final offset = (page - 1) * limit;
    final pageQuery = <String, String>{
      ...query,
      'limit': '$limit',
      'offset': '$offset',
    };
    final uri = _supabaseResourceUri('rest/v1/$table', query: pageQuery);
    final http.Response response;
    if (publicRead) {
      try {
        response = await _client
            .get(
              uri,
              headers: <String, String>{
                'apikey': _supabaseAnonKey,
                'Accept': 'application/json',
                'Prefer': 'count=exact',
              },
            )
            .timeout(_requestTimeout);
      } on TimeoutException {
        throw ApiException.timeout(
          'Supabase took too long to respond. Please try again.',
        );
      } catch (_) {
        throw ApiException.network(
          'Could not reach Supabase. Check your connection and try again.',
        );
      }
    } else {
      final result = await _supabaseAuthenticatedCall(
        'GET',
        uri,
        contentType: 'application/json',
        extraHeaders: const <String, String>{
          'Accept': 'application/json',
          'Prefer': 'count=exact',
        },
      );
      response = result;
    }

    final decoded = _decodeSupabaseResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _supabaseResponseError(response, decoded);
    }
    final rows = _mapRows(decoded, 'page');
    if (rows.length > limit) {
      throw ApiException.invalidResponse(
        'Supabase returned more rows than requested.',
      );
    }
    final range = response.headers['content-range'];
    final match =
        range == null ? null : RegExp(r'/([0-9]+|\*)\s*$').firstMatch(range);
    final token = match?.group(1);
    final exactTotal =
        token == null || token == '*' ? null : int.tryParse(token);
    final total = exactTotal ?? offset + rows.length;
    final pages =
        exactTotal == null
            ? page + (rows.length == limit ? 1 : 0)
            : (exactTotal + limit - 1) ~/ limit;
    return PaginatedResult<Map<String, dynamic>>(
      items: rows,
      page: page,
      limit: limit,
      total: total,
      totalPages: pages == 0 ? 1 : pages,
      hasMore:
          exactTotal == null
              ? rows.length == limit
              : offset + rows.length < exactTotal,
      exactTotal: exactTotal,
    );
  }

  List<Map<String, dynamic>> _mapRows(dynamic decoded, String context) {
    if (decoded is! List) {
      throw ApiException.invalidResponse(
        'Supabase returned an unexpected $context response.',
      );
    }
    final rows = <Map<String, dynamic>>[];
    for (final row in decoded) {
      if (row is! Map) {
        throw ApiException.invalidResponse(
          'Supabase returned an invalid $context record.',
        );
      }
      try {
        rows.add(Map<String, dynamic>.from(row));
      } on TypeError {
        throw ApiException.invalidResponse(
          'Supabase returned an invalid $context record.',
        );
      }
    }
    return rows;
  }

  Future<http.Response> _supabaseAuthenticatedCall(
    String method,
    Uri uri, {
    required String contentType,
    Object? body,
    Duration? timeout,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    if (!usesSupabase) {
      throw ApiException(config.errorMessage, 503);
    }
    final requestUid = _authUid;
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await _freshToken(
        force: attempt == 1,
        expectedUid: requestUid,
      );
      if (_authUid != requestUid) {
        throw ApiException('Your session changed. Please retry.', 401);
      }
      if (token == null || token.isEmpty) {
        throw ApiException('You are not signed in.', 401);
      }
      final headers = <String, String>{
        'apikey': _supabaseAnonKey,
        'Authorization': 'Bearer $token',
        'Content-Type': contentType,
        ...extraHeaders,
      };
      try {
        Future<http.Response> call() {
          switch (method) {
            case 'GET':
              return _client.get(uri, headers: headers);
            case 'POST':
              return _client.post(uri, headers: headers, body: body);
            case 'PATCH':
              return _client.patch(uri, headers: headers, body: body);
            case 'DELETE':
              return _client.delete(uri, headers: headers, body: body);
            default:
              throw ApiException('Unsupported Supabase request method.', 405);
          }
        }

        final response = await call().timeout(timeout ?? _requestTimeout);
        if (_authUid != requestUid) {
          throw ApiException('Your session changed. Please retry.', 401);
        }
        if (response.statusCode == 401 && attempt == 0) continue;
        return response;
      } on TimeoutException {
        throw ApiException.timeout(
          'Supabase took too long to respond. Please try again.',
        );
      } on ApiException {
        rethrow;
      } catch (_) {
        throw ApiException.network(
          'Could not reach Supabase. Check your connection and try again.',
        );
      }
    }
    throw ApiException('Your session has expired. Please sign in again.', 401);
  }

  dynamic _decodeSupabaseResponse(http.Response response) {
    if (response.body.trim().isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw ApiException.invalidResponse(
        'Supabase returned an unexpected response (${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
  }

  ApiException _supabaseResponseError(http.Response response, dynamic decoded) {
    final message =
        decoded is Map
            ? (decoded['message'] ??
                    decoded['msg'] ??
                    decoded['error_description'] ??
                    decoded['error'])
                ?.toString()
            : null;
    return ApiException(
      message?.isNotEmpty == true
          ? message!
          : 'Supabase request failed (${response.statusCode}).',
      response.statusCode,
    );
  }

  Future<String> _requireSupabaseApplicationUid() async {
    if (!usesSupabase) {
      throw ApiException(config.errorMessage, 503);
    }
    final authUid = _authUid?.trim();
    if (authUid == null || authUid.isEmpty) {
      throw ApiException('You are not signed in.', 401);
    }
    if (_applicationAuthUid != authUid || _applicationUid == null) {
      clearApplicationUid();
      await getMyProfile();
    }
    final appUid = _applicationUid?.trim();
    if (appUid == null ||
        appUid.isEmpty ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(appUid)) {
      throw ApiException(
        'The signed-in profile ID cannot be used for a Supabase resource path.',
        400,
      );
    }
    return appUid;
  }

  /// Uploads a PDF through the authenticated document-upload Edge Function.
  /// The server revalidates the byte signature and size before its server-only
  /// Storage client writes the object; this app never receives that key.
  Future<String> uploadPrivatePdf(List<int> bytes) async {
    if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
      throw ApiException(
        'Choose a non-empty PDF that is 10 MiB or smaller.',
        413,
      );
    }
    if (bytes.length < 5 ||
        bytes[0] != 0x25 ||
        bytes[1] != 0x50 ||
        bytes[2] != 0x44 ||
        bytes[3] != 0x46 ||
        bytes[4] != 0x2d) {
      throw ApiException(
        'The selected file does not have a valid PDF header.',
        415,
      );
    }

    final ownerId = await _requireSupabaseApplicationUid();
    final uri = _supabaseResourceUri('functions/v1/document-upload');
    final response = await _supabaseAuthenticatedCall(
      'POST',
      uri,
      contentType: 'application/pdf',
      body: bytes,
      timeout: defaultEdgeFunctionTimeout,
      extraHeaders: const <String, String>{'Accept': 'application/json'},
    );
    final decoded = _decodeSupabaseResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _supabaseResponseError(response, decoded);
    }
    if (decoded is! Map || decoded['object_path'] is! String) {
      throw ApiException.invalidResponse(
        'The document upload returned an unexpected response.',
        statusCode: response.statusCode,
      );
    }
    final objectPath = decoded['object_path'] as String;
    final segments = objectPath.split('/');
    if (segments.length != 3 ||
        segments[0] != ownerId ||
        segments[1] != 'documents' ||
        !RegExp(r'^[A-Za-z0-9_-]+\.pdf$').hasMatch(segments[2])) {
      throw ApiException.invalidResponse(
        'The document upload returned a path outside this profile.',
        statusCode: response.statusCode,
      );
    }
    return objectPath;
  }

  Future<Map<String, dynamic>> invokeSupabaseFunction(
    String functionName,
    Map<String, dynamic> body,
  ) async {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(functionName)) {
      throw ApiException('Invalid Edge Function name.', 400);
    }
    final uri = _supabaseResourceUri('functions/v1/$functionName');
    final response = await _supabaseAuthenticatedCall(
      'POST',
      uri,
      contentType: 'application/json',
      body: jsonEncode(body),
      timeout: defaultEdgeFunctionTimeout,
    );
    final decoded = _decodeSupabaseResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _supabaseResponseError(response, decoded);
    }
    if (decoded is! Map) {
      throw ApiException.invalidResponse(
        'The Edge Function returned an unexpected response.',
      );
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> deletePrivatePdf(String objectPath) async {
    final segments = objectPath.split('/');
    if (segments.length != 3 ||
        segments[1] != 'documents' ||
        !RegExp(r'^[A-Za-z0-9_-]+\.pdf$').hasMatch(segments[2])) {
      throw ApiException(
        'The document path is not owned by this session.',
        403,
      );
    }
    final ownerId = await _requireSupabaseApplicationUid();
    if (segments[0] != ownerId) {
      throw ApiException(
        'The document path is not owned by this session.',
        403,
      );
    }
    final uri = _supabaseResourceUri('storage/v1/object/legal-documents');
    final response = await _supabaseAuthenticatedCall(
      'DELETE',
      uri,
      contentType: 'application/json',
      body: jsonEncode(<String, dynamic>{
        'prefixes': <String>[objectPath],
      }),
    );
    final decoded = _decodeSupabaseResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _supabaseResponseError(response, decoded);
    }
  }

  void dispose() => _client.close();
}

/// Stable categories for failures returned by Supabase and its transports.
enum ApiErrorKind {
  request,
  network,
  timeout,
  invalidResponse,
  unauthorized,
  forbidden,
  notFound,
  conflict,
  server,
}

class ApiException implements Exception {
  ApiException(this.message, this.statusCode, {ApiErrorKind? kind})
    : kind = kind ?? _kindForStatus(statusCode);

  final String message;
  final int statusCode;
  final ApiErrorKind kind;

  factory ApiException.network(String message) =>
      ApiException(message, 0, kind: ApiErrorKind.network);

  factory ApiException.timeout(String message) =>
      ApiException(message, 0, kind: ApiErrorKind.timeout);

  factory ApiException.invalidResponse(
    String message, {
    int statusCode = 502,
  }) => ApiException(message, statusCode, kind: ApiErrorKind.invalidResponse);

  static ApiErrorKind _kindForStatus(int statusCode) {
    switch (statusCode) {
      case 401:
        return ApiErrorKind.unauthorized;
      case 403:
        return ApiErrorKind.forbidden;
      case 404:
        return ApiErrorKind.notFound;
      case 409:
        return ApiErrorKind.conflict;
      default:
        return statusCode >= 500 ? ApiErrorKind.server : ApiErrorKind.request;
    }
  }

  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;
  bool get isConflict => statusCode == 409;
  bool get isNetworkFailure =>
      kind == ApiErrorKind.network || kind == ApiErrorKind.timeout;
  bool get isTransient =>
      isNetworkFailure || statusCode == 0 || statusCode >= 500;

  @override
  String toString() => message;
}
