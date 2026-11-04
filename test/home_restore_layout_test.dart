import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legalserviceapp/commonwidgets/caregivercategories.dart';
import 'package:legalserviceapp/commonwidgets/home_widget.dart';
import 'package:legalserviceapp/commonwidgets/product_card.dart';
import 'package:legalserviceapp/constants/colors.dart';
import 'package:legalserviceapp/models/product_model.dart';
import 'package:legalserviceapp/views/home/details.dart';
import 'package:legalserviceapp/views/samaha/samaha_home_section.dart';
import 'package:legalserviceapp/views/samaha/samaha_pages.dart';
import 'package:legalserviceapp/views/settings/views/notifications.dart';

import 'samaha_screens_test.dart' show pumpHome, lawyerPage, lawyer;

Finder homeScroll() =>
    find
        .descendant(
          of: find.byKey(const PageStorageKey('legal-home-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;

Future<void> reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    450,
    scrollable: homeScroll(),
    maxScrolls: 35,
  );
  await tester.pumpAndSettle();
}

void main() {
  final oldFatal = WidgetController.hitTestWarningShouldBeFatal;
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDownAll(() => WidgetController.hitTestWarningShouldBeFatal = oldFatal);

  testWidgets('restore contract: original header icons and original banner', (
    tester,
  ) async {
    await pumpHome(tester, size: const Size(1280, 900));
    final header = find.byType(HomeWidgte);
    final menu = tester.widget<Icon>(
      find.descendant(of: header, matching: find.byIcon(Icons.menu_outlined)),
    );
    expect(menu.color, Colors.white);
    expect(
      find.descendant(of: header, matching: find.text('Home')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: header, matching: find.text('LEGAL')),
      findsNothing,
    );
    expect(
      find.descendant(of: header, matching: find.byIcon(Icons.balance)),
      findsNothing,
    );
    expect(
      find.descendant(of: header, matching: find.byIcon(Icons.notifications)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: header,
        matching: find.byIcon(Icons.notifications_outlined),
      ),
      findsNothing,
    );
    final background = tester.widget<Container>(
      find.byKey(const ValueKey('legal-home-header')),
    );
    final decoration = background.decoration! as BoxDecoration;
    expect((decoration.gradient! as LinearGradient).colors, [
      AppColors.buttonColor,
      Colors.blueAccent,
    ]);
    final circle = tester.widget<Container>(
      find.byKey(const ValueKey('home-original-notification-circle')),
    );
    final circleDecoration = circle.decoration! as BoxDecoration;
    expect(circleDecoration.shape, BoxShape.circle);
    expect(circleDecoration.color, Colors.white);
    expect(
      tester.getSize(
        find.byKey(const ValueKey('home-original-notification-circle')),
      ),
      const Size(42, 42),
    );
    final banner = find.byWidgetPredicate(
      (widget) =>
          widget is Image &&
          widget.image is ExactAssetImage &&
          (widget.image as ExactAssetImage).assetName == 'images/banner2.png',
    );
    expect(banner, findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      AppColors.bgColor,
    );
    expect(
      Theme.of(tester.element(header)).scaffoldBackgroundColor,
      isNot(AppColors.corporatePaper),
    );
    expect(
      tester
          .widget<LegalServiceCategories>(find.byType(LegalServiceCategories))
          .corporate,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'restore contract: Samaha is the single last Home section after lawyers',
    (tester) async {
      await pumpHome(
        tester,
        size: const Size(1280, 900),
        lawyers: (_) async => lawyerPage(List.generate(4, lawyer), total: 4),
      );
      expect(find.byKey(const ValueKey('samaha-language')), findsOneWidget);
      final scroll = tester.widget<CustomScrollView>(
        find.byKey(const PageStorageKey('legal-home-scroll')),
      );
      final last = scroll.slivers.last as SliverPadding;
      expect(last.child, isA<SliverToBoxAdapter>());
      expect(
        (last.child! as SliverToBoxAdapter).child,
        isA<SamahaHomeSection>(),
      );
      final promotion =
          tester
              .getTopLeft(find.byKey(const ValueKey('legal-home-promotion')))
              .dy;
      final category =
          tester.getTopLeft(find.byType(LegalServiceCategories)).dy;
      expect(promotion, lessThan(category));
      await reveal(tester, find.byKey(const ValueKey('home-lawyer-lawyer-3')));
      final lastCard =
          tester
              .getBottomLeft(find.byKey(const ValueKey('home-lawyer-lawyer-3')))
              .dy +
          tester.state<ScrollableState>(homeScroll()).position.pixels;
      await reveal(tester, find.byKey(const ValueKey('samaha-home-section')));
      final section =
          tester
              .getTopLeft(find.byKey(const ValueKey('samaha-home-section')))
              .dy +
          tester.state<ScrollableState>(homeScroll()).position.pixels;
      expect(section, greaterThan(lastCard));
      expect(find.byType(SamahaHomeSection), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in ['en', 'ar']) {
    for (final viewport in [
      const Size(1280, 900),
      const Size(800, 1024),
      const Size(600, 960),
      const Size(390, 844),
      const Size(320, 740),
    ]) {
      testWidgets(
        'restore grid $language ${viewport.width}: equal, ordered, readable columns',
        (tester) async {
          await pumpHome(
            tester,
            size: viewport,
            language: language,
            lawyers:
                (_) async => lawyerPage(List.generate(4, lawyer), total: 4),
          );
          await reveal(
            tester,
            find.byKey(const ValueKey('home-lawyer-lawyer-0')),
          );
          final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
          final delegate =
              grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
          final columns = viewport.width >= 600 ? 2 : 1;
          expect(delegate.crossAxisCount, columns);
          await reveal(
            tester,
            find.byKey(const ValueKey('home-lawyer-lawyer-0')),
          );
          final first = tester.getRect(
            find.byKey(const ValueKey('home-lawyer-lawyer-0')),
          );
          if (columns == 2) {
            final second = tester.getRect(
              find.byKey(const ValueKey('home-lawyer-lawyer-1')),
            );
            expect(first.top, closeTo(second.top, .01));
            expect(first.width, closeTo(second.width, .01));
            expect(
              language == 'ar'
                  ? first.left > second.left
                  : first.left < second.left,
              isTrue,
            );
            expect(
              (first.center.dx - second.center.dx).abs() - first.width,
              closeTo(16, .01),
            );
          } else {
            final firstBottom =
                first.bottom +
                tester.state<ScrollableState>(homeScroll()).position.pixels;
            await reveal(
              tester,
              find.byKey(const ValueKey('home-lawyer-lawyer-1')),
            );
            final second = tester.getRect(
              find.byKey(const ValueKey('home-lawyer-lawyer-1')),
            );
            expect(first.left, closeTo(second.left, .01));
            expect(first.width, closeTo(second.width, .01));
            expect(
              second.top +
                  tester.state<ScrollableState>(homeScroll()).position.pixels,
              greaterThan(firstBottom),
            );
          }
          expect(first.left, greaterThanOrEqualTo(0));
          expect(first.right, lessThanOrEqualTo(viewport.width));
          final card = tester.widget<ProductCard>(
            find.byKey(const ValueKey('home-lawyer-lawyer-1')),
          );
          expect(card.name, 'Existing Lawyer 1');
          expect(card.imagePath, 'images/lawyer2.png');
          expect(card.price, 'EGP 50');
          expect(card.rating, 4.5);
          expect(card.lawyer!.specialty, 'Family law');
          expect(
            Directionality.of(tester.element(find.byType(ProductCard).first)),
            language == 'ar' ? TextDirection.rtl : TextDirection.ltr,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
    for (final viewport in [const Size(320, 740), const Size(800, 1024)]) {
      testWidgets(
        'restore large-text $language ${viewport.width}: no clipped card content',
        (tester) async {
          await pumpHome(
            tester,
            size: viewport,
            language: language,
            scale: 2,
            lawyers:
                (_) async => lawyerPage(
                  List.generate(
                    2,
                    (i) => {
                      ...lawyer(i),
                      'name':
                          language == 'ar'
                              ? 'محامٍ للاختبار باسم طويل ومعلومات قانونية منشورة $i'
                              : 'A long published lawyer name retained in full for review $i',
                      'specialty':
                          language == 'ar'
                              ? 'قانون الشركات والعقود والتحكيم التجاري'
                              : 'Corporate law, contracts and commercial arbitration',
                      'price': 'EGP 123,456.00 / hour',
                    },
                  ),
                  total: 2,
                ),
          );
          await reveal(
            tester,
            find.byKey(const ValueKey('home-lawyer-lawyer-0')),
          );
          final delegate =
              tester.widget<SliverGrid>(find.byType(SliverGrid)).gridDelegate
                  as SliverGridDelegateWithFixedCrossAxisCount;
          expect(delegate.crossAxisCount, viewport.width >= 800 ? 2 : 1);
          final first = find.byKey(const ValueKey('home-lawyer-lawyer-0'));
          await reveal(tester, first);
          final rating = find.descendant(of: first, matching: find.text('4.5'));
          final price = find.descendant(
            of: first,
            matching: find.text('EGP 123,456.00 / hour'),
          );
          expect(rating, findsOneWidget);
          expect(price, findsOneWidget);
          final bounds = tester.getRect(first);
          for (final child in [rating, price]) {
            final rect = tester.getRect(child);
            expect(rect.left, greaterThanOrEqualTo(bounds.left));
            expect(rect.right, lessThanOrEqualTo(bounds.right));
            expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'restored Home actions preserve menu, notifications and company routes',
    (tester) async {
      final calls = <String>[];
      await pumpHome(
        tester,
        size: const Size(800, 1024),
        lawyers: (request) async {
          calls.add(request.method);
          return lawyerPage(List.generate(2, lawyer), total: 2);
        },
      );
      await tester.tap(find.byTooltip('Open menu'));
      await tester.pumpAndSettle();
      expect(find.text('Homepage'), findsOneWidget);
      expect(find.byIcon(Icons.home_outlined), findsOneWidget);
      // Close, rather than selecting a different account or route.
      tester.state<ScaffoldState>(find.byType(Scaffold).first).closeDrawer();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      expect(find.byType(GroceryNotifications), findsOneWidget);
      Navigator.of(tester.element(find.byType(GroceryNotifications))).pop();
      await tester.pumpAndSettle();
      await reveal(
        tester,
        find.byKey(const ValueKey('samaha-company-company_legal')),
      );
      await tester.tap(
        find.byKey(const ValueKey('samaha-company-company_legal')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SamahaDetailPage), findsOneWidget);
      expect(calls.every((method) => method == 'GET'), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ProductCard preserves original lawyer identity and detail/favorite actions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        var favorites = 0;
        final product = Product(
          id: 'layout-only-fixture',
          name: 'Published name',
          imagePath: 'images/lawyer2.png',
          price: 'EGP 50',
          specialty: 'Family law',
          rating: 4.5,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  height: 400,
                  child: ProductCard(
                    imagePath: product.imagePath,
                    name: product.name,
                    price: product.price,
                    rating: product.rating,
                    lawyer: product,
                    onTap:
                        () => Navigator.of(
                          tester.element(find.byType(ProductCard)),
                        ).push(
                          MaterialPageRoute<void>(
                            builder:
                                (_) => const Scaffold(
                                  body: Text('Original detail action'),
                                ),
                          ),
                        ),
                    onFavoriteTap: () => favorites++,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Family law'), findsOneWidget);
        final spokenLabel = tester.getSemantics(find.byType(ProductCard)).label;
        expect('Published name'.allMatches(spokenLabel).length, 1);
        await tester.tap(find.byIcon(Icons.favorite_border));
        await tester.pumpAndSettle();
        expect(favorites, 1);
        expect(find.byIcon(Icons.favorite), findsOneWidget);
        expect(find.text('Original detail action'), findsNothing);
        await tester.tap(find.text('Published name'));
        await tester.pumpAndSettle();
        expect(find.text('Original detail action'), findsOneWidget);
        expect(find.byType(LegalServiceDetailsScreen), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}
