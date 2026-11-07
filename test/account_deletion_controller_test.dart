import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:legalserviceapp/services/api_client.dart';
import 'package:legalserviceapp/services/auth_service.dart';
import 'package:legalserviceapp/state/session_controller.dart';

import 'support/deletion_harness.dart';
import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApiClient.deleteMyAccount', () {
    test('sends an authenticated empty POST and validates the payload', () async {
      final requests = <http.Request>[];
      final api = testApiClient(
        handler: (request, _) async {
          requests.add(request);
          return http.Response(jsonEncode({'deleted': true}), 200);
        },
      );
      await api.deleteMyAccount();

      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/functions/v1/delete-my-account');
      expect(requests.single.headers['Authorization'], 'Bearer test-token');
      expect(requests.single.headers['apikey'], isNotNull);
      expect(requests.single.body, '{}');
    });

    test('surfaces the server code for a refusal', () async {
      final api = testApiClient(
        handler: (request, _) async => http.Response(
          jsonEncode({'code': 'ADMIN_ACCOUNT_PROTECTED', 'message': 'no'}),
          403,
        ),
      );
      try {
        await api.deleteMyAccount();
        fail('expected ApiException');
      } on ApiException catch (error) {
        expect(error.statusCode, 403);
        expect(error.code, 'ADMIN_ACCOUNT_PROTECTED');
      }
    });
  });

  group('SessionController.deleteAccount', () {
    testWidgets('calls the function with no user id in the body', (
      tester,
    ) async {
      final bodies = <String>[];
      final paths = <String>[];
      final h = await pumpDeletionHarness(
        tester,
        null,
        handler: (request, _) async {
          paths.add(request.url.path);
          bodies.add(request.body);
          return http.Response(
            jsonEncode({'deleted': true, 'profileRetained': true}),
            200,
          );
        },
      );

      await tester.runAsync(() => h.session.deleteAccount());
      await settleDeletion(tester);

      expect(paths, ['/functions/v1/delete-my-account']);
      // The contract: nothing in the request can be read as a deletion target.
      expect(bodies.single, '{}');
      for (final key in ['user_id', 'userId', 'profileId', 'auth_user_id']) {
        expect(bodies.single.contains(key), isFalse, reason: key);
      }
    });

    testWidgets('a confirmed deletion clears the session locally', (
      tester,
    ) async {
      final h = await pumpDeletionHarness(
        tester,
        null,
        handler: (request, _) async =>
            http.Response(jsonEncode({'deleted': true}), 200),
      );
      expect(h.session.isSignedIn, isTrue);

      final ok = await tester.runAsync(() => h.session.deleteAccount());
      await settleDeletion(tester);

      expect(ok, isTrue);
      expect(h.session.status, SessionStatus.signedOut);
      expect(h.session.profile, isNull);
      expect(h.session.user, isNull);
      expect(h.session.error, isNull);
      // The gateway was told to drop the credentials.
      expect(h.gateway.signOutCalls, 1);
      // The deleted identity is recorded so a stale token cannot be mistaken
      // for a live session.
      expect(h.session.deletedAccountUid, 'uid-1');
      expect(h.session.isDeletingAccount, isFalse);
    });

    testWidgets('a server error keeps the user signed in and reports failure', (
      tester,
    ) async {
      final h = await pumpDeletionHarness(
        tester,
        null,
        handler: (request, _) async => http.Response(
          jsonEncode({
            'code': 'ACCOUNT_DELETE_FAILED',
            'message': 'Your sign-in account could not be deleted.',
          }),
          502,
        ),
      );

      final ok = await tester.runAsync(() => h.session.deleteAccount());
      await settleDeletion(tester);

      expect(ok, isFalse);
      expect(h.session.status, SessionStatus.signedIn);
      expect(h.session.profile, isNotNull);
      expect(h.gateway.signOutCalls, 0);
      expect(h.session.deletedAccountUid, isNull);
      expect(h.session.error, contains('could not be deleted'));
    });

    testWidgets('a network failure never claims success', (tester) async {
      final h = await pumpDeletionHarness(
        tester,
        null,
        handler: (request, _) async {
          throw http.ClientException('connection reset', request.url);
        },
      );

      final ok = await tester.runAsync(() => h.session.deleteAccount());
      await settleDeletion(tester);

      expect(ok, isFalse);
      expect(h.session.status, SessionStatus.signedIn);
      expect(h.gateway.signOutCalls, 0);
      expect(h.session.error, isNotNull);
    });

    testWidgets('a 200 without `deleted: true` is treated as unconfirmed', (
      tester,
    ) async {
      final h = await pumpDeletionHarness(
        tester,
        null,
        handler: (request, _) async =>
            http.Response(jsonEncode({'deleted': false}), 200),
      );

      final ok = await tester.runAsync(() => h.session.deleteAccount());
      await settleDeletion(tester);

      expect(ok, isFalse);
      expect(h.session.status, SessionStatus.signedIn);
      expect(h.gateway.signOutCalls, 0);
    });

    testWidgets('a lawyer refusal is explained without signing the user out', (
      tester,
    ) async {
      final h = await pumpDeletionHarness(
        tester,
        null,
        role: 'lawyer',
        handler: (request, _) async => http.Response(
          jsonEncode({
            'code': 'LAWYER_PROFILE_REQUIRES_DEACTIVATION',
            'message': 'Deactivate your profile first.',
          }),
          409,
        ),
      );

      final ok = await tester.runAsync(() => h.session.deleteAccount());
      await settleDeletion(tester);

      expect(ok, isFalse);
      expect(h.session.error, contains('lawyer profile'));
      expect(h.session.status, SessionStatus.signedIn);
    });

    testWidgets('concurrent calls send exactly one request', (tester) async {
      var calls = 0;
      // No timers: the first request is held open by a completer so the
      // overlapping calls happen deterministically.
      final gate = Completer<void>();
      final h = await pumpDeletionHarness(
        tester,
        null,
        handler: (request, _) async {
          calls++;
          await gate.future;
          return http.Response(jsonEncode({'deleted': true}), 200);
        },
      );

      final pending = [
        h.session.deleteAccount(),
        h.session.deleteAccount(),
        h.session.deleteAccount(),
      ];
      gate.complete();
      final results = await tester.runAsync(() => Future.wait(pending));
      await settleDeletion(tester);

      expect(calls, 1, reason: 'a double tap must not delete twice');
      expect(results!.where((r) => r).length, 1);
      expect(h.session.status, SessionStatus.signedOut);
    });

    testWidgets('deleting while signed out is rejected locally', (
      tester,
    ) async {
      var calls = 0;
      final h = await pumpDeletionHarness(
        tester,
        null,
        signedIn: false,
        handler: (request, _) async {
          calls++;
          return http.Response(jsonEncode({'deleted': true}), 200);
        },
      );

      await tester.runAsync(() async {
        await expectLater(
          h.session.deleteAccount(),
          throwsA(isA<AuthException>()),
        );
      });
      expect(calls, 0);
    });
  });
}
