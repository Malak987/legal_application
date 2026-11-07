import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config/supabase_client_config.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/user_cache_service.dart';
import 'state/session_controller.dart';
import 'views/configuration/supabase_config_error_screen.dart';

/// Startup sequence: validate the compiled Supabase configuration first, then
/// build exactly one Supabase session (Auth gateway + data client sharing the
/// same validated config) and start restoring the persisted session.
///
/// With an invalid configuration no Supabase client is created and no network
/// request is made; a configuration screen explains how to rebuild.
Widget bootstrapApp({
  required Widget Function(SessionController session) buildApp,
  SupabaseClientConfig? config,
  SessionController Function(SupabaseClientConfig config)? createSession,
  Uri? initialCallbackUri,
}) {
  final resolved = config ?? SupabaseClientConfig.environment;
  if (!resolved.isValid) {
    // Safe to log: the message never contains the key value.
    debugPrint(resolved.errorMessage);
    return SupabaseConfigErrorApp(config: resolved);
  }
  final session = (createSession ?? createSupabaseSession)(resolved);
  session.start(initialCallbackUri: initialCallbackUri);
  return buildApp(session);
}

/// Wires one [SupabaseAuthGateway], one [ApiClient], and an optional
/// [UserCacheService] to the same validated [config].
/// [httpClient], [sessionStore], and [userCache] are injection points for tests.
SessionController createSupabaseSession(
  SupabaseClientConfig config, {
  http.Client? httpClient,
  AuthSessionStore? sessionStore,
  PkceVerifierStore? pkceStore,
  UserCacheService? userCache,
  Stream<Uri>? recoveryLinkStream,
  // Test seams. Production leaves these null so the compiled Dart defines
  // (`SUPABASE_AUTH_REDIRECT_URL`, `ENABLE_CLIENT_SIGNUP`) decide.
  String? authRedirectUrl,
  bool? allowClientSignup,
}) {
  final gateway = SupabaseAuthGateway(
    config: config,
    client: httpClient,
    sessionStore: sessionStore,
    pkceStore: pkceStore,
    authRedirectUrl: authRedirectUrl,
    allowClientSignup: allowClientSignup,
  );
  final api = ApiClient(
    config: config,
    client: httpClient,
    idTokenProvider: () => gateway.getAccessToken(),
    forceRefreshTokenProvider: () => gateway.getAccessToken(forceRefresh: true),
    currentUidProvider: () => gateway.currentUser?.uid,
  );
  return SessionController(
    auth: AuthService(
      gateway: gateway,
      api: api,
      userCache: userCache,
    ),
    recoveryLinkStream: recoveryLinkStream,
  );
}

/// Initializes the [SharedPreferences]-backed [UserCacheService] and returns
/// it for wiring into the session.
Future<UserCacheService> initUserCache() async {
  final prefs = await SharedPreferences.getInstance();
  return UserCacheService(preferences: prefs);
}
