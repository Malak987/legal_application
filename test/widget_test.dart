// The old counter template test was removed: it asserted on a demo widget that
// no longer exists, so it could never pass against this app. These tests
// exercise the authentication boundary that now decides what the user sees.
//
// They run under `testWidgets`, which uses a fake clock. The session's profile
// load awaits real futures (MockClient), so each state change is driven inside
// `tester.runAsync` and awaited through the controller itself rather than by
// guessing how many microtask turns a `pump()` flushes. That keeps the tests
// deterministic instead of timing-dependent.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:legalserviceapp/services/auth_service.dart';
import 'package:legalserviceapp/state/session_controller.dart';
import 'package:legalserviceapp/state/session_scope.dart';
import 'package:legalserviceapp/views/search/search_screen.dart';

import 'support/fakes.dart';

/// A stand-in for the app shell: what it shows depends entirely on the session.
class _Probe extends StatelessWidget {
  const _Probe();

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    if (session.isResolving) {
      return const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('resolving'),
      );
    }
    if (session.isSignedIn) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Text('home:${session.profile?.displayName}'),
      );
    }
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: Text('auth'),
    );
  }
}

void main() {
  late FakeAuthGateway gateway;
  late SessionController session;

  setUp(() {
    gateway = FakeAuthGateway();
    session = SessionController(
      auth: AuthService(
        gateway: gateway,
        api: testApiClient(
          userProfile: profileJson(),
          handler: (_, __) async => jsonOk(const {}),
        ),
      ),
    );
  });

  tearDown(() => session.dispose());

  /// Runs real async until [done] is true, then renders one frame.
  ///
  /// Bounded, so a broken session fails the assertion below instead of hanging.
  Future<void> settle(
    WidgetTester tester,
    bool Function() done, {
    String reason = 'session never settled',
  }) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    expect(done(), isTrue, reason: reason);
    await tester.pump();
  }

  testWidgets('protected UI is not shown while auth is still resolving',
      (tester) async {
    await tester.pumpWidget(
      SessionScope(controller: session, child: const _Probe()),
    );

    expect(find.text('resolving'), findsOneWidget);
    expect(find.text('auth'), findsNothing);
    expect(find.textContaining('home:'), findsNothing);
  });

  testWidgets('the signed-out state renders the auth flow', (tester) async {
    await tester.pumpWidget(
      SessionScope(controller: session, child: const _Probe()),
    );
    session.start();

    gateway.emit(null);
    await settle(tester, () => session.status == SessionStatus.signedOut);

    expect(find.text('auth'), findsOneWidget);
  });

  testWidgets('a loaded profile switches the shell to the signed-in UI',
      (tester) async {
    await tester.pumpWidget(
      SessionScope(controller: session, child: const _Probe()),
    );
    session.start();

    gateway.emit(const AuthUser(uid: 'uid-1', email: 'sara@example.com'));
    await settle(tester, () => session.isSignedIn);

    expect(find.text('home:Sara Ali'), findsOneWidget);
  });

  testWidgets('signing out returns to the auth flow', (tester) async {
    await tester.pumpWidget(
      SessionScope(controller: session, child: const _Probe()),
    );
    session.start();

    gateway.emit(const AuthUser(uid: 'uid-1', email: 'sara@example.com'));
    await settle(tester, () => session.isSignedIn);
    expect(find.text('home:Sara Ali'), findsOneWidget);

    await tester.runAsync(() => session.signOut());
    await settle(tester, () => session.status == SessionStatus.signedOut);

    expect(find.text('auth'), findsOneWidget);
    expect(find.text('home:Sara Ali'), findsNothing);
  });

  group('SearchScreen', _searchTests);
}

// ---------------------------------------------------------------------------
// Search screen: it renders whatever `GET /api/lawyers?search=` returns.
//
// This replaces the old behaviour where the list came from `ProductData()`
// sample rows and the text field was not connected to anything. The tests pin
// the three states that used to be impossible to reach: real results, an empty
// directory, and a failed request with a retry action.
// ---------------------------------------------------------------------------

/// Waits (in real time) for the screen's initial request to settle, then
/// renders one frame. `testWidgets` fakes timers, but the HTTP layer it awaits
/// is a real future, so the wait must happen inside `runAsync`.
Future<void> _settleSearch(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
  await tester.pump();
}

Widget _searchApp(SessionController session) {
  return SessionScope(
    controller: session,
    child: const MaterialApp(home: SearchScreen()),
  );
}

SessionController _searchSession({
  required Future<http.Response> Function(http.Request request, int attempt)
      handler,
}) {
  return SessionController(
    auth: AuthService(
      gateway: FakeAuthGateway(),
      api: testApiClient(
        handler: (request, attempt) async {
          if (request.url.path.contains('/categories')) {
            return supabaseOk([]);
          }
          return handler(request, attempt);
        },
      ),
    ),
  );
}

Map<String, dynamic> _lawyerJson(String name, String city) => {
      'id': 'lawyer-$name',
      'name': name,
      'specialty': 'Family law',
      'location': city,
      'rating': 4.5,
      'price': '250 EGP',
    };

void _searchTests() {
  testWidgets('renders the lawyers returned by the API', (tester) async {
    final session = _searchSession(
      handler: (_, __) async {
        final lawyers = [
          _lawyerJson('Ahmed Hassan', 'Cairo'),
          _lawyerJson('Mona Fahmy', 'Giza'),
        ];
        return supabaseOk(lawyers, headers: {'content-range': '0-${lawyers.length - 1}/${lawyers.length}'});
      },
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(_searchApp(session));
    await _settleSearch(tester);

    expect(find.text('Ahmed Hassan'), findsWidgets);
    expect(find.text('Mona Fahmy'), findsWidgets);
    // Real rows, not the old sample catalogue.
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('reports an empty directory instead of sample rows',
      (tester) async {
    final session = _searchSession(
      handler: (_, __) async => supabaseOk([], headers: {'content-range': '0--1/0'}),
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(_searchApp(session));
    await _settleSearch(tester);

    expect(find.text('No lawyers listed yet'), findsOneWidget);
  });

  testWidgets('a failed request shows the error and a retry action',
      (tester) async {
    final session = _searchSession(
      handler: (_, __) async => jsonError(500, 'Server exploded'),
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(_searchApp(session));
    await _settleSearch(tester);

    expect(find.text('Search failed'), findsOneWidget);
    expect(find.text('Server exploded'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
