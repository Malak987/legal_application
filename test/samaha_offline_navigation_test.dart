import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legalserviceapp/app_bootstrap.dart';
import 'package:legalserviceapp/config/supabase_client_config.dart';
import 'package:legalserviceapp/models/samaha_catalog.dart';
import 'package:legalserviceapp/services/samaha_repository.dart';
import 'package:legalserviceapp/state/samaha_controller.dart';
import 'package:legalserviceapp/views/authentication/login_screen.dart';
import 'package:legalserviceapp/views/configuration/supabase_config_error_screen.dart';
import 'package:legalserviceapp/views/home/homescreen.dart';
import 'package:legalserviceapp/views/samaha/samaha_entry_point.dart';
import 'package:legalserviceapp/views/samaha/samaha_pages.dart';
import 'package:legalserviceapp/views/samaha/samaha_strings.dart';
import 'package:legalserviceapp/views/samaha/samaha_widgets.dart';

import 'support/samaha_fixtures.dart';

Future<SamahaController> controllerFor(String language) async {
  final controller = SamahaController(
    loader: SamahaRepository(bundle: SamahaTestBundle()).fetchCatalog,
    language: language,
  );
  addTearDown(controller.dispose);
  await controller.load();
  return controller;
}

Future<void> pumpDirectoryWidget(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
  double scale = 1,
  bool app = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    DefaultAssetBundle(
      bundle: SamahaTestBundle(),
      child:
          app
              ? child
              : MaterialApp(
                builder:
                    (context, page) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: page!,
                    ),
                home: child,
              ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['en', 'ar']) {
    for (final companyId in [
      'company_group',
      'company_legal',
      'company_debt',
      'company_businessmen',
      'company_immigration',
      'company_translation',
    ]) {
      testWidgets(
        '$language $companyId has complete scoped sections and its website action last',
        (tester) async {
          final controller = await controllerFor(language);
          final company = controller.catalog!.company(companyId)!;
          final opened = <Uri>[];
          final s = SamahaStrings(language);
          await pumpDirectoryWidget(
            tester,
            SamahaDetailPage(
              controller: controller,
              companyId: companyId,
              opener: (uri) async {
                opened.add(uri);
                return true;
              },
            ),
          );
          expect(find.text(s.servicesAndSpecializations), findsOneWidget);
          expect(find.text(s.foundersAndTeam), findsOneWidget);
          expect(find.text(s.noFounders), findsOneWidget);
          expect(find.text(s.contacts), findsOneWidget);
          expect(find.text(s.faqs), findsOneWidget);
          expect(find.text(s.branches), findsWidgets);
          for (final entry in controller.catalog!.entries.where(
            (entry) =>
                entry.kind == SamahaEntryKind.service ||
                entry.kind == SamahaEntryKind.person,
          )) {
            expect(
              find.byKey(ValueKey('samaha-entry-${entry.id}')),
              entry.companyId == companyId ? findsOneWidget : findsNothing,
              reason: 'Never borrow ${entry.id} from another company',
            );
          }
          final profile = tester.widget<Column>(
            find.byKey(ValueKey('samaha-company-profile-$companyId')),
          );
          expect(profile.children.last, isA<SamahaWebsiteFooter>());
          final button = find.byKey(ValueKey('samaha-website-$companyId'));
          expect(find.text(s.officialWebsite), findsOneWidget);
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          final control = tester.widget<FilledButton>(button);
          expect(control.onPressed != null, company.website != null);
          expect(
            tester.getTopLeft(button).dy,
            greaterThan(tester.getTopLeft(find.byType(SamahaSources)).dy),
          );
          if (company.website == null) {
            expect(find.text(s.websiteUnavailable), findsOneWidget);
            await tester.tap(button);
            expect(opened, isEmpty);
          } else {
            await tester.tap(button);
            await tester.pumpAndSettle();
            expect(opened, [company.website]);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'a public entry navigates directory to company to person and back without a session',
    (tester) async {
      await pumpDirectoryWidget(
        tester,
        const Scaffold(body: SamahaDirectoryEntryButton()),
      );
      await tester.tap(find.byKey(const ValueKey('samaha-public-entry')));
      await tester.pumpAndSettle();
      expect(find.byType(SamahaDirectoryPage), findsOneWidget);
      final company = find.byWidgetPredicate(
        (widget) =>
            widget is SamahaCompanyCard && widget.company.id == 'company_legal',
      );
      await tester.ensureVisible(company);
      await tester.tap(company);
      await tester.pumpAndSettle();
      expect(find.byType(SamahaDetailPage), findsOneWidget);
      final person = find.byKey(
        const ValueKey('samaha-entry-team_ac6ff7a2d5ac93'),
      );
      await tester.ensureVisible(person);
      await tester.pumpAndSettle();
      await tester.tap(person);
      await tester.pumpAndSettle();
      expect(find.text('Yazan Al bakheet'), findsWidgets);
      expect(find.text('Lawyer – partner- Jordan office'), findsOneWidget);
      expect(find.text(const SamahaStrings('en').noBiography), findsOneWidget);
      expect(
        find.text(const SamahaStrings('en').noSpecialties),
        findsOneWidget,
      );
      expect(
        find.textContaining('not registered Legal platform lawyer accounts'),
        findsOneWidget,
      );
      expect(find.text('Book Now'), findsNothing);
      expect(find.text('Message'), findsNothing);
      expect(find.byType(HomePage), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('samaha-company-profile-company_legal')),
        findsOneWidget,
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(SamahaDirectoryPage), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('samaha-public-entry')), findsOneWidget);
    },
  );

  testWidgets(
    'invalid operational config still permits local browsing and creates no session',
    (tester) async {
      var sessionCalls = 0;
      final app = bootstrapApp(
        config: SupabaseClientConfig.resolve(url: '', anonKey: ''),
        createSession: (_) {
          sessionCalls++;
          throw StateError('Must not create a session');
        },
        buildApp:
            (_) => throw StateError('Protected application must not start'),
      );
      await pumpDirectoryWidget(tester, app, app: true);
      expect(find.byType(SupabaseConfigErrorScreen), findsOneWidget);
      final button = find.byKey(const ValueKey('samaha-public-entry'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(SamahaDirectoryPage), findsOneWidget);
      expect(find.byType(SamahaCompanyCard), findsNWidgets(6));
      expect(find.byType(HomePage), findsNothing);
      expect(sessionCalls, 0);
    },
  );

  testWidgets(
    'sign-in offers the public directory without submitting credentials or opening home',
    (tester) async {
      // The legacy sign-in form is intentionally not restyled. This flow test
      // uses tablet width; directory layouts are separately exercised at 320px
      // with 2x text in both the existing and new responsive tests.
      await pumpDirectoryWidget(
        tester,
        const LoginScreen(),
        size: const Size(800, 1000),
      );
      final button = find.byKey(const ValueKey('samaha-public-entry'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(SamahaDirectoryPage), findsOneWidget);
      expect(find.byType(HomePage), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
    },
  );

  testWidgets(
    'local asset error and recovery never tell the user to connect to Supabase',
    (tester) async {
      final bundle = SamahaTestBundle();
      const key = '${SamahaRepository.assetRoot}companies.json';
      final original = bundle.content.remove(key)!;
      await pumpDirectoryWidget(
        tester,
        SamahaOfflineDirectory(
          language: 'ar',
          repository: SamahaRepository(bundle: bundle),
        ),
      );
      const s = SamahaStrings('ar');
      expect(find.text(s.assetHelp), findsOneWidget);
      expect(find.textContaining('يرجى التحقق من الاتصال'), findsNothing);
      bundle.content[key] = original;
      await tester.tap(find.text(s.retry));
      await tester.pumpAndSettle();
      expect(find.byType(SamahaCompanyCard), findsNWidgets(6));
    },
  );

  for (final size in [
    const Size(320, 740),
    const Size(800, 1024),
    const Size(1440, 1000),
  ]) {
    testWidgets(
      'Arabic profile at $size with large text uses a local font and no overflow',
      (tester) async {
        final controller = await controllerFor('ar');
        await pumpDirectoryWidget(
          tester,
          SamahaDetailPage(
            controller: controller,
            companyId: 'company_translation',
          ),
          size: size,
          scale: size.width == 320 ? 2 : 1.3,
        );
        final heading = find.text(const SamahaStrings('ar').overview);
        expect(Directionality.of(tester.element(heading)), TextDirection.rtl);
        expect(
          Theme.of(tester.element(heading)).textTheme.bodyMedium!.fontFamily,
          'DirectoryArabic',
        );
        final button = find.byKey(
          const ValueKey('samaha-website-company_translation'),
        );
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        expect(tester.getRect(button).right, lessThanOrEqualTo(size.width));
        expect(tester.getRect(button).left, greaterThanOrEqualTo(0));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'default official-site launcher requests an external application, not a webview',
    (tester) async {
      final launches = <MethodCall>[];
      const channels = [
        MethodChannel('plugins.flutter.io/url_launcher'),
        MethodChannel('plugins.flutter.io/url_launcher_linux'),
      ];
      for (final channel in channels) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            launches.add(call);
            return true;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
      }
      final controller = await controllerFor('en');
      await pumpDirectoryWidget(
        tester,
        SamahaDetailPage(
          controller: controller,
          companyId: 'company_translation',
        ),
      );
      final button = find.byKey(
        const ValueKey('samaha-website-company_translation'),
      );
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      final call = launches.singleWhere((call) => call.method == 'launch');
      final arguments = call.arguments as Map;
      expect(arguments['url'], 'https://samaha-translations.com/');
      expect(arguments['useSafariVC'], isNot(true));
      expect(arguments['useWebView'], isNot(true));
    },
  );

  testWidgets(
    'an official website launch failure is reported without navigation to another site',
    (tester) async {
      final controller = await controllerFor('en');
      var calls = 0;
      await pumpDirectoryWidget(
        tester,
        SamahaDetailPage(
          controller: controller,
          companyId: 'company_translation',
          opener: (uri) async {
            calls++;
            throw StateError('No external browser');
          },
        ),
      );
      final button = find.byKey(
        const ValueKey('samaha-website-company_translation'),
      );
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pump();
      expect(calls, 1);
      expect(find.text(const SamahaStrings('en').linkFailed), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('samaha-company-profile-company_translation'),
        ),
        findsOneWidget,
      );
    },
  );
}
