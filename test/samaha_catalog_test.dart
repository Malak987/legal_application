import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:legalserviceapp/models/samaha_catalog.dart';
import 'package:legalserviceapp/state/samaha_controller.dart';
import 'support/samaha_fixtures.dart';

void main() {
  group('Reviewed Samaha catalogue', () {
    test(
      'reviewed counts, preserved bilingual identities and source-attributed media',
      () {
        final catalog = SamahaCatalog.fromJson(samahaFixture());
        expect(catalog.companies.length, 6);
        expect(catalog.divisions.length, 5);
        expect(catalog.find(SamahaEntryKind.service).length, 22);
        expect(catalog.find(SamahaEntryKind.person).length, 28);
        expect(catalog.find(SamahaEntryKind.branch).length, 1);
        expect(catalog.find(SamahaEntryKind.faq).length, 3);
        expect(catalog.entries.length, 66);
        expect(catalog.links.length, 10);
        expect(catalog.media.length, 26);
        expect(
          catalog.company('company_legal')!.name.ar,
          'سماحة للمحاماة والاستشارات القانونية',
        );
        expect(
          catalog.entry('team_3fdf7ddc2692ca')!.title.en,
          'Mahmoud Elgemeay',
        );
        expect(catalog.entry('team_3fdf7ddc2692ca')!.role.en, 'CFO');
        expect(catalog.entry('team_3fdf7ddc2692ca')!.body.isEmpty, isTrue);
      },
    );
    test('moderation status is exact and unknown states fail closed', () {
      expect(PublicationStatus.parse('approved'), PublicationStatus.approved);
      expect(PublicationStatus.parse('excluded'), PublicationStatus.excluded);
      for (final value in [null, 'Approved', 'published', '', 'needs_review']) {
        expect(PublicationStatus.parse(value), PublicationStatus.needsReview);
      }
    });
    test('unreviewed malformed observations never enter the graph', () {
      final data = samahaFixture();
      (data['entries'] as List).add({
        'id': 'hidden',
        'publication_status': 'needs_review',
        'title': 13,
      });
      final catalog = SamahaCatalog.fromJson(data);
      expect(catalog.entries.length, 66);
      expect(catalog.entry('hidden'), isNull);
    });
    test('an unpublished umbrella hides all descendants', () {
      final data = samahaFixture();
      data['companies'][0]['publication_status'] = 'excluded';
      final catalog = SamahaCatalog.fromJson(data);
      expect(catalog.companies, isEmpty);
      expect(catalog.entries, isEmpty);
      expect(catalog.links, isEmpty);
    });
    test(
      'an unpublished company hides entries and relations without deletion',
      () {
        final data = samahaFixture();
        (data['companies'] as List).firstWhere(
              (r) => r['id'] == 'company_legal',
            )['publication_status'] =
            'needs_review';
        final catalog = SamahaCatalog.fromJson(data);
        expect(catalog.company('company_legal'), isNull);
        expect(
          catalog.entries.where((r) => r.companyId == 'company_legal'),
          isEmpty,
        );
        expect(catalog.links, isEmpty);
        expect((data['entries'] as List).length, 66);
      },
    );
    test('unpublished location cannot expose its contact actions', () {
      final data = samahaFixture();
      final branch = (data['entries'] as List).firstWhere(
        (r) => r['kind'] == 'branch',
      );
      branch['publication_status'] = 'needs_review';
      final catalog = SamahaCatalog.fromJson(data);
      expect(
        catalog.contacts('company_legal', branchId: branch['id']),
        isEmpty,
      );
      expect(catalog.contacts('company_legal').length, 7);
    });
    test('relationship endpoints must be approved, typed and same-company', () {
      final data = samahaFixture();
      final link = data['links'][0];
      link['company_id'] = 'company_translation';
      final catalog = SamahaCatalog.fromJson(data);
      expect(catalog.links.length, 9);
      expect(
        catalog
            .related('service_9a43143bf49c49')
            .every((e) => e.kind == SamahaEntryKind.faq),
        isTrue,
      );
    });
    test(
      'same-name profiles with distinct approved IDs are not auto-merged',
      () {
        final data = samahaFixture();
        final original = Map<String, dynamic>.from(
          (data['entries'] as List).firstWhere((r) => r['kind'] == 'person'),
        );
        original['id'] = 'test_distinct_observation';
        (data['entries'] as List).add(original);
        final catalog = SamahaCatalog.fromJson(data);
        expect(catalog.find(SamahaEntryKind.person).length, 29);
        expect(catalog.entry('test_distinct_observation'), isNotNull);
      },
    );
    test(
      'duplicate public IDs are invalid rather than silently deduplicated',
      () {
        final data = samahaFixture();
        (data['companies'] as List).add(data['companies'][0]);
        expect(() => SamahaCatalog.fromJson(data), throwsFormatException);
      },
    );
    test(
      'missing review provenance and malformed localized names fail closed',
      () {
        for (final mutation in ['source_refs', 'reviewed_at', 'name']) {
          final data = samahaFixture();
          data['companies'][0][mutation] =
              mutation == 'source_refs'
                  ? []
                  : mutation == 'name'
                  ? {'en': 14}
                  : null;
          expect(() => SamahaCatalog.fromJson(data), throwsFormatException);
        }
      },
    );
    test('language fallback preserves exact original spelling', () {
      const name = LocalizedContent(en: 'islam atris');
      expect(name.text('ar'), 'islam atris');
      expect(name.languageFor('ar'), 'en');
      expect(name.isFallback('ar'), isTrue);
      expect(const LocalizedContent(ar: 'اسم منشور').text('en'), 'اسم منشور');
    });
    test('search matches both source languages and published roles', () {
      final catalog = SamahaCatalog.fromJson(samahaFixture());
      expect(
        catalog.find(SamahaEntryKind.person, query: 'محمود').single.title.en,
        'Mahmoud Elgemeay',
      );
      expect(
        catalog.find(SamahaEntryKind.person, query: 'cfo').single.title.ar,
        'محمود الجامعي',
      );
      expect(
        catalog
            .find(SamahaEntryKind.service, companyId: 'company_translation')
            .length,
        6,
      );
      expect(
        catalog.find(SamahaEntryKind.person, companyId: 'company_debt'),
        isEmpty,
      );
    });
    test(
      'no invented portraits, offices, contact reassignment or biographies',
      () {
        final catalog = SamahaCatalog.fromJson(samahaFixture());
        final branch = catalog.find(SamahaEntryKind.branch).single;
        expect(branch.title.ar, 'فرع المنصورة');
        expect(branch.operationalStatus, 'unverified');
        expect(branch.address.en, contains('Office No. 1001'));
        expect(catalog.find(SamahaEntryKind.branch, query: 'مسقط'), isEmpty);
        expect(catalog.contacts('company_immigration'), isEmpty);
        expect(
          catalog.find(SamahaEntryKind.person).every((p) => p.body.isEmpty),
          isTrue,
        );
        expect(catalog.entry('team_3fdf7ddc2692ca')!.office.isEmpty, isTrue);
        expect(
          catalog.entry('team_ac6ff7a2d5ac93')!.office.en,
          'Jordan office',
        );
        expect(
          catalog.related('team_ac6ff7a2d5ac93'),
          isEmpty,
        ); // No inferred Amman assignment.
      },
    );
    test('unsafe website actions are disabled', () {
      for (final value in [
        'javascript:alert(1)',
        'file:///etc/passwd',
        'https://user:pass@example.test/',
        'https://example.test/a b',
      ]) {
        expect(samahaWebUri(value), isNull);
      }
      expect(samahaWebUri('https://samaha-group.com/'), isNotNull);
    });
    test(
      'phone actions preserve digits and reject silent country substitution',
      () {
        expect(
          SamahaContact.fromJson({
            'contact_kind': 'phone',
            'display_value': '+971 4 578 0666',
            'action_uri': 'tel:+97145780666',
          }).uri.toString(),
          'tel:+97145780666',
        );
        expect(
          () => SamahaContact.fromJson({
            'contact_kind': 'phone',
            'display_value': '+971 4 578 0666',
            'action_uri': 'tel:+201556666493',
          }),
          throwsFormatException,
        );
        expect(
          () => SamahaContact.fromJson({
            'contact_kind': 'email',
            'display_value': 'info@example.test',
            'action_uri': 'mailto:info@example.test?bcc=other@example.test',
          }),
          throwsFormatException,
        );
      },
    );
    test(
      'WhatsApp contact cannot inject a precomposed message or a different number',
      () {
        expect(
          () => SamahaContact.fromJson({
            'contact_kind': 'whatsapp',
            'display_value': '+971544447773',
            'action_uri':
                'https://api.whatsapp.com/send/?phone=971544447773&text=send-this',
          }),
          throwsFormatException,
        );
        expect(
          () => SamahaContact.fromJson({
            'contact_kind': 'whatsapp',
            'display_value': '+971544447773',
            'action_uri': 'https://wa.me/201556666493',
          }),
          throwsFormatException,
        );
      },
    );
    test(
      'unknown/restricted rights or missing permission/association hide media',
      () {
        for (final field in [
          'rights_status',
          'permission_evidence',
          'association_evidence',
          'original_sha256',
        ]) {
          final data = samahaFixture();
          final media = samahaMediaFixture(data);
          media[field] = field == 'rights_status' ? 'unknown' : '';
          data['media'] = [media];
          expect(SamahaCatalog.fromJson(data).media, isEmpty);
        }
      },
    );
    test(
      'media is allowed only for its reviewed subject and permitted rights',
      () {
        final data = samahaFixture();
        final media = samahaMediaFixture(data);
        data['media'] = [media];
        expect(SamahaCatalog.fromJson(data).media.length, 1);
        media['entry_id'] = 'service_9a43143bf49c49';
        expect(
          SamahaCatalog.fromJson(data).media,
          isEmpty,
        ); // Portrait is not a service image.
        media['entry_id'] = 'service_company_setup_scope';
        expect(
          SamahaCatalog.fromJson(data).media,
          isEmpty,
        ); // Another division.
      },
    );
    test('public lists are immutable', () {
      final catalog = SamahaCatalog.fromJson(samahaFixture());
      expect(() => catalog.companies.clear(), throwsUnsupportedError);
      expect(() => catalog.entries.clear(), throwsUnsupportedError);
    });
  });

  group('Bundled company and person contracts', () {
    test(
      'exact company website mapping includes honest unavailable states',
      () {
        final catalog = SamahaCatalog.fromJson(samahaFixture());
        const websites = <String, String?>{
          'company_group': 'https://samaha-group.com/',
          'company_legal': 'https://samaha-group.com/',
          'company_debt': null,
          'company_businessmen': null,
          'company_immigration': null,
          'company_translation': 'https://samaha-translations.com/',
        };
        for (final company in catalog.companies) {
          expect(
            company.website?.toString(),
            websites[company.id],
            reason: company.id,
          );
          expect(company.description.en, isNotEmpty);
          expect(company.description.ar, isNotEmpty);
          if (company.website == null) {
            expect(company.websiteUnavailableReason.en, isNotEmpty);
            expect(company.websiteUnavailableReason.ar, isNotEmpty);
          }
        }
      },
    );
    test('all services retain their explicit company association', () {
      final catalog = SamahaCatalog.fromJson(samahaFixture());
      const counts = {
        'company_group': 0,
        'company_legal': 12,
        'company_debt': 1,
        'company_businessmen': 2,
        'company_immigration': 1,
        'company_translation': 6,
      };
      for (final entry in counts.entries) {
        expect(
          catalog.find(SamahaEntryKind.service, companyId: entry.key).length,
          entry.value,
          reason: entry.key,
        );
      }
    });
    test(
      'published team categories do not create founders or registered lawyers',
      () {
        final catalog = SamahaCatalog.fromJson(samahaFixture());
        final people = catalog.find(SamahaEntryKind.person);
        expect(
          people.every((person) => person.companyId == 'company_legal'),
          isTrue,
        );
        expect(
          people.where(
            (person) => person.teamCategory == SamahaTeamCategory.founder,
          ),
          isEmpty,
        );
        expect(
          people.where(
            (person) => person.teamCategory == SamahaTeamCategory.lawyer,
          ),
          isEmpty,
        );
        expect(
          catalog.entry('team_ac6ff7a2d5ac93')!.teamCategory,
          SamahaTeamCategory.partner,
        );
        expect(
          people
              .where((p) => p.teamCategory == SamahaTeamCategory.partner)
              .length,
          4,
        );
        expect(
          people
              .where(
                (p) => p.teamCategory == SamahaTeamCategory.legalProfessional,
              )
              .length,
          11,
        );
        expect(
          people
              .where((p) => p.teamCategory == SamahaTeamCategory.other)
              .length,
          13,
        );
        expect(
          people.every(
            (person) => person.specialties.isEmpty && person.body.isEmpty,
          ),
          isTrue,
        );
        expect(
          catalog.entry('team_4567545e181b73'),
          isNull,
        ); // Unresolved founder byline, not silently merged.
      },
    );
    test('company contacts never leak from a sibling or a parent group', () {
      final catalog = SamahaCatalog.fromJson(samahaFixture());
      expect(catalog.contacts('company_legal').length, 7);
      expect(catalog.contacts('company_translation').length, 2);
      expect(
        catalog
            .contacts('company_legal', branchId: 'branch_cee76c848c472a')
            .length,
        3,
      );
      for (final id in [
        'company_group',
        'company_debt',
        'company_businessmen',
        'company_immigration',
      ]) {
        expect(catalog.contacts(id), isEmpty);
        expect(catalog.find(SamahaEntryKind.person, companyId: id), isEmpty);
      }
    });
    test(
      'missing optional company fields do not inherit the parent website',
      () {
        final data = samahaFixture();
        final company = data['companies'][1] as Map<String, dynamic>;
        for (final key in [
          'summary',
          'description',
          'website_url',
          'website_unavailable_reason',
          'sort_order',
        ]) {
          company.remove(key);
        }
        final parsed = SamahaCatalog.fromJson(data).company('company_legal')!;
        expect(parsed.website, isNull);
        expect(parsed.summary.isEmpty, isTrue);
        expect(parsed.description.isEmpty, isTrue);
        expect(parsed.websiteUnavailableReason.isEmpty, isTrue);
      },
    );
    test(
      'missing person bio, role, office, specialties and image remain safe',
      () {
        final data = samahaFixture();
        final person =
            (data['entries'] as List).firstWhere(
                  (entry) => entry['kind'] == 'person',
                )
                as Map<String, dynamic>;
        for (final key in ['body', 'summary', 'details', 'sort_order']) {
          person.remove(key);
        }
        (data['media'] as List).removeWhere(
          (media) => media['entry_id'] == person['id'],
        );
        final catalog = SamahaCatalog.fromJson(data);
        final parsed = catalog.entry(person['id'])!;
        expect(parsed.role.isEmpty, isTrue);
        expect(parsed.body.isEmpty, isTrue);
        expect(parsed.office.isEmpty, isTrue);
        expect(parsed.specialties, isEmpty);
        expect(parsed.teamCategory, SamahaTeamCategory.other);
        expect(catalog.image(parsed.companyId, entryId: parsed.id), isNull);
      },
    );
    test('specialties preserve source language and cannot be mutated', () {
      final data = samahaFixture();
      final person = (data['entries'] as List).firstWhere(
        (entry) => entry['kind'] == 'person',
      );
      person['details']['specialties'] = [
        {'en': 'Synthetic test-only specialty'},
      ];
      final specialties =
          SamahaCatalog.fromJson(data).entry(person['id'])!.specialties;
      expect(specialties.single.isFallback('ar'), isTrue);
      expect(() => specialties.clear(), throwsUnsupportedError);
    });
    test('even permitted media must use a safe bundled path, never a URL', () {
      for (final path in [
        'https://example.test/x.png',
        'file:///x.png',
        '../x.png',
        'assets/images/samaha/../x.png',
        'assets/images/samaha/a.svg',
        'assets/images/samaha/a.png?token=x',
      ]) {
        final data = samahaFixture();
        final media = samahaMediaFixture(data)..['asset_path'] = path;
        data['media'] = [media];
        expect(SamahaCatalog.fromJson(data).media, isEmpty, reason: path);
      }
    });
  });

  group('Feature-scoped state', () {
    test(
      'loading, ready and language switching share one immutable snapshot',
      () async {
        final completion = Completer<SamahaCatalog>();
        final controller = SamahaController(loader: () => completion.future);
        addTearDown(controller.dispose);
        final loading = controller.load();
        expect(controller.state, SamahaLoadState.loading);
        controller.setLanguage('ar-EG');
        completion.complete(SamahaCatalog.fromJson(samahaFixture()));
        await loading;
        expect(controller.state, SamahaLoadState.ready);
        expect(controller.language, 'ar');
        expect(controller.catalog!.divisions.length, 5);
      },
    );
    test(
      'refresh failure removes stale published data and retry recovers',
      () async {
        var fail = false;
        final controller = SamahaController(
          loader: () async {
            if (fail) {
              throw StateError('offline');
            }
            return SamahaCatalog.fromJson(samahaFixture());
          },
        );
        addTearDown(controller.dispose);
        await controller.load();
        fail = true;
        await controller.load();
        expect(controller.state, SamahaLoadState.error);
        expect(controller.catalog, isNull);
        fail = false;
        await controller.load();
        expect(controller.state, SamahaLoadState.ready);
      },
    );
    test('a stale response cannot replace a newer load', () async {
      final old = Completer<SamahaCatalog>();
      var calls = 0;
      final empty = SamahaCatalog.fromJson({
        'companies': [],
        'entries': [],
        'links': [],
        'media': [],
      });
      final controller = SamahaController(
        loader: () => calls++ == 0 ? old.future : Future.value(empty),
      );
      addTearDown(controller.dispose);
      final first = controller.load();
      await controller.load();
      old.complete(SamahaCatalog.fromJson(samahaFixture()));
      await first;
      expect(controller.catalog!.companies, isEmpty);
    });
    test('completion after disposal does not notify or crash', () async {
      final pending = Completer<SamahaCatalog>();
      final controller = SamahaController(loader: () => pending.future);
      final load = controller.load();
      controller.dispose();
      pending.complete(SamahaCatalog.fromJson(samahaFixture()));
      await load;
    });
  });
}
