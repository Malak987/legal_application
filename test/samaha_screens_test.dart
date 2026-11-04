import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:legalserviceapp/commonwidgets/caregivercategories.dart';
import 'package:legalserviceapp/models/samaha_catalog.dart';
import 'package:legalserviceapp/services/auth_service.dart';
import 'package:legalserviceapp/state/samaha_controller.dart';
import 'package:legalserviceapp/state/session_controller.dart';
import 'package:legalserviceapp/state/session_scope.dart';
import 'package:legalserviceapp/views/home/homescreen.dart';
import 'package:legalserviceapp/views/samaha/samaha_home_section.dart';
import 'package:legalserviceapp/views/samaha/samaha_pages.dart';
import 'package:legalserviceapp/views/samaha/samaha_strings.dart';
import 'package:legalserviceapp/views/samaha/samaha_widgets.dart';
import 'support/fakes.dart';
import 'support/samaha_fixtures.dart';

http.Response lawyerPage(
  List<Map<String, dynamic>> rows, {
  int total = 0,
  int offset = 0,
}) => http.Response(
  jsonEncode(rows),
  200,
  headers: {
    'content-type': 'application/json; charset=utf-8',
    'content-range':
        rows.isEmpty
            ? '*/$total'
            : '$offset-${offset + rows.length - 1}/$total',
  },
);
Map<String, dynamic> lawyer(int i) => {
  'id': 'lawyer-$i',
  'name': 'Existing Lawyer $i',
  'price': 'EGP 50',
  'rating': 4.5,
  'image': 'images/lawyer2.png',
  'specialty': 'Family law',
  'location': 'Sohag',
};

Future<void> pumpHome(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double scale = 1,
  String language = 'en',
  Future<http.Response> Function(http.Request)? lawyers,
  bool settle = true,
  bool operationalOffline = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.localeTestValue = Locale(language);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearLocaleTestValue);
  final api = testApiClient(
    handler: (request, _) async {
      expect(
        request.url.path,
        isNot(contains('samaha_')),
        reason: 'Directory content must never use the operational API',
      );
      if (operationalOffline) {
        return supabaseError(503, 'Operational services offline');
      }
      if (request.url.path.endsWith('legal_categories')) {
        return supabaseOk([
          {'id': 'family-law', 'name': 'Family law', 'slug': 'family-law'},
        ]);
      }
      if (request.url.path.endsWith('lawyers')) {
        return lawyers == null ? lawyerPage([]) : lawyers(request);
      }
      return supabaseOk([]);
    },
  );
  final gateway = FakeAuthGateway();
  final session = SessionController(
    auth: AuthService(gateway: gateway, api: api),
  );
  addTearDown(api.dispose);
  addTearDown(session.dispose);
  addTearDown(gateway.dispose);
  await tester.pumpWidget(
    DefaultAssetBundle(
      bundle: SamahaTestBundle(),
      child: SessionScope(
        controller: session,
        child: MaterialApp(
          builder:
              (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
          home: const HomePage(),
        ),
      ),
    ),
  );
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

Future<SamahaController> loadedController({
  String language = 'en',
  Map<String, dynamic>? data,
}) async {
  final controller = SamahaController(
    loader: () async => SamahaCatalog.fromJson(data ?? samahaFixture()),
    language: language,
  );
  addTearDown(controller.dispose);
  await controller.load();
  return controller;
}

Future<void> pumpPage(
  WidgetTester tester,
  Widget page, {
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder:
          (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
      home: page,
    ),
  );
  await tester.pumpAndSettle();
}

// The directory is now the last lazy sliver, not permanently visible at the
// top. Exercise the real scroll before every Home action, including returning
// to the language control after a directory route is popped.
Future<void> revealHome(WidgetTester tester, Finder target) async {
  final scrollable =
      find
          .descendant(
            of: find.byKey(const PageStorageKey('legal-home-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    target,
    450,
    scrollable: scrollable,
    maxScrolls: 40,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'home directory remains usable while all operational API reads fail',
    (tester) async {
      await pumpHome(tester, operationalOffline: true);
      expect(find.byType(SamahaCompanyCard), findsNWidgets(5));
      expect(find.textContaining('Operational services offline'), findsWidgets);
      await tester.ensureVisible(
        find.byKey(const ValueKey('samaha-company-company_legal')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('samaha-company-company_legal')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('samaha-company-company_legal')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('samaha-company-profile-company_legal')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('samaha-entry-team_ac6ff7a2d5ac93')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('reviewed phone and email actions preserve their exact targets', (
    tester,
  ) async {
    final catalog = SamahaCatalog.fromJson(samahaFixture());
    final entries = catalog.contacts('company_translation');
    final opened = <Uri>[];
    await pumpPage(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: SamahaContacts(
            entries: entries,
            language: 'en',
            opener: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      ),
    );
    for (final entry in entries) {
      final action = find.byKey(ValueKey('samaha-contact-${entry.id}'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
    }
    expect(opened, entries.map((entry) => entry.contact!.uri).toList());
    expect(opened.map((uri) => uri.scheme).toSet(), {'mailto', 'tel'});
  });
  testWidgets(
    'plain Arabic home headings inherit the bundled font, not a web fallback',
    (tester) async {
      await pumpHome(tester, language: 'ar');
      final heading = tester.element(find.text('الشركات والأقسام'));
      expect(DefaultTextStyle.of(heading).style.fontFamily, 'DirectoryArabic');
      final label = tester.element(
        find.text(const SamahaStrings('ar').offlineDirectory),
      );
      expect(DefaultTextStyle.of(label).style.fontFamily, 'DirectoryArabic');
      // Original Home typography is restored; Arabic still uses its bundled font.
      final operational = tester.element(find.text('الخدمات القانونية'));
      expect(Directionality.of(operational), TextDirection.rtl);
      expect(
        DefaultTextStyle.of(operational).style.fontFamily,
        'DirectoryArabic',
      );
    },
  );
  testWidgets(
    'original Home content precedes the single bottom company section',
    (tester) async {
      await pumpHome(tester);
      expect(find.byType(HomePage), findsOneWidget);
      expect(find.text('Companies & divisions'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('samaha-company-company_legal')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('samaha-company-company_translation')),
        findsOneWidget,
      );
      final section =
          tester
              .getTopLeft(find.byKey(const ValueKey('samaha-home-section')))
              .dy;
      final promotion =
          tester
              .getTopLeft(find.byKey(const ValueKey('legal-home-promotion')))
              .dy;
      expect(section, greaterThan(promotion));
      expect(
        section,
        greaterThan(
          tester.getBottomLeft(find.text('No services available yet.')).dy,
        ),
      );
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('samaha-company-company_legal')),
            )
            .dy,
        greaterThan(promotion),
      );
      expect(find.text('Find Best Lawyers with us'), findsOneWidget);
      expect(find.byType(LegalServiceCategories), findsOneWidget);
      expect(find.text('Legal Services'), findsOneWidget);
      expect(find.byIcon(Icons.menu_outlined), findsOneWidget);
      expect(find.byIcon(Icons.notifications), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'company cards open original-app routes and back returns to home',
    (tester) async {
      await pumpHome(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('samaha-company-company_legal')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('samaha-company-company_legal')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('samaha-company-company_legal')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SamahaDetailPage), findsOneWidget);
      expect(find.text('Samaha Lawyers & Legal Consultants'), findsWidgets);
      expect(find.text('Company enquiries'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(HomePage), findsOneWidget);
      await revealHome(tester, find.text('Legal Services'));
      expect(find.text('Legal Services'), findsOneWidget);
    },
  );
  testWidgets('umbrella group and all five divisions are navigable', (
    tester,
  ) async {
    await pumpHome(tester);
    await revealHome(tester, find.text('About the group'));
    await tester.tap(find.text('About the group'));
    await tester.pumpAndSettle();
    expect(find.text('Samaha Group'), findsWidgets);
    expect(find.byType(SamahaCompanyCard), findsNWidgets(5));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'services search and company filtering work in both source languages',
    (tester) async {
      final controller = await loadedController();
      await pumpPage(
        tester,
        SamahaDirectoryPage(
          controller: controller,
          kind: SamahaEntryKind.service,
        ),
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Samaha Legal Translation').last);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('samaha-entry-service_9a43143bf49c49')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('samaha-entry-service_9aebb5e88a6d4f')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('samaha-search')),
        'المستندات',
      );
      await tester.pumpAndSettle();
      expect(find.text('Document Translation Services'), findsOneWidget);
      expect(find.text('Interpretation Services'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('samaha-search')),
        'no-such-service',
      );
      await tester.pumpAndSettle();
      expect(
        find.text('No matching results. Try another name or division.'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'language changes RTL/LTR inside the feature and persist through navigation',
    (tester) async {
      await pumpHome(tester);
      await revealHome(tester, find.byKey(const ValueKey('samaha-language')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('samaha-language')));
      await tester.pumpAndSettle();
      expect(find.text('الشركات والأقسام'), findsOneWidget);
      expect(
        Directionality.of(tester.element(find.text('الشركات والأقسام'))),
        TextDirection.rtl,
      );
      expect(
        Directionality.of(tester.element(find.text('الخدمات القانونية'))),
        TextDirection.rtl,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('samaha-company-company_legal')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('samaha-company-company_legal')),
      );
      await tester.pumpAndSettle();
      expect(find.text('التواصل مع الشركة'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('الشركات والأقسام'), findsOneWidget);
      await revealHome(tester, find.byKey(const ValueKey('samaha-language')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('samaha-language')));
      await tester.pumpAndSettle();
      expect(find.text('Companies & divisions'), findsOneWidget);
    },
  );
  testWidgets(
    'team detail preserves published role and shows only its original source portrait',
    (tester) async {
      final controller = await loadedController(language: 'ar');
      await pumpPage(
        tester,
        SamahaDetailPage(
          controller: controller,
          entryId: 'team_3fdf7ddc2692ca',
        ),
      );
      expect(find.text('محمود الجامعي'), findsWidgets);
      expect(find.text('المدير المالي (CFO)'), findsOneWidget);
      expect(find.textContaining('سنوات'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image));
      final source =
          controller.catalog!.image(
            'company_legal',
            entryId: 'team_3fdf7ddc2692ca',
          )!;
      expect((image.image as AssetImage).assetName, source.assetPath);
      expect(source.isPermitted, isFalse);
      expect(source.isSourceReference, isTrue);
      expect(find.text('المكتب كما ورد في المصدر'), findsNothing);
    },
  );
  testWidgets(
    'missing translation explicitly falls back to the original source language',
    (tester) async {
      final data = samahaFixture();
      final entry = (data['entries'] as List).firstWhere(
        (e) => e['id'] == 'team_3fdf7ddc2692ca',
      );
      entry['title'] = {'en': 'Mahmoud Elgemeay'};
      final controller = await loadedController(language: 'ar', data: data);
      await pumpPage(
        tester,
        SamahaDetailPage(controller: controller, entryId: entry['id']),
      );
      expect(find.text('Mahmoud Elgemeay'), findsWidgets);
      expect(find.text('يُعرض بلغة المصدر المتاحة'), findsOneWidget);
    },
  );
  testWidgets('a direct detail route never displays an unapproved ID', (
    tester,
  ) async {
    final controller = await loadedController();
    await pumpPage(
      tester,
      SamahaDetailPage(controller: controller, entryId: 'team_61ff4e6788de4c'),
    );
    expect(
      find.text('This information is not available for publication.'),
      findsOneWidget,
    );
    expect(find.text('JENNA KADHUM'), findsNothing);
  });
  testWidgets(
    'published location stays unverified and the map action uses its evidenced target',
    (tester) async {
      final controller = await loadedController();
      final opened = <Uri>[];
      await pumpPage(
        tester,
        SamahaDetailPage(
          controller: controller,
          entryId: 'branch_cee76c848c472a',
          opener: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      );
      expect(
        find.textContaining('not confirmation of an operating office'),
        findsOneWidget,
      );
      expect(find.textContaining('Office No. 1001'), findsWidgets);
      expect(find.textContaining('Muscat'), findsNothing);
      final map = find.byKey(
        const ValueKey('samaha-contact-contact_c108d9924c5d9c'),
      );
      await tester.ensureVisible(map);
      await tester.pumpAndSettle();
      await tester.tap(map);
      await tester.pumpAndSettle();
      expect(opened.single.host, 'maps.google.com');
      expect(opened.single.queryParameters['q'], contains('Mansoura'));
    },
  );
  testWidgets(
    'failed external launch offers an honest failure and copy preserves the published value',
    (tester) async {
      final catalog = SamahaCatalog.fromJson(samahaFixture());
      final entry = catalog.entry('contact_e09ce871890365')!;
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpPage(
        tester,
        Scaffold(
          body: SamahaContacts(
            entries: [entry],
            language: 'en',
            opener: (_) async => false,
          ),
        ),
      );
      await tester.tap(find.text('Call'));
      await tester.pump();
      expect(find.text(const SamahaStrings('en').linkFailed), findsOneWidget);
      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(copied, '+971 4 578 0666');
    },
  );
  testWidgets(
    'loading, failure, retry and empty states are localized and visible',
    (tester) async {
      final pending = Completer<SamahaCatalog>();
      var calls = 0;
      final controller = SamahaController(
        language: 'ar',
        loader: () {
          calls++;
          if (calls == 1) return pending.future;
          return Future.value(
            SamahaCatalog.fromJson({
              'companies': [],
              'entries': [],
              'links': [],
              'media': [],
            }),
          );
        },
      );
      addTearDown(controller.dispose);
      final initial = controller.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SamahaHomeSection(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('جارٍ تحميل الدليل…'), findsOneWidget);
      pending.completeError(StateError('offline'));
      await initial;
      await tester.pumpAndSettle();
      expect(find.text('الدليل غير متاح حاليًا'), findsOneWidget);
      await tester.tap(find.text('إعادة تحميل الدليل'));
      await tester.pumpAndSettle();
      expect(
        find.text('لا تتوفر معلومات معتمدة للعرض هنا بعد.'),
        findsOneWidget,
      );
    },
  );
  testWidgets('wide home shows every division without horizontal hiding', (
    tester,
  ) async {
    await pumpHome(tester, size: const Size(1440, 1000));
    await revealHome(
      tester,
      find.byKey(const ValueKey('samaha-company-company_legal')),
    );
    for (final id in [
      'company_legal',
      'company_debt',
      'company_businessmen',
      'company_immigration',
      'company_translation',
    ]) {
      final rect = tester.getRect(find.byKey(ValueKey('samaha-company-$id')));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(1440));
      expect(rect.bottom, lessThan(1000));
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'narrow Arabic home and detail tolerate large accessibility text',
    (tester) async {
      await pumpHome(
        tester,
        size: const Size(320, 740),
        language: 'ar',
        scale: 2,
      );
      await revealHome(tester, find.text('الشركات والأقسام'));
      expect(find.text('الشركات والأقسام'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final company = find.byKey(
        const ValueKey('samaha-company-company_legal'),
      );
      await tester.ensureVisible(company);
      await tester.pumpAndSettle();
      await tester.tap(company);
      await tester.pumpAndSettle();
      expect(find.byType(SamahaDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('company card exposes a screen-reader activation action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpHome(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('samaha-company-company_legal')),
      );
      await tester.pumpAndSettle();
      final finder = find.bySemanticsLabel(
        RegExp(r'^Samaha Lawyers & Legal Consultants\.'),
      );
      expect(finder, findsOneWidget);
      expect(
        tester.getSemantics(finder),
        matchesSemantics(
          isButton: true,
          hasTapAction: true,
          label: tester.getSemantics(finder).label,
        ),
      );
    } finally {
      semantics.dispose();
    }
  });
  testWidgets('existing category filtering ignores a stale lawyer response', (
    tester,
  ) async {
    final stale = Completer<http.Response>();
    final filters = <String?>[];
    await pumpHome(
      tester,
      settle: false,
      lawyers: (request) async {
        final filter = request.url.queryParameters['category_id'];
        filters.add(filter);
        if (filter == null) return stale.future;
        return lawyerPage([lawyer(100)], total: 1);
      },
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.ensureVisible(find.text('Family law'));
    await tester.pump();
    await tester.tap(find.text('Family law'));
    await tester.pumpAndSettle();
    stale.complete(lawyerPage([lawyer(999)], total: 1));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Legal Services'));
    await tester.drag(
      find.byKey(const PageStorageKey('legal-home-scroll')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(filters, [null, 'eq.family-law']);
    expect(find.text('Existing Lawyer 100'), findsOneWidget);
    expect(find.text('Existing Lawyer 999'), findsNothing);
  });
  testWidgets(
    'existing pagination, retry and deduplication survive the scroll-layout change',
    (tester) async {
      var secondAttempts = 0;
      await pumpHome(
        tester,
        lawyers: (request) async {
          final offset = int.parse(
            request.url.queryParameters['offset'] ?? '0',
          );
          if (offset == 0) {
            return lawyerPage(List.generate(20, lawyer), total: 22);
          }
          secondAttempts++;
          if (secondAttempts == 1) {
            return supabaseError(503, 'More lawyers offline');
          }
          return lawyerPage([lawyer(19), lawyer(20)], total: 22, offset: 20);
        },
      );
      final scrollable =
          find
              .descendant(
                of: find.byKey(const PageStorageKey('legal-home-scroll')),
                matching: find.byType(Scrollable),
              )
              .first;
      await tester.scrollUntilVisible(
        find.text('Load more'),
        600,
        scrollable: scrollable,
        maxScrolls: 30,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(find.text('More lawyers offline'), findsOneWidget);
      await tester.ensureVisible(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('home-lawyer-lawyer-20')),
        300,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(secondAttempts, 2);
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      expect(
        (grid.delegate as SliverChildBuilderDelegate).estimatedChildCount,
        21,
      );
      // One-column cards are recycled outside the viewport. Check the final
      // old card and the new card by scrolling, not by requiring both mounted.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('home-lawyer-lawyer-19')),
        -200,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('home-lawyer-lawyer-19')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('home-lawyer-lawyer-20')),
        200,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('home-lawyer-lawyer-20')),
        findsOneWidget,
      );
      expect(find.text('Load more'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('every approved division card opens its own detail', (
    tester,
  ) async {
    await pumpHome(tester, size: const Size(1440, 1000));
    final catalog = SamahaCatalog.fromJson(samahaFixture());
    for (final company in catalog.divisions) {
      await revealHome(
        tester,
        find.byKey(ValueKey('samaha-company-${company.id}')),
      );
      await tester.tap(find.byKey(ValueKey('samaha-company-${company.id}')));
      await tester.pumpAndSettle();
      expect(find.text(company.name.en), findsWidgets);
      expect(find.byType(SamahaDetailPage), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
    }
  });
  testWidgets(
    'homepage services, team and location shortcuts navigate naturally',
    (tester) async {
      await pumpHome(tester);
      for (final kind in [
        SamahaEntryKind.service,
        SamahaEntryKind.person,
        SamahaEntryKind.branch,
      ]) {
        final button = find.byKey(ValueKey('samaha-open-${kind.name}'));
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.byType(SamahaDirectoryPage), findsOneWidget);
        expect(find.byKey(const ValueKey('samaha-search')), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }
    },
  );
}
