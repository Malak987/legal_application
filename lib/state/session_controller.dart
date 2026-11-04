import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_profile.dart';
import '../services/api_client.dart';
import '../services/app_repository.dart';
import '../services/auth_service.dart';

/// Where the app is in the authentication lifecycle.
enum SessionStatus {
  /// Auth state has not been determined yet. Screens must not assume anything.
  resolving,

  /// No active Supabase Auth session.
  signedOut,

  /// Signed in **and** the application profile is loaded.
  signedIn,

  /// A Supabase session exists but the profile could not be loaded. Protected
  /// screens stay closed until the session/profile can be verified.
  profileUnavailable,

  /// A valid recovery callback is awaiting the user's new password.
  passwordRecovery,

  /// A configured recovery callback was rejected or expired.
  recoveryLinkInvalid,
}

/// Owns the authentication lifecycle for the whole app.
///
/// One [AuthService.authStateChanges] subscription drives every state change,
/// so the sign-in screen, the drawer and the profile screen all agree. A
/// generation counter discards results from superseded operations, which is
/// what stops a slow profile read from overwriting a newer sign-out.
class SessionController extends ChangeNotifier {
  SessionController({
    required AuthService auth,
    AppRepository? repository,
    Stream<Uri>? recoveryLinkStream,
  }) : _auth = auth,
       _repository = repository,
       _recoveryLinkStream = recoveryLinkStream;

  final AuthService _auth;
  final Stream<Uri>? _recoveryLinkStream;
  AppRepository? _repository;
  StreamSubscription<Uri>? _recoveryLinkSubscription;

  /// The auth service this session drives (its gateway and API client share
  /// one validated Supabase config). Exposed for wiring tests only.
  @visibleForTesting
  AuthService get authService => _auth;

  /// Read access to the backend collections, sharing this session's
  /// [ApiClient] so every request uses the same base URL and token handling.
  AppRepository get repository => _repository ??= AppRepository(_auth.api);

  /// Session/token changes consumed by Realtime; unlike profile auth-state
  /// events, a refresh does not cause another profile read.
  Stream<AuthUser?> get authSessionChanges => _auth.sessionChanges;

  StreamSubscription<AuthUser?>? _subscription;
  int _generation = 0;

  /// True while [signIn], [register] or [refreshProfile] is running.
  ///
  /// Those methods load the profile themselves, and Auth also reports explicit
  /// changes on the stream. Without this guard both paths would fetch the
  /// profile — duplicate requests, and a visible flicker.
  bool _explicitOperation = false;

  SessionStatus _status = SessionStatus.resolving;
  AuthUser? _user;
  AppProfile? _profile;
  String? _error;
  String? _registrationErrorCode;
  bool _registrationAccountCreated = false;
  bool _busy = false;

  SessionStatus get status => _status;
  AuthUser? get user => _user;
  AppProfile? get profile => _profile;

  /// Last user-facing error, if any. Cleared when a new attempt starts.
  String? get error => _error;

  /// Safe structured registration result for UI messages (never raw server text).
  String? get registrationErrorCode => _registrationErrorCode;
  bool get registrationAccountCreated => _registrationAccountCreated;

  /// True while a sign-in/registration/refresh is in flight.
  bool get isBusy => _busy;

  /// True only when a profile is loaded. Protected screens gate on this.
  bool get isSignedIn => _status == SessionStatus.signedIn;

  bool get isPasswordRecoveryFlow => const {
    SessionStatus.passwordRecovery,
    SessionStatus.recoveryLinkInvalid,
  }.contains(_status);

  bool get isAuthCallbackFlow => isPasswordRecoveryFlow;

  /// True while the app is still deciding. Used to avoid showing either the
  /// signed-in or the signed-out UI too early.
  bool get isResolving => _status == SessionStatus.resolving;

  /// Starts the auth-change listener and restores the encrypted refresh-token
  /// session. Safe to call more than once.
  void start({Uri? initialCallbackUri}) {
    if (_subscription != null) return;
    _restoring = true;
    _status = SessionStatus.resolving;
    try {
      _subscription = _auth.authStateChanges.listen(
        (user) {
          // Callback links can emit while restoreSession is parsing the URL.
          // The restore result is authoritative and handles that event once.
          if (_restoring) return;
          unawaited(_onAuthStateChanged(user));
        },
        onError: (Object error) {
          if (_restoring) return;
          _auth.api.clearApplicationUid();
          _status = SessionStatus.signedOut;
          _error = _describe(error);
          notifyListeners();
        },
      );
      final links = _recoveryLinkStream;
      if (links != null) {
        _recoveryLinkSubscription = links.listen(
          (uri) => unawaited(_handleRecoveryLink(uri)),
          onError: (Object _) {},
        );
      }
      unawaited(_restoreSession(initialCallbackUri));
    } catch (error) {
      _restoring = false;
      _status = SessionStatus.signedOut;
      _error = _describe(error);
      notifyListeners();
    }
  }

  bool _restoring = false;

  Future<void> _restoreSession(Uri? callbackUri) async {
    final generation = ++_generation;
    try {
      final user = await _auth.restoreSession(callbackUri: callbackUri);
      if (generation != _generation) return;
      _restoring = false;
      if (user != null && _auth.isPasswordRecovery) {
        _enterPasswordRecovery(user);
      } else {
        await _onAuthStateChanged(user);
      }
    } catch (error) {
      if (generation != _generation) return;
      _restoring = false;
      _user = null;
      _profile = null;
      if (error is AuthException && error.code == 'invalid-recovery-link') {
        _status = SessionStatus.recoveryLinkInvalid;
        _error = error.message;
      } else {
        _status = SessionStatus.signedOut;
        _error = _describe(error);
      }
      notifyListeners();
    }
  }

  Future<void> _handleRecoveryLink(Uri uri) async {
    final generation = ++_generation;
    _restoring = true;
    _status = SessionStatus.resolving;
    _error = null;
    notifyListeners();
    try {
      final user = await _auth.restoreSession(callbackUri: uri);
      if (generation != _generation) return;
      _restoring = false;
      if (user == null) {
        // Ignore unrelated app links and restore the previously known state.
        if (_profile != null) {
          _status = SessionStatus.signedIn;
        } else if (_user == null) {
          _status = SessionStatus.signedOut;
        } else {
          _status = SessionStatus.profileUnavailable;
        }
        notifyListeners();
        return;
      }
      if (_auth.isPasswordRecovery) {
        _enterPasswordRecovery(user);
      } else {
        await _onAuthStateChanged(user);
      }
    } catch (error) {
      if (generation != _generation) return;
      _restoring = false;
      _user = null;
      _profile = null;
      _status = SessionStatus.recoveryLinkInvalid;
      _error = _describe(error);
      notifyListeners();
    }
  }

  void _enterPasswordRecovery(AuthUser user) {
    _user = user;
    _profile = null;
    _status = SessionStatus.passwordRecovery;
    _error = null;
    notifyListeners();
  }

  Future<void> _onAuthStateChanged(AuthUser? user) async {
    // Native link delivery and the callback's auth-state event can reach this
    // listener in either order. Never profile-load a recovery-only session.
    if (user != null && _auth.isPasswordRecovery) {
      _restoring = false;
      _generation++;
      _enterPasswordRecovery(user);
      return;
    }
    // Explicit sign-in/register/profile operations reconcile their own result.
    // In particular, signup may emit null while reporting confirmation pending;
    // processing that event here would supersede and erase the pending result.
    if (_explicitOperation) return;
    // The same account reported again (a token refresh, say) must not trigger
    // another profile read.
    if (user != null &&
        _user?.uid == user.uid &&
        (_status == SessionStatus.signedIn ||
            _status == SessionStatus.resolving)) {
      return;
    }

    if (user == null) {
      _generation++;
      _auth.api.clearApplicationUid();
      _user = null;
      _profile = null;
      _error = null;
      _status = SessionStatus.signedOut;
      notifyListeners();
      return;
    }

    final generation = ++_generation;
    if (_user?.uid != user.uid) _auth.api.clearApplicationUid();
    _user = user;
    _profile = null;
    _status = SessionStatus.resolving;
    _error = null;
    notifyListeners();

    try {
      // SharedPreferences is mutable client state, not authorization evidence.
      // Fail closed when the server profile cannot be verified; cached display
      // data must never grant access or resurrect a previously privileged role.
      final profile = await _auth.loadProfile();
      if (generation != _generation) return;
      _profile = profile;
      _status = SessionStatus.signedIn;
    } catch (error) {
      if (generation != _generation) return;
      _profile = null;
      _status = SessionStatus.profileUnavailable;
      _error = _describe(error);
    }
    notifyListeners();
  }

  /// Signs in and loads the profile. Returns true when the app is ready.
  Future<bool> signIn({required String email, required String password}) async {
    _restoring = false;
    final generation = ++_generation;
    _explicitOperation = true;
    _busy = true;
    _error = null;
    notifyListeners();

    try {
      final profile = await _auth.signIn(email: email, password: password);

      // A newer operation (sign-out, or a second attempt) won while this one
      // was in flight. Reporting success here would let the caller navigate to
      // a protected screen for a session that no longer exists.
      if (generation != _generation) return false;

      _user = _auth.currentUser;
      _profile = profile;
      _status = SessionStatus.signedIn;
      _explicitOperation = false;
      _busy = false;
      notifyListeners();
      return true;
    } catch (error) {
      if (generation != _generation) return false;
      _explicitOperation = false;

      // A profile failure means Supabase Auth accepted the credential, even
      // though this call failed: keep the UUID so a retry targets that account.
      _user ??= _auth.currentUser;
      if (error is AuthException) {
        // The credential was rejected: there is no session to keep.
        _user = null;
        _profile = null;
        _status = SessionStatus.signedOut;
      } else {
        // Signed in, but the profile could not be read. Keep the session and
        // report it, rather than pretending the sign-in failed.
        _status = SessionStatus.profileUnavailable;
      }
      _error = _describe(error);
      _busy = false;
      notifyListeners();
      return false;
    }
  }

  /// Registers a new client. Returns true when the app is ready.
  Future<bool> register({
    required String name,
    required String email,
    required String password,
  }) async {
    _restoring = false;
    final generation = ++_generation;
    _explicitOperation = true;
    _busy = true;
    _error = null;
    _registrationErrorCode = null;
    _registrationAccountCreated = false;
    notifyListeners();

    try {
      final profile = await _auth.register(
        name: name,
        email: email,
        password: password,
      );

      // Superseded by a newer operation: do not claim the account is ready.
      if (generation != _generation) return false;

      _user = _auth.currentUser;
      _profile = profile;
      _status = SessionStatus.signedIn;
      _explicitOperation = false;
      _busy = false;
      notifyListeners();
      return true;
    } catch (error) {
      if (generation != _generation) return false;
      _explicitOperation = false;

      // A profile-incomplete account is preserved; keep its live Auth session
      // available for a later profile retry. Confirmation-pending accounts have
      // no session and remain signed out.
      final currentUser = _auth.currentUser;
      if (error is AuthException &&
          error.accountCreated &&
          currentUser != null) {
        _user = currentUser;
        _profile = null;
        _status = SessionStatus.profileUnavailable;
      } else {
        _user = null;
        _profile = null;
        _status = SessionStatus.signedOut;
      }
      _registrationErrorCode = error is AuthException ? error.code : null;
      _registrationAccountCreated =
          error is AuthException && error.accountCreated;
      _error = _describe(error);
      _busy = false;
      notifyListeners();
      return false;
    }
  }

  /// Re-reads the profile from the server and updates the local cache.
  Future<void> refreshProfile() async {
    final generation = ++_generation;
    _explicitOperation = true;
    _busy = true;
    notifyListeners();
    try {
      final profile = await _auth.loadProfile();
      if (generation != _generation) return;
      _profile = profile;
      _status = SessionStatus.signedIn;
      _error = null;
      // Update the local cache with fresh data.
      if (profile.uid.trim().isNotEmpty) {
        _auth.cacheProfile(profile);
      }
    } catch (error) {
      if (generation != _generation) return;
      _status =
          _user == null
              ? SessionStatus.signedOut
              : SessionStatus.profileUnavailable;
      _error = _describe(error);
    } finally {
      // Only the operation that still owns the state clears the flags; a
      // superseding operation is responsible for its own.
      if (generation == _generation) {
        _explicitOperation = false;
        _busy = false;
        notifyListeners();
      }
    }
  }

  /// Saves the caller's own profile fields and refreshes the cached copy.
  ///
  /// The `role` is never part of this call: it is server-owned, and the backend
  /// strips it from a self-update regardless.
  Future<void> updateProfile({
    required String name,
    required String email,
    String? phone,
    String? address,
  }) async {
    final updated = await _auth.api.updateMyProfile(
      name: name,
      email: email,
      phone: phone,
      address: address,
    );
    // The profile row is authoritative. A lawyer role is honoured only while
    // the server lifecycle is active and its email matches Auth.
    final authEmail = (_auth.currentUser?.email ?? '').trim().toLowerCase();
    final allowedRole =
        updated.isClient ||
        (updated.isLawyer &&
            updated.onboardingStatus == 'active' &&
            authEmail == updated.email.trim().toLowerCase());
    if (!updated.hasValidRole || !allowedRole || updated.uid.trim().isEmpty) {
      await signOut();
      throw AuthException(
        'This account has no active client or lawyer profile.',
        code: 'role-not-authorized',
      );
    }
    _profile = AppProfile(
      uid: updated.uid,
      name: updated.name,
      email: updated.email,
      phone: updated.phone,
      role: updated.role,
      avatar: updated.avatar,
      address: updated.address,
      onboardingStatus: updated.onboardingStatus,
    );
    notifyListeners();
  }

  /// Requests a recovery email. The UI uses a generic success message so this
  /// endpoint does not reveal whether an email is registered.
  Future<void> requestPasswordReset(String email) =>
      _auth.requestPasswordReset(email.trim());

  /// Completes a reset-email callback session with a new password.
  Future<void> setPasswordFromRecovery(String newPassword) async {
    await _auth.setPasswordFromRecovery(newPassword);
    await signOut();
  }

  bool get isPasswordRecovery => _auth.isPasswordRecovery;

  /// Changes the signed-in account's password.
  ///
  /// Throws [AuthException] with a message that can be shown as-is. The session
  /// remains active after successful Supabase reauthentication and update.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (!isSignedIn) {
      throw AuthException('You are not signed in.');
    }
    await _auth.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
  }

  /// Signs out of Supabase Auth, clears every cached value, and removes
  /// the local profile cache so the next user sees a clean state.
  Future<void> signOut() async {
    _restoring = false;
    _generation++; // discard any in-flight profile read
    _explicitOperation = false;
    try {
      await _auth.signOut();
    } catch (_) {
      // Local state is cleared regardless: the UI must not stay "signed in"
      // because the network was down.
    }
    _user = null;
    _profile = null;
    _error = null;
    _busy = false;
    _status = SessionStatus.signedOut;

    // Remove the cached profile for the signed-out user.
    final user = _auth.currentUser;
    if (user != null) {
      _auth.clearCachedProfile(user.uid);
    }

    notifyListeners();
  }

  static String _describe(Object error) {
    if (error is AuthException) return error.message;
    if (error is ApiException) {
      if (error.statusCode == 0) {
        // Client-side failure: a timeout or an unusable payload. `ApiClient`
        // already phrased it for the user.
        return error.message;
      }
      if (error.isTransient) {
        return 'Could not reach the server. Check your connection and retry.';
      }
      return error.message;
    }
    return 'Something went wrong. Please try again.';
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _recoveryLinkSubscription?.cancel();
    _recoveryLinkSubscription = null;
    // Also closes the shared HTTP client, so a rebuilt app does not leak
    // sockets.
    _auth.dispose();
    super.dispose();
  }
}
