import 'package:flutter/material.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:legalserviceapp/views/onboarding/onboarding.dart';
import 'dart:async' show unawaited;

import '../../state/session_controller.dart';
import '../../state/session_scope.dart';
import '../../state/start_route.dart';
import '../home/homescreen.dart';
import '../authentication/reset_password.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  SplashScreenState createState() => SplashScreenState();
}

class SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _scaleAnimation = Tween<double>(
      begin: 0.9,
      end: 1.1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _controller.repeat(reverse: true);

    _bootstrap();
  }

  /// Navigates to the appropriate screen based on the current auth status.
  ///
  /// This method is called immediately when the splash animation completes.
  /// It checks the session status and routes accordingly — no artificial delay
  /// is added, preventing any authentication flicker.
  void _navigateToDestination(SessionController session) {
    if (!mounted) return;

    // MyApp owns password-recovery callback routing for both cold-start and
    // already-running app links. Do not retry a callback-only session as a
    // normal signed-in profile or create a duplicate navigation route here.
    if (session.isAuthCallbackFlow) return;

    // A Supabase session that exists but whose profile could not be loaded is
    // usually a transient failure (offline start, backend restart). Retrying
    // once here is the difference between "signed in" and being dropped on the
    // onboarding screen for no app-level reason.
    unawaited(_recoverProfileOnce(session));

    final recoveryStatus =
        session.status == SessionStatus.passwordRecovery ||
        session.status == SessionStatus.recoveryLinkInvalid;
    final Widget destination =
        recoveryStatus
            ? const ResetPasswordScreen()
            : startScreenFor(session.status) == StartScreen.home
            ? HomePage()
            : OnboardingScreen();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => destination),
    );
  }

  /// Waits for the splash animation, then routes on the restored session.
  ///
  /// The splash screen is the only screen shown before authentication is
  /// known, so a protected screen can never flash before the answer arrives:
  /// the decision is made here, after `SessionController` reports a definitive
  /// status. No forced delay — auth state is checked immediately after the
  /// animation completes to avoid any flicker.
  void _bootstrap() async {
    // Wait only for the animation to complete, not an arbitrary delay.
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    final session = SessionScope.read(context);
    await _awaitResolution(session);
    if (!mounted) return;

    _navigateToDestination(session);
  }

  /// One bounded recovery attempt for a session whose profile failed to load.
  ///
  /// Skipped entirely when there is no Supabase session, and never retried in a
  /// loop: a second failure falls through to the unauthenticated flow, which
  /// still lets the user sign in again.
  Future<void> _recoverProfileOnce(SessionController session) async {
    if (session.isSignedIn || session.user == null) return;
    await session.refreshProfile();
  }

  /// Waits (briefly) for auth state to resolve.
  ///
  /// Bounded so a Supabase request that never answers cannot trap the user on the
  /// splash screen: after the timeout the app falls through to the
  /// unauthenticated flow, which is the safe default.
  Future<void> _awaitResolution(SessionController session) async {
    const tick = Duration(milliseconds: 100);
    const maxWait = Duration(seconds: 8);
    var waited = Duration.zero;
    while (session.isResolving && waited < maxWait) {
      await Future.delayed(tick);
      waited += tick;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          _buildBackgroundGlow(),
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ScaleTransition(
                  scale: _scaleAnimation,
                  child: Container(
                    padding: const EdgeInsets.all(35),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.amber.withAlpha((0.7 * 255).toInt()),
                          blurRadius: 30,
                          spreadRadius: 10,
                        ),
                      ],
                      gradient: const LinearGradient(
                        colors: [Colors.amber, Colors.deepOrange],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: const Icon(
                      Icons.gavel, // Legal theme icon
                      size: 85,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  "Legal Assist", // App Name
                  style: GoogleFonts.poppins(
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  "Your Trusted Partner in Legal Solutions",
                  style: GoogleFonts.poppins(
                    fontSize: 16,
                    color: Colors.grey.shade400,
                  ),
                ),
                const SizedBox(height: 40),
                SpinKitThreeBounce(
                  color: Colors.amberAccent.shade100,
                  size: 40,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackgroundGlow() {
    return Positioned.fill(
      child: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.2,
            colors: [Colors.amber, Colors.black],
          ),
        ),
      ),
    );
  }
}
