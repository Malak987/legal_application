import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_bootstrap.dart';
import 'config/supabase_client_config.dart';
import 'constants/colors.dart';
import 'services/chat_realtime.dart';
import 'services/auth_service.dart';
import 'services/user_cache_service.dart';
import 'state/session_controller.dart';
import 'state/session_scope.dart';
import 'views/authentication/reset_password.dart';
import 'views/splash/splashscreen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize user cache before building the app.
  late final UserCacheService userCache;
  try {
    userCache = await initUserCache();
  } catch (e) {
    debugPrint('Failed to initialize user cache: $e');
    userCache = UserCacheService();
  }

  final appLinks = AppLinks();
  Uri? initialCallbackUri;
  try {
    initialCallbackUri = await appLinks.getInitialLink();
  } catch (_) {
    // Link-stream delivery remains available when no cold-start URI exists.
  }

  runApp(
    bootstrapApp(
      initialCallbackUri: initialCallbackUri,
      buildApp: (session) => MyApp(session: session, userCache: userCache),
      createSession:
          (config) => createSupabaseSession(
            config,
            userCache: userCache,
            recoveryLinkStream: appLinks.uriLinkStream,
          ),
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key, this.session, this.userCache});

  /// Supplied by [bootstrapApp] (already started) or by tests. When omitted
  /// the app builds and starts its own session from the validated config.
  final SessionController? session;

  /// The user cache service, injected from [main].
  final UserCacheService? userCache;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  SessionController? _ownedSession;
  ChatRealtimeService? _chatRealtime;
  StreamSubscription<AuthUser?>? _authSessionSubscription;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  String? _activeCallbackRouteKind;

  SessionController get _session {
    final injected = widget.session;
    if (injected != null) return injected;
    return _ownedSession ??= _createSession();
  }

  bool get _ownsSession => widget.session == null;

  static SessionController _createSession() =>
      createSupabaseSession(SupabaseClientConfig.environment);

  @override
  void initState() {
    super.initState();
    // Restore the encrypted Supabase refresh-token session before protected
    // screens are selected. Missing public config leaves the user signed out
    // with an actionable auth error rather than falling back to Firebase.
    if (_ownsSession) {
      _session.start();
    } else {
      // If we have an injected session, it's already been started by
      // bootstrapApp, but we still need to listen for auth changes.
      _session.addListener(_syncRealtimeSession);
      _authSessionSubscription = _session.authSessionChanges.listen(
        _syncRealtimeSession,
      );
      _syncRealtimeSession();
    }

    // One Realtime connection for the whole app. Each socket handshake gets a
    // fresh JWT; the service only marks it connected after both table joins are
    // acknowledged, and a rejected join tears down the socket and retries.
    // Chat-thread polling remains active when Realtime cannot join.
    final session = _session;
    final repository = session.repository;
    final realtime = ChatRealtimeService(
      baseUrl: repository.realtimeUrl,
      anonKey: repository.realtimeAnonKey,
      tokenProvider: repository.realtimeAccessToken,
    );
    _chatRealtime = realtime;
    // Do not open a privileged-by-role channel until the client profile has
    // been validated. Token-only refresh events update the socket without
    // forcing a duplicate profile read.
    session.addListener(_syncRealtimeSession);
    _authSessionSubscription = session.authSessionChanges.listen(
      _syncRealtimeSession,
    );
    _syncRealtimeSession();
  }

  void _syncRealtimeSession([AuthUser? changedUser]) {
    _syncCallbackRoute();
    final realtime = _chatRealtime;
    if (realtime == null) return;
    final session = _session;
    final user = session.user;
    final authUser = session.authUser;
    final verified =
        session.status == SessionStatus.signedIn &&
        user != null &&
        authUser?.uid == user.uid &&
        (changedUser == null || changedUser.uid == user.uid);
    unawaited(realtime.setSession(verified ? user!.uid : null));
  }

  void _syncCallbackRoute() {
    final session = _session;
    final routeKind = session.isPasswordRecoveryFlow ? 'recovery' : null;
    if (routeKind == null) {
      _activeCallbackRouteKind = null;
      return;
    }
    if (_activeCallbackRouteKind == routeKind) return;
    _activeCallbackRouteKind = routeKind;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _activeCallbackRouteKind != routeKind) return;
      final navigator = _navigatorKey.currentState;
      if (navigator == null) {
        _activeCallbackRouteKind = null;
        return;
      }
      const Widget destination = ResetPasswordScreen();
      navigator.pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => destination),
        (_) => false,
      );
    });
  }

  @override
  void dispose() {
    _session.removeListener(_syncRealtimeSession);
    unawaited(_authSessionSubscription?.cancel());
    _authSessionSubscription = null;
    _chatRealtime?.dispose();
    if (_ownsSession) _ownedSession?.dispose();
    super.dispose();
  }

  /// Ensures injected sessions (from tests or bootstrap) are started when
  /// attached to the widget tree.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ownsSession || widget.session != null) {
      _session.addListener(_syncRealtimeSession);
      _authSessionSubscription = _session.authSessionChanges.listen(
        _syncRealtimeSession,
      );
      _syncRealtimeSession();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChatRealtimeScope(
      service: _chatRealtime!,
      child: SessionScope(
        controller: _session,
        child: MaterialApp(
          navigatorKey: _navigatorKey,
          debugShowCheckedModeBanner: false,
          title: 'Legal Services App',
          supportedLocales: const [Locale('en'), Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: ThemeData(
            scaffoldBackgroundColor: AppColors.bgColor,
            useMaterial3: true,
          ),
          home: const SplashScreen(),
        ),
      ),
    );
  }
}
