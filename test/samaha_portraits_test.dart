import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legalserviceapp/models/samaha_catalog.dart';
import 'package:legalserviceapp/services/samaha_repository.dart';
import 'package:legalserviceapp/views/samaha/samaha_widgets.dart';
import 'support/samaha_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '26 original assets decode and require the user declaration, not a verified licence',
    () async {
      final catalog = await SamahaRepository().fetchCatalog();
      expect(catalog.media.length, 26);
      for (final media in catalog.media) {
        final person = catalog.entry(media.entryId!)!;
        expect(person.kind, SamahaEntryKind.person);
        expect(media.altText.en, person.title.en);
        expect(media.sourcePageUrl, 'https://samaha-group.com/');
        expect(Uri.parse(media.originalImageUrl).host, 'samaha-group.com');
        expect(media.isSourceReference, isTrue);
        expect(
          media.isPermitted,
          isFalse,
          reason: 'Published does not mean licensed.',
        );
        expect(media.permissionEvidence, contains('2026-11-02'));
        expect(media.permissionEvidence, contains('user declaration'));
        expect(media.permissionEvidence, contains('no permission document'));
        expect(media.displayPolicy, 'user_declared_permission');
        final data = await rootBundle.load(media.assetPath);
        final codec = await ui.instantiateImageCodec(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 250);
        expect(frame.image.height, 350);
        frame.image.dispose();
        codec.dispose();
      }
    },
  );

  test(
    'live duplicates do not become extra profiles and ambiguous images remain withheld',
    () {
      final catalog = SamahaCatalog.fromJson(samahaFixture());
      final people = catalog.find(SamahaEntryKind.person);
      expect(people.length, 28);
      for (final name in ['Rushel virina', 'JENNA KADHUM', 'Amani Emara']) {
        expect(people.where((p) => p.title.en == name).length, 1);
      }
      for (final name in ['Hassan Ali', 'Sherif El-Sebaie']) {
        final person = people.singleWhere((p) => p.title.en == name);
        expect(catalog.image(person.companyId, entryId: person.id), isNull);
        expect(person.sourceNote.isEmpty, isFalse);
      }
      expect(
        people.where(
          (p) =>
              p.title.en == 'Hussein bayoumi' || p.title.en == 'Osheen Hamdy',
        ),
        isEmpty,
      );
      final amani = people.singleWhere((p) => p.title.en == 'Amani Emara');
      expect(amani.role.isEmpty, isTrue);
      expect(amani.roleVariants.length, 2);
      expect(
        people.every((p) => p.body.isEmpty && p.specialties.isEmpty),
        isTrue,
      );
    },
  );

  test(
    'reference display requires exact provenance, subject binding and an explicit rights policy',
    () {
      for (final change
          in <String, Object?>{
            'rights_status': 'restricted',
            'display_policy': 'source_attributed_reference',
            'permission_evidence': '',
            'association_status': 'needs_review',
            'source_card_sha256': '',
            'original_image_url': 'https://example.invalid/unrelated.jpg',
            'source_page_url': 'http://samaha-group.com/',
            'media_role': 'logo',
            'asset_path': 'assets/images/samaha/../unrelated.jpg',
            'entry_id': 'team_3fdf7ddc2692ca',
          }.entries) {
        final data = samahaFixture();
        final original = Map<String, dynamic>.from(
          (data['media'] as List).firstWhere(
            (m) => m['entry_id'] == 'team_ac6ff7a2d5ac93',
          ),
        );
        original[change.key] = change.value;
        data['media'] = [original];
        expect(SamahaCatalog.fromJson(data).media, isEmpty, reason: change.key);
      }
    },
  );

  test(
    'original URLs survive in every team content record, including withheld photographs',
    () {
      final doc = jsonDecode(
        File('assets/data/samaha/team.json').readAsStringSync(),
      );
      for (final person in doc['people'] as List) {
        expect(
          person['details']['source_page_url'],
          'https://samaha-group.com/',
        );
        expect(
          (person['details']['original_image_url'] as String).startsWith(
            'https://samaha-group.com/wp-content/uploads/',
          ),
          isTrue,
        );
        expect(person['details']['image_rights_status'], 'unverified');
        expect(person.containsKey('auth_user_id'), isFalse);
        expect(person.containsKey('lawyer_id'), isFalse);
      }
    },
  );

  testWidgets(
    'missing or failed local portrait shows an honest neutral fallback, never a remote image',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SamahaImage(
              media: null,
              language: 'en',
              fallback: Icons.person_outline,
              size: 120,
              height: 144,
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      final fixture = samahaFixture();
      final media = SamahaMedia.fromJson(samahaMediaFixture(fixture));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SamahaImage(
              media: media,
              language: 'ar',
              fallback: Icons.person_outline,
              size: 120,
              height: 144,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
