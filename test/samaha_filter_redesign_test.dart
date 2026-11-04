import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legalserviceapp/constants/colors.dart';
import 'package:legalserviceapp/models/samaha_catalog.dart';
import 'package:legalserviceapp/state/samaha_controller.dart';
import 'package:legalserviceapp/views/samaha/samaha_pages.dart';
import 'package:legalserviceapp/views/samaha/samaha_strings.dart';
import 'package:legalserviceapp/views/samaha/samaha_widgets.dart';
import 'support/samaha_fixtures.dart';

void main() {
  test('corporate body and small accent text meet 4.5:1 contrast', () {
    double ratio(Color first, Color second) {
      final a = first.computeLuminance();
      final b = second.computeLuminance();
      return ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
    }

    for (final surface in [Colors.white, AppColors.corporatePaper]) {
      for (final text in [
        AppColors.corporateNavy,
        AppColors.corporateInk,
        AppColors.corporateMuted,
        AppColors.corporateBlue,
        AppColors.corporateGoldText,
      ]) {
        expect(ratio(text, surface), greaterThanOrEqualTo(4.5));
      }
    }
    expect(
      ratio(Colors.white, AppColors.corporateNavy),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      ratio(const Color(0xFFE7CB93), AppColors.corporateNavy),
      greaterThanOrEqualTo(4.5),
    );
  });

  for (final language in ['en', 'ar']) {
    testWidgets(
      'contacts share responsive card widths and reflow at 2x $language',
      (tester) async {
        final catalog = SamahaCatalog.fromJson(samahaFixture());
        final branch = catalog.find(SamahaEntryKind.branch).single;
        final contacts = catalog.contacts(
          branch.companyId,
          branchId: branch.id,
        );
        expect(contacts, hasLength(3));
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final width in [390.0, 1280.0]) {
          for (final scale in [1.0, 2.0]) {
            tester.view.physicalSize = Size(width, 900);
            await tester.pumpWidget(
              MaterialApp(
                theme: samahaTheme(ThemeData()),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 900),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: Directionality(
                    textDirection:
                        language == 'ar'
                            ? TextDirection.rtl
                            : TextDirection.ltr,
                    child: Scaffold(
                      body: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: SamahaContacts(
                          entries: contacts,
                          language: language,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final rects = [
              for (final contact in contacts)
                tester.getRect(
                  find.byKey(ValueKey('samaha-contact-card-${contact.id}')),
                ),
            ];
            expect(
              rects.every((r) => (r.width - rects.first.width).abs() < .01),
              isTrue,
            );
            expect(
              rects.every((r) => r.left >= 20 && r.right <= width - 19.99),
              isTrue,
            );
            if (width == 390 || scale == 2) {
              expect(rects.every((r) => (r.left - 20).abs() < .01), isTrue);
              expect(rects.last.top, greaterThan(rects.first.bottom));
            } else {
              expect(
                rects.every((r) => (r.top - rects.first.top).abs() < .01),
                isTrue,
              );
            }
            expect(tester.takeException(), isNull);
          }
        }
      },
    );
  }

  for (final language in ['en', 'ar']) {
    for (final width in [390.0, 1280.0]) {
      testWidgets('role, search, empty and reset controls $language / $width', (
        tester,
      ) async {
        final oldFatal = WidgetController.hitTestWarningShouldBeFatal;
        WidgetController.hitTestWarningShouldBeFatal = true;
        addTearDown(
          () => WidgetController.hitTestWarningShouldBeFatal = oldFatal,
        );
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = SamahaController(
          loader: () async => SamahaCatalog.fromJson(samahaFixture()),
          language: language,
        );
        addTearDown(controller.dispose);
        await controller.load();
        final s = SamahaStrings(language);
        await tester.pumpWidget(
          MaterialApp(
            home: SamahaDirectoryPage(
              controller: controller,
              kind: SamahaEntryKind.person,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final cards = find.byWidgetPredicate(
          (widget) =>
              widget is Material &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'samaha-entry-',
              ),
        );
        expect(cards, findsNWidgets(28));

        final partners = find.byKey(const ValueKey('samaha-role-partner'));
        await tester.ensureVisible(partners);
        await tester.pumpAndSettle();
        await tester.tap(partners);
        await tester.pumpAndSettle();
        expect(cards, findsNWidgets(4));
        expect(find.text('4 ${s.results}'), findsOneWidget);

        final search = find.byKey(const ValueKey('samaha-search'));
        await tester.ensureVisible(search);
        await tester.pumpAndSettle();
        await tester.enterText(search, 'Yazan');
        await tester.pumpAndSettle();
        expect(cards, findsOneWidget);
        expect(
          find.byKey(const ValueKey('samaha-entry-team_ac6ff7a2d5ac93')),
          findsOneWidget,
        );

        await tester.enterText(search, 'no-such-reviewed-profile');
        await tester.pumpAndSettle();
        expect(cards, findsNothing);
        expect(find.text(s.noResults), findsOneWidget);
        expect(find.text('0 ${s.results}'), findsOneWidget);

        final reset = find.text(s.clearFilters);
        await tester.ensureVisible(reset);
        await tester.pumpAndSettle();
        await tester.tap(reset);
        await tester.pumpAndSettle();
        expect(cards, findsNWidgets(28));
        expect(find.text('28 ${s.results}'), findsOneWidget);
        expect(tester.widget<TextField>(search).controller!.text, isEmpty);
        expect(find.text(s.clearFilters), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
