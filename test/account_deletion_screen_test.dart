import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:legalserviceapp/state/session_controller.dart';
import 'package:legalserviceapp/views/authentication/login_screen.dart';
import 'package:legalserviceapp/views/profile/delete_account.dart';
import 'package:legalserviceapp/views/profile/profile_screen.dart';

import 'support/deletion_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Profile screen entry point', () {
    testWidgets('offers an Arabic "حذف الحساب" action that opens the screen', (
      tester,
    ) async {
      await pumpDeletionHarness(
        tester,
        const ProfileScreen(),
        handler: (request, _) async => http.Response('{}', 200),
      );

      final entry = find.text('حذف الحساب');
      await tester.scrollUntilVisible(entry, 200);
      expect(entry, findsOneWidget);

      await tester.tap(entry);
      await settleDeletion(tester);
      expect(find.byType(DeleteAccountScreen), findsOneWidget);
      // The destructive button exists but is disabled until the word is typed.
      final button = tester.widget<ElevatedButton>(
        find.byKey(const ValueKey('delete-account-submit')),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('DeleteAccountScreen', () {
    Future<DeletionHarness> pumpScreen(
      WidgetTester tester, {
      required Future<http.Response> Function(http.Request, int) handler,
    }) => pumpDeletionHarness(tester, const DeleteAccountScreen(), handler: handler);

    testWidgets('the destructive button stays disabled without the word', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        handler: (request, _) async => http.Response('{}', 200),
      );
      ElevatedButton button() => tester.widget<ElevatedButton>(
        find.byKey(const ValueKey('delete-account-submit')),
      );
      expect(button().onPressed, isNull);

      await tester.enterText(
        find.byKey(const ValueKey('delete-account-confirmation')),
        'حذ',
      );
      await tester.pump();
      expect(button().onPressed, isNull);

      await tester.enterText(
        find.byKey(const ValueKey('delete-account-confirmation')),
        'حذف',
      );
      await tester.pump();
      expect(button().onPressed, isNotNull);
    });

    testWidgets('a first tap only opens a confirmation dialog', (tester) async {
      var calls = 0;
      final h = await pumpScreen(
        tester,
        handler: (request, _) async {
          calls++;
          return http.Response(jsonEncode({'deleted': true}), 200);
        },
      );
      await tester.enterText(
        find.byKey(const ValueKey('delete-account-confirmation')),
        'حذف',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('delete-account-submit')));
      await tester.pumpAndSettle();

      expect(find.text('تأكيد الحذف النهائي'), findsOneWidget);
      expect(calls, 0, reason: 'the first tap must not delete anything');

      // Cancelling the dialog leaves the session untouched.
      await tester.tap(
        find.byKey(const ValueKey('delete-account-dialog-cancel')),
      );
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(h.session.isSignedIn, isTrue);
    });

    testWidgets('confirming deletes and lands on the sign-in screen', (
      tester,
    ) async {
      var calls = 0;
      final h = await pumpScreen(
        tester,
        handler: (request, _) async {
          calls++;
          return http.Response(jsonEncode({'deleted': true}), 200);
        },
      );
      await tester.enterText(
        find.byKey(const ValueKey('delete-account-confirmation')),
        'حذف',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('delete-account-submit')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('delete-account-dialog-confirm')),
      );
      await settleDeletion(tester);

      // The route replacement animates; drive the fake clock to completion
      // before asserting what is left in the tree.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(calls, 1);
      expect(h.session.status, SessionStatus.signedOut);
      expect(find.byType(LoginScreen), findsOneWidget);
      // No authenticated route survives behind the sign-in screen.
      expect(find.byType(DeleteAccountScreen), findsNothing);
    });

    testWidgets('a failure shows an error and does not navigate', (
      tester,
    ) async {
      final h = await pumpScreen(
        tester,
        handler: (request, _) async => http.Response(
          jsonEncode({
            'code': 'ACCOUNT_DELETE_FAILED',
            'message': 'could not delete',
          }),
          502,
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('delete-account-confirmation')),
        'حذف',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('delete-account-submit')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('delete-account-dialog-confirm')),
      );
      await settleDeletion(tester);

      expect(find.byKey(const ValueKey('delete-account-error')), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byType(DeleteAccountScreen), findsOneWidget);
      expect(h.session.isSignedIn, isTrue);
    });

    testWidgets('shows a loading state while the request is in flight', (
      tester,
    ) async {
      final gate = Completer<void>();
      await pumpScreen(
        tester,
        handler: (request, _) async {
          await gate.future;
          return http.Response(jsonEncode({'deleted': true}), 200);
        },
      );
      await tester.enterText(
        find.byKey(const ValueKey('delete-account-confirmation')),
        'حذف',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('delete-account-submit')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('delete-account-dialog-confirm')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('جارٍ حذف الحساب…'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(
        find.byKey(const ValueKey('delete-account-submit')),
      );
      expect(button.onPressed, isNull, reason: 'no second submission');

      gate.complete();
      await settleDeletion(tester);
      expect(find.text('جارٍ حذف الحساب…'), findsNothing);
    });

    testWidgets('renders right-to-left', (tester) async {
      await pumpScreen(
        tester,
        handler: (request, _) async => http.Response('{}', 200),
      );
      expect(
        Directionality.of(
          tester.element(find.byKey(const ValueKey('delete-account-submit'))),
        ),
        TextDirection.rtl,
      );
    });
  });
}
