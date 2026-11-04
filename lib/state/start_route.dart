import 'session_controller.dart';

/// The first screen the app routes to once authentication has resolved.
enum StartScreen { home, onboarding }

/// Decides where a restored session should land.
///
/// Deliberately a pure function so it can be tested without building screens,
/// and deliberately strict: only [SessionStatus.signedIn] — a session whose
/// profile is loaded — reaches the protected home. Signed out, still resolving,
/// or signed in with a broken profile all go to the unauthenticated flow. That
/// is what makes "authenticated" impossible to mistake for "allowed in".
StartScreen startScreenFor(SessionStatus status) {
  return status == SessionStatus.signedIn
      ? StartScreen.home
      : StartScreen.onboarding;
}
