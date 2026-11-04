import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legalserviceapp/models/samaha_catalog.dart';
import 'package:legalserviceapp/state/samaha_controller.dart';
import 'package:legalserviceapp/views/samaha/samaha_pages.dart';
import 'package:legalserviceapp/views/samaha/samaha_strings.dart';
import 'package:legalserviceapp/views/samaha/samaha_widgets.dart';
import 'support/samaha_fixtures.dart';

// The pre-fix real-data probe fails first in ScrollPosition.restoreScrollOffset:
// ExpansionTile writes bool into the unkeyed selectable's PageStorage address.
// After the failed mount, _InactiveElements.remove asserts on subsequent builds.
// This suite keeps selection, expansion and scrolling enabled: no suppression.
void main() {
  for (final language in ['en', 'ar']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets(
        '$language $width provenance expand, select, rebuild, pop and reopen',
        (tester) async {
          final oldFatal = WidgetController.hitTestWarningShouldBeFatal;
          WidgetController.hitTestWarningShouldBeFatal = true;
          addTearDown(
            () => WidgetController.hitTestWarningShouldBeFatal = oldFatal,
          );
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final catalog = SamahaCatalog.fromJson(samahaFixture());
          final controller = SamahaController(
            loader: () async => catalog,
            language: language,
          );
          await controller.load();
          addTearDown(controller.dispose);
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder:
                    (context) => Scaffold(
                      body: TextButton(
                        key: const ValueKey('open-profile'),
                        onPressed:
                            () => openSamahaEntry(
                              context,
                              controller,
                              'team_ac6ff7a2d5ac93',
                            ),
                        child: const Text('Open profile'),
                      ),
                    ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          Finder heading() => find.descendant(
            of: find.byType(SamahaSources),
            matching: find.text(SamahaStrings(controller.language).sources),
          );
          Future<void> toggle() async {
            await tester.ensureVisible(heading());
            await tester.pumpAndSettle();
            await tester.tap(heading());
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }

          for (var cycle = 0; cycle < 3; cycle++) {
            await tester.tap(find.byKey(const ValueKey('open-profile')));
            await tester.pumpAndSettle();
            await toggle();
            final texts = find.descendant(
              of: find.byType(SamahaSources),
              matching: find.byType(SelectableText),
            );
            expect(texts, findsWidgets);
            await tester.ensureVisible(texts.first);
            await tester.pumpAndSettle();
            await tester.tap(texts.first);
            await tester.pumpAndSettle();
            controller.setLanguage(controller.language == 'en' ? 'ar' : 'en');
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await toggle(); // collapse
            expect(
              find.descendant(
                of: find.byType(SamahaSources),
                matching: find.byType(SelectableText),
              ),
              findsNothing,
            );
            await toggle(); // reopen
            await controller.load();
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.tap(find.byType(BackButton));
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('open-profile')), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    }
  }

  testWidgets(
    'storage types are isolated: list offset, expansion bool and source selection',
    (tester) async {
      final bucket = PageStorageBucket();
      const url = 'https://samaha-group.com/team/';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageStorage(
              bucket: bucket,
              child: ListView(
                key: const PageStorageKey('outer-list'),
                children: [
                  const SizedBox(height: 500),
                  SamahaSources(
                    sources: [
                      const SamahaSource(
                        recordId: 'test-source',
                        archiveMember: 'test',
                        url: url,
                        language: 'en',
                      ),
                    ],
                    language: 'en',
                  ),
                  const SizedBox(height: 600),
                ],
              ),
            ),
          ),
        ),
      );
      final title = find.text('Sources & provenance');
      await tester.ensureVisible(title);
      await tester.pumpAndSettle();
      await tester.tap(title);
      await tester.pumpAndSettle();
      final tile = find.byKey(const PageStorageKey('samaha-sources:$url'));
      expect(bucket.readState(tester.element(tile)), isTrue);
      final scrollables = find.byType(Scrollable);
      for (final element in scrollables.evaluate()) {
        final state = (element as StatefulElement).state as ScrollableState;
        final stored = bucket.readState(state.storageContext);
        expect(
          stored == null || stored is double,
          isTrue,
          reason: 'No ScrollPosition may read an ExpansionTile bool.',
        );
      }
      expect(
        find.byKey(const PageStorageKey('samaha-source-url:$url')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending directory reload after leaving/disposal cannot notify stale widgets',
    (tester) async {
      final pending = Completer<SamahaCatalog>();
      final controller = SamahaController(loader: () => pending.future);
      await tester.pumpWidget(
        MaterialApp(home: SamahaDirectoryPage(controller: controller)),
      );
      final load = controller.load();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      pending.complete(SamahaCatalog.fromJson(samahaFixture()));
      await load;
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
