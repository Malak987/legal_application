import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:legalserviceapp/services/auth_service.dart';
import 'package:legalserviceapp/state/session_controller.dart';
import 'package:legalserviceapp/state/session_scope.dart';

import 'fakes.dart';

/// A [SessionController] backed by a real HTTP mock, with an optional widget
/// pumped behind it inside a [SessionScope].
class DeletionHarness {
  DeletionHarness({required this.session, required this.gateway});
  final SessionController session;
  final FakeAuthGateway gateway;
}

Future<DeletionHarness> pumpDeletionHarness(
  WidgetTester tester,
  Widget? child, {
  required Future<http.Response> Function(http.Request request, int attempt)
  handler,
  bool signedIn = true,
  String role = 'client',
}) async {
  // `AuthService.loadProfile` only accepts a lawyer whose onboarding is active,
  // so the profile has to look like a real authorised lawyer account.
  final profile = profileJson(role: role);
  if (role == 'lawyer') profile['onboarding_status'] = 'active';
  final gateway = FakeAuthGateway();
  final session = SessionController(
    auth: AuthService(
      gateway: gateway,
      api: testApiClient(userProfile: profile, handler: handler),
    ),
  );
  addTearDown(session.dispose);
  session.start();
  if (signedIn) {
    // Like a real gateway, the Auth session already exists when the controller
    // starts, so startup restoration resolves it to signedIn.
    gateway.emit(const AuthUser(uid: 'uid-1', email: 'sara@example.com'));
  }
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (child != null) {
    // A tall viewport keeps lazily-built ListView content laid out and findable.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      SessionScope(controller: session, child: MaterialApp(home: child)),
    );
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
  }
  return DeletionHarness(session: session, gateway: gateway);
}

/// Lets real I/O and fake-async frames interleave until the UI is settled.
Future<void> settleDeletion(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}
