import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:legalserviceapp/models/app_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legalserviceapp/services/auth_service.dart';
import 'package:legalserviceapp/services/api_client.dart';
import 'package:legalserviceapp/services/user_cache_service.dart';
import 'package:legalserviceapp/state/session_controller.dart';
import 'package:legalserviceapp/views/authentication/registration_validation.dart';
import 'package:legalserviceapp/views/authentication/signup_sreeen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'registration is RTL and stays disabled pending backend deployment',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          supportedLocales: [Locale('en'), Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: SignUpScreen(),
        ),
      );
      expect(find.text('إنشاء حساب'), findsOneWidget);
      expect(
        find.text('التسجيل غير متاح حاليًا. يرجى المحاولة لاحقًا.'),
        findsOneWidget,
      );
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNull);
      final formFields =
          tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(formFields, hasLength(4));
      expect(formFields[2].obscureText, isTrue);
      expect(formFields[3].obscureText, isTrue);
      await tester.tap(find.byTooltip('إظهار كلمة المرور'));
      await tester.pump();
      final fieldsAfter =
          tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fieldsAfter[2].obscureText, isFalse);
      expect(fieldsAfter[3].obscureText, isTrue);
    },
  );

  testWidgets('English registration is LTR', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        supportedLocales: [Locale('en'), Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: SignUpScreen(),
      ),
    );
    expect(find.text('Create account'), findsNWidgets(2));
    expect(
      Directionality.of(tester.element(find.byType(TextFormField).first)),
      TextDirection.ltr,
    );
    expect(
      RegistrationValidation.email('invalid', arabic: false),
      'Enter a valid email address.',
    );
  });

  test(
    'server roles recognize new users and legacy clients without privilege',
    () {
      for (final role in ['user', 'client']) {
        final profile = AppProfile(uid: 'id', role: role);
        expect(profile.hasValidRole, isTrue);
        expect(profile.isClient, isTrue);
        expect(profile.isLawyer, isFalse);
        expect(profile.isAdmin, isFalse);
      }
      for (final role in ['', 'unknown', 'USER', 'owner', 'admin', 'lawyer']) {
        expect(AppProfile(uid: 'id', role: role).isClient, isFalse);
      }
    },
  );

  test('user server profile can sign in; no local role is supplied', () async {
    final gateway = FakeAuthGateway(
      initialUser: const AuthUser(uid: 'uid-1', email: 'sara@example.com'),
    );
    final api = testApiClient(
      handler: (_, __) async => jsonOk(profileJson(role: 'user')),
    );
    final auth = AuthService(gateway: gateway, api: api);
    expect((await auth.loadProfile()).role, 'user');
    auth.dispose();
  });

  test('Arabic registration field validators fail closed', () {
    expect(RegistrationValidation.name(' '), isNotNull);
    expect(RegistrationValidation.name('سارة علي'), isNull);
    for (final invalid in ['', 'sara@', '@example.com', 'a@b', 'a @b.com']) {
      expect(RegistrationValidation.email(invalid), isNotNull, reason: invalid);
    }
    expect(RegistrationValidation.email('sara@example.com'), isNull);
    expect(RegistrationValidation.password('12345'), isNotNull);
    expect(RegistrationValidation.password('123456'), isNull);
    expect(RegistrationValidation.confirmation('abc', 'abcd'), isNotNull);
    expect(RegistrationValidation.confirmation('abcd', 'abcd'), isNull);
  });

  test(
    'a forged cached role cannot open a session when profile fetch fails',
    () async {
      SharedPreferences.setMockInitialValues({
        'user_cache_uid-1': jsonEncode({
          'uid': 'uid-1',
          'name': 'Forged',
          'role': 'client',
        }),
      });
      final cache = UserCacheService(
        preferences: await SharedPreferences.getInstance(),
      );
      final gateway = FakeAuthGateway(
        initialUser: const AuthUser(uid: 'uid-1', email: 'sara@example.com'),
      );
      final api = testApiClient(
        handler: (_, __) async => jsonError(503, 'offline'),
      );
      final controller = SessionController(
        auth: AuthService(gateway: gateway, api: api, userCache: cache),
      );
      controller.start();
      for (var i = 0; i < 50 && controller.isResolving; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(controller.status, SessionStatus.profileUnavailable);
      expect(controller.isSignedIn, isFalse);
      expect(controller.profile, isNull);
      controller.dispose();
    },
  );

  test('confirmation-pending survives the signup null auth event', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/auth/v1/signup')) {
        return http.Response(
          jsonEncode({
            'user': {'id': 'uid-pending', 'email': 'sara@example.com'},
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    final gateway = SupabaseAuthGateway(
      client: client,
      supabaseUrl: 'https://qqfzbecwhewswkyxgebu.supabase.co',
      supabaseAnonKey: 'public-anon-key',
      authRedirectUrl: 'https://legal.example/auth/callback',
      allowClientSignup: true,
      sessionStore: MemoryAuthSessionStore(),
    );
    final api = ApiClient(
      client: client,
      supabaseUrl: 'https://qqfzbecwhewswkyxgebu.supabase.co',
      supabaseAnonKey: 'public-anon-key',
      idTokenProvider: () => gateway.getAccessToken(),
      currentUidProvider: () => gateway.currentUser?.uid,
    );
    final session = SessionController(
      auth: AuthService(gateway: gateway, api: api),
    );
    session.start();
    await Future<void>.delayed(Duration.zero);
    expect(
      await session.register(
        name: 'Sara',
        email: 'sara@example.com',
        password: '123456',
      ),
      isFalse,
    );
    expect(session.registrationErrorCode, 'email-confirmation-required');
    expect(session.registrationAccountCreated, isTrue);
    expect(session.status, SessionStatus.signedOut);
    session.dispose();
  });

  test(
    'registration rejects an incorrectly provisioned legacy client role',
    () async {
      final gateway = FakeAuthGateway();
      final api = testApiClient(
        uid: 'uid-new',
        handler:
            (_, __) async => jsonOk(profileJson(id: 'uid-new', role: 'client')),
      );
      final auth = AuthService(gateway: gateway, api: api);
      await expectLater(
        auth.register(
          name: 'Sara',
          email: 'sara@example.com',
          password: '123456',
        ),
        throwsA(isA<AuthException>()),
      );
      expect(gateway.currentUser, isNull);
      auth.dispose();
    },
  );

  test('unknown Supabase error details are not shown', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({'code': 'unexpected', 'message': 'SECRET INTERNAL DETAIL'}),
        400,
      ),
    );
    final gateway = SupabaseAuthGateway(
      client: client,
      supabaseUrl: 'https://qqfzbecwhewswkyxgebu.supabase.co',
      supabaseAnonKey: 'public-anon-key',
      sessionStore: MemoryAuthSessionStore(),
    );
    await expectLater(
      gateway.signIn(email: 'sara@example.com', password: 'secret123'),
      throwsA(
        isA<AuthException>().having(
          (e) => e.message,
          'message',
          isNot(contains('SECRET')),
        ),
      ),
    );
    gateway.dispose();
  });
}
