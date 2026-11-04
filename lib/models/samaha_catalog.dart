/// Source-reviewed editorial content, deliberately separate from AppProfile,
/// Product/lawyer accounts, availability, bookings and authorization roles.
library;

enum SamahaEntryKind {
  service,
  person,
  branch,
  faq,
  article,
  contact,
  testimonial,
  partner,
}

/// Editorial grouping from an explicitly reviewed published role, not an
/// authorization role, credential check or registered-platform lawyer type.
enum SamahaTeamCategory {
  founder,
  partner,
  lawyer,
  legalProfessional,
  other;

  static SamahaTeamCategory parse(Object? value) => switch (value) {
    'founder' => founder,
    'partner' => partner,
    'lawyer' => lawyer,
    'legal_professional' => legalProfessional,
    null || 'other' => other,
    _ => throw const FormatException('Unknown published team category'),
  };
}

enum PublicationStatus {
  approved,
  needsReview,
  excluded;

  static PublicationStatus parse(Object? value) => switch (value) {
    'approved' => approved,
    'excluded' => excluded,
    _ => needsReview, // Unknown/future states fail closed.
  };
}

class LocalizedContent {
  const LocalizedContent({this.en = '', this.ar = ''});
  final String en;
  final String ar;

  factory LocalizedContent.fromJson(Object? value, {bool required = false}) {
    if (value == null && !required) return const LocalizedContent();
    final map = _object(value);
    if (map.keys.any((key) => key != 'en' && key != 'ar')) {
      throw const FormatException('Unsupported content language');
    }
    final result = LocalizedContent(
      en: _string(map['en'], optional: true),
      ar: _string(map['ar'], optional: true),
    );
    if (required && result.isEmpty) {
      throw const FormatException('Missing localized text');
    }
    return result;
  }

  bool get isEmpty => en.trim().isEmpty && ar.trim().isEmpty;
  String languageFor(String language) {
    if (language == 'ar' && ar.trim().isNotEmpty) return 'ar';
    if (language != 'ar' && en.trim().isNotEmpty) return 'en';
    return en.trim().isNotEmpty ? 'en' : 'ar';
  }

  String text(String language) => languageFor(language) == 'ar' ? ar : en;
  bool isFallback(String language) =>
      !isEmpty && languageFor(language) != language;
}

class SamahaSource {
  const SamahaSource({
    required this.recordId,
    required this.archiveMember,
    required this.url,
    required this.language,
  });
  final String recordId;
  final String archiveMember;
  final String url;
  final String language;

  factory SamahaSource.fromJson(Object? value) {
    final row = _object(value);
    final url = _string(row['url']);
    if (samahaWebUri(url, allowHttp: true) == null) {
      throw const FormatException('Invalid provenance URL');
    }
    return SamahaSource(
      recordId: _id(row['record_id']),
      archiveMember: _string(row['archive_member']),
      url: url,
      language: _string(row['language'], optional: true),
    );
  }
}

class SamahaCompany {
  SamahaCompany._(Map<String, dynamic> row)
    : id = _id(row['id']),
      parentId = _optionalId(row['parent_id']),
      kind = _string(row['kind']),
      name = LocalizedContent.fromJson(row['name'], required: true),
      summary = LocalizedContent.fromJson(row['summary']),
      description = LocalizedContent.fromJson(row['description']),
      website = samahaWebUri(_string(row['website_url'], optional: true)),
      websiteUnavailableReason = LocalizedContent.fromJson(
        row['website_unavailable_reason'],
      ),
      sources = _sources(row),
      sortOrder = _order(row['sort_order']);

  factory SamahaCompany.fromJson(Map<String, dynamic> row) {
    _requireReview(row);
    final company = SamahaCompany._(row);
    if (!['group', 'division'].contains(company.kind) ||
        company.isGroup != (company.parentId == null) ||
        company.parentId == company.id) {
      throw const FormatException('Invalid company hierarchy');
    }
    return company;
  }
  final String id;
  final String? parentId;
  final String kind;
  final LocalizedContent name;
  final LocalizedContent summary;
  final LocalizedContent description;
  final Uri? website;
  final LocalizedContent websiteUnavailableReason;
  final List<SamahaSource> sources;
  final int sortOrder;
  bool get isGroup => kind == 'group';
}

class SamahaContact {
  const SamahaContact._(this.kind, this.displayValue, this.uri);
  final String kind;
  final String displayValue;
  final Uri uri;

  factory SamahaContact.fromJson(Map<String, dynamic> details) {
    final kind = _string(details['contact_kind']);
    final display = _string(details['display_value']);
    final value = _string(details['action_uri']);
    final uri = Uri.tryParse(value);
    bool valid = uri != null;
    switch (kind) {
      case 'phone':
        final digits = display.replaceAll(RegExp(r'[\s()-]'), '');
        valid =
            valid &&
            RegExp(r'^tel:\+?[0-9]{7,15}$').hasMatch(value) &&
            uri.path == digits;
      case 'email':
        valid =
            valid &&
            uri.scheme == 'mailto' &&
            uri.hasQuery == false &&
            uri.hasFragment == false &&
            uri.path == display &&
            RegExp(r'^[^@\s?,]+@[^@\s?,]+\.[^@\s?,]+$').hasMatch(display);
      case 'whatsapp':
        final digits = display.replaceAll(RegExp(r'[+\s()-]'), '');
        valid =
            samahaWebUri(value) != null &&
            ['api.whatsapp.com', 'wa.me'].contains(uri?.host) &&
            ((uri?.host == 'wa.me'
                    ? uri?.path.replaceFirst('/', '')
                    : uri?.queryParameters['phone']) ==
                digits) &&
            (uri?.queryParameters['text'] ?? '').isEmpty;
      case 'map':
        valid =
            samahaWebUri(value) != null &&
            const {
              'maps.google.com',
              'www.google.com',
              'google.com',
              'maps.app.goo.gl',
              'maps.apple.com',
            }.contains(uri?.host);
      case 'website':
      case 'social':
        valid = samahaWebUri(value) != null;
      default:
        valid = false;
    }
    if (!valid || uri == null) {
      throw const FormatException('Unsafe or mismatched contact action');
    }
    return SamahaContact._(kind, display, uri);
  }
}

class SamahaEntry {
  SamahaEntry._(Map<String, dynamic> row, Map<String, dynamic> details)
    : id = _id(row['id']),
      companyId = _id(row['company_id']),
      kind = SamahaEntryKind.values.byName(_string(row['kind'])),
      title = LocalizedContent.fromJson(row['title'], required: true),
      summary = LocalizedContent.fromJson(row['summary']),
      body = LocalizedContent.fromJson(row['body']),
      role = LocalizedContent.fromJson(details['role']),
      office = LocalizedContent.fromJson(details['office']),
      sourceNote = LocalizedContent.fromJson(details['source_note']),
      roleVariants = _localizedList(details['published_role_variants']),
      teamCategory =
          row['kind'] == 'person'
              ? SamahaTeamCategory.parse(details['team_category'])
              : null,
      specialties = _localizedList(details['specialties']),
      address = LocalizedContent.fromJson(details['address']),
      city = LocalizedContent.fromJson(details['city']),
      country = LocalizedContent.fromJson(details['country']),
      parentId = _optionalId(row['parent_entry_id']),
      operationalStatus = _string(
        details['operational_status'],
        optional: true,
      ),
      verificationEvidence = _string(
        details['verification_evidence'],
        optional: true,
      ),
      locationType = _string(details['location_type'], optional: true),
      publishedDate = DateTime.tryParse(
        _string(details['published_date'], optional: true),
      ),
      contact =
          row['kind'] == 'contact' ? SamahaContact.fromJson(details) : null,
      sources = _sources(row),
      sortOrder = _order(row['sort_order']);

  factory SamahaEntry.fromJson(Map<String, dynamic> row) {
    _requireReview(row);
    if (!SamahaEntryKind.values.any((value) => value.name == row['kind'])) {
      throw const FormatException('Unknown directory entry kind');
    }
    final entry = SamahaEntry._(
      row,
      _object(row['details'] ?? <String, dynamic>{}),
    );
    if (entry.parentId != null &&
        (entry.kind != SamahaEntryKind.contact || entry.parentId == entry.id)) {
      throw const FormatException('Invalid contact parent');
    }
    if (entry.kind == SamahaEntryKind.branch &&
        (![
              'published_address',
              'published_city',
            ].contains(entry.locationType) ||
            !['unverified', 'verified'].contains(entry.operationalStatus) ||
            (entry.operationalStatus == 'verified' &&
                entry.verificationEvidence.isEmpty))) {
      throw const FormatException('Unsupported location/operational claim');
    }
    return entry;
  }

  final String id;
  final String companyId;
  final SamahaEntryKind kind;
  final SamahaTeamCategory? teamCategory;
  final List<LocalizedContent> specialties;
  final LocalizedContent sourceNote;
  final List<LocalizedContent> roleVariants;
  final LocalizedContent title,
      summary,
      body,
      role,
      office,
      address,
      city,
      country;
  final String? parentId;
  final String operationalStatus, verificationEvidence, locationType;
  final DateTime? publishedDate;
  final SamahaContact? contact;
  final List<SamahaSource> sources;
  final int sortOrder;
}

class SamahaLink {
  SamahaLink._(Map<String, dynamic> row)
    : id = _id(row['id']),
      companyId = _id(row['company_id']),
      fromId = _id(row['from_id']),
      toId = _id(row['to_id']),
      fromKind = _string(row['from_kind']),
      toKind = _string(row['to_kind']),
      relationKind = _string(row['relation_kind']);
  factory SamahaLink.fromJson(Map<String, dynamic> row) {
    _requireReview(row);
    _sources(row);
    return SamahaLink._(row);
  }
  final String id, companyId, fromId, toId, fromKind, toKind, relationKind;

  bool connects(SamahaEntry? from, SamahaEntry? to) =>
      from != null &&
      to != null &&
      fromId != toId &&
      from.companyId == companyId &&
      to.companyId == companyId &&
      from.kind.name == fromKind &&
      to.kind.name == toKind &&
      const {
            'person_branch': 'person:branch',
            'person_service': 'person:service',
            'service_branch': 'service:branch',
            'service_faq': 'service:faq',
          }[relationKind] ==
          '$fromKind:$toKind';
}

class SamahaMedia {
  SamahaMedia._(Map<String, dynamic> row)
    : id = _id(row['id']),
      companyId = _id(row['company_id']),
      entryId = _optionalId(row['entry_id']),
      assetPath = _string(row['asset_path'], optional: true),
      altText = LocalizedContent.fromJson(row['alt_text'], required: true),
      role = _string(row['media_role']),
      rights = _string(row['rights_status']),
      displayPolicy = _string(row['display_policy'], optional: true),
      associationStatus = _string(row['association_status'], optional: true),
      sourcePageUrl = _string(row['source_page_url'], optional: true),
      originalImageUrl = _string(row['original_image_url'], optional: true),
      sourceCardSha256 = _string(row['source_card_sha256'], optional: true),
      sources = _sources(row),
      permissionEvidence = _string(row['permission_evidence'], optional: true),
      associationEvidence = _string(
        row['association_evidence'],
        optional: true,
      ),
      originalSha256 = _string(row['original_sha256'], optional: true);
  factory SamahaMedia.fromJson(Map<String, dynamic> row) {
    _requireReview(row);
    _sources(row);
    return SamahaMedia._(row);
  }
  final String id,
      companyId,
      role,
      rights,
      permissionEvidence,
      associationEvidence,
      originalSha256;
  final String? entryId;
  final String displayPolicy,
      associationStatus,
      sourcePageUrl,
      originalImageUrl,
      sourceCardSha256;
  final List<SamahaSource> sources;
  final String assetPath;
  final LocalizedContent altText;
  bool get isPermitted =>
      rights == 'permitted' &&
      RegExp(
        r'^assets/images/samaha/[A-Za-z0-9_-]+\.(png|jpg|jpeg|webp)$',
      ).hasMatch(assetPath) &&
      permissionEvidence.trim().isNotEmpty &&
      associationEvidence.trim().isNotEmpty &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(originalSha256) &&
      ['logo', 'portrait', 'illustration', 'photo'].contains(role);

  /// Source association is NOT a copyright licence. The requester expressly
  /// declared permission for these portraits. That per-record declaration must
  /// be recorded before a reference image may display; it does not change the
  /// independently unverified rights status or imply an open licence.
  bool get isSourceReference {
    final page = samahaWebUri(sourcePageUrl);
    final image = samahaWebUri(originalImageUrl);
    return rights == 'unverified' &&
        displayPolicy == 'user_declared_permission' &&
        permissionEvidence.trim().isNotEmpty &&
        associationStatus == 'verified_source_card' &&
        role == 'portrait' &&
        entryId != null &&
        page?.host == 'samaha-group.com' &&
        image?.host == 'samaha-group.com' &&
        image!.path.startsWith('/wp-content/uploads/') &&
        sources.any((source) => source.url == sourcePageUrl) &&
        RegExp(
          r'^assets/images/samaha/[A-Za-z0-9_-]+\.(png|jpg|jpeg|webp)$',
        ).hasMatch(assetPath) &&
        associationEvidence.trim().isNotEmpty &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(originalSha256) &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(sourceCardSha256);
  }

  bool get isDisplayable => isPermitted || isSourceReference;
}

/// Only a complete, validated, approved graph is exposed to any public screen.
/// Missing/unpublished parents and relation endpoints are removed defensively,
/// and the asset repository additionally rejects an incomplete bundled graph.
class SamahaCatalog {
  SamahaCatalog._(this.companies, this.entries, this.links, this.media)
    : _companies = Map.unmodifiable({
        for (final company in companies) company.id: company,
      }),
      _entries = Map.unmodifiable({
        for (final entry in entries) entry.id: entry,
      });

  factory SamahaCatalog.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> approved(String key) =>
        _rows(json[key])
            .where(
              (row) =>
                  PublicationStatus.parse(row['publication_status']) ==
                  PublicationStatus.approved,
            )
            .toList();
    final allCompanies =
        approved('companies').map(SamahaCompany.fromJson).toList();
    _uniqueIds(allCompanies.map((c) => c.id));
    final groups = {for (final c in allCompanies.where((c) => c.isGroup)) c.id};
    final companies =
        allCompanies
            .where((c) => c.isGroup || groups.contains(c.parentId))
            .toList()
          ..sort((a, b) => _sort(a.sortOrder, a.id, b.sortOrder, b.id));
    final companyIds = companies.map((c) => c.id).toSet();
    final allEntries =
        approved('entries')
            .map(SamahaEntry.fromJson)
            .where((e) => companyIds.contains(e.companyId))
            .toList();
    _uniqueIds(allEntries.map((e) => e.id));
    final parents = {
      for (final e in allEntries.where((e) => e.kind == SamahaEntryKind.branch))
        e.id: e,
    };
    final entries =
        allEntries
            .where(
              (e) =>
                  e.parentId == null ||
                  parents[e.parentId]?.companyId == e.companyId,
            )
            .toList()
          ..sort((a, b) => _sort(a.sortOrder, a.id, b.sortOrder, b.id));
    final byId = {for (final e in entries) e.id: e};
    final links =
        approved('links')
            .map(SamahaLink.fromJson)
            .where((r) => r.connects(byId[r.fromId], byId[r.toId]))
            .toList();
    _uniqueIds(links.map((r) => r.id));
    final media =
        approved('media')
            .map(SamahaMedia.fromJson)
            .where(
              (m) =>
                  m.isDisplayable &&
                  companyIds.contains(m.companyId) &&
                  (m.entryId == null ||
                      byId[m.entryId]?.companyId == m.companyId) &&
                  (m.role != 'portrait' ||
                      (byId[m.entryId]?.kind == SamahaEntryKind.person &&
                          (!m.isSourceReference ||
                              m.altText.en == byId[m.entryId]?.title.en))),
            )
            .toList();
    _uniqueIds(media.map((m) => m.id));
    return SamahaCatalog._(
      List.unmodifiable(companies),
      List.unmodifiable(entries),
      List.unmodifiable(links),
      List.unmodifiable(media),
    );
  }
  final List<SamahaCompany> companies;
  final List<SamahaEntry> entries;
  final List<SamahaLink> links;
  final List<SamahaMedia> media;
  final Map<String, SamahaCompany> _companies;
  final Map<String, SamahaEntry> _entries;
  List<SamahaCompany> get divisions =>
      companies.where((c) => !c.isGroup).toList(growable: false);
  SamahaCompany? company(String id) => _companies[id];
  SamahaEntry? entry(String id) => _entries[id];

  List<SamahaEntry> find(
    SamahaEntryKind kind, {
    String? companyId,
    String query = '',
  }) {
    final term = _searchText(query);
    return entries
        .where(
          (e) =>
              e.kind == kind &&
              (companyId == null || e.companyId == companyId) &&
              (term.isEmpty ||
                  _searchText(
                    '${e.title.en} ${e.title.ar} ${e.summary.en} ${e.summary.ar} ${e.role.en} ${e.role.ar}',
                  ).contains(term)),
        )
        .toList(growable: false);
  }

  List<SamahaEntry> contacts(String companyId, {String? branchId}) => entries
      .where(
        (e) =>
            e.companyId == companyId &&
            e.kind == SamahaEntryKind.contact &&
            e.parentId == branchId,
      )
      .toList(growable: false);
  List<SamahaEntry> related(String id) {
    final ids = <String>{};
    for (final link in links) {
      if (link.fromId == id) ids.add(link.toId);
      if (link.toId == id) ids.add(link.fromId);
    }
    return ids.map((id) => _entries[id]!).toList(growable: false);
  }

  SamahaMedia? image(String companyId, {String? entryId}) {
    for (final item in media) {
      if (item.companyId == companyId && item.entryId == entryId) return item;
    }
    return null;
  }
}

Uri? samahaWebUri(String value, {bool allowHttp = false}) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'https' && !(allowHttp && uri.scheme == 'http')) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      RegExp(r'\s').hasMatch(value)) {
    return null;
  }
  return uri;
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('Expected an object');
  }
  return Map<String, dynamic>.from(value);
}

List<LocalizedContent> _localizedList(Object? value) {
  if (value == null) return const [];
  if (value is! List) throw const FormatException('Expected localized list');
  return List.unmodifiable(
    value.map((item) => LocalizedContent.fromJson(item, required: true)),
  );
}

List<Map<String, dynamic>> _rows(Object? value) {
  if (value is! List) throw const FormatException('Expected catalogue rows');
  return value.map(_object).toList(growable: false);
}

String _string(Object? value, {bool optional = false}) {
  if (value == null && optional) return '';
  if (value is! String || (!optional && value.trim().isEmpty)) {
    throw const FormatException('Expected text');
  }
  return value;
}

String _id(Object? value) {
  final id = _string(value);
  if (!RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(id)) {
    throw const FormatException('Invalid directory ID');
  }
  return id;
}

String? _optionalId(Object? value) => value == null ? null : _id(value);
int _order(Object? value) =>
    value == null
        ? 0
        : value is int
        ? value
        : throw const FormatException('Invalid sort order');
List<SamahaSource> _sources(Map<String, dynamic> row) {
  final list = row['source_refs'];
  if (list is! List || list.isEmpty) {
    throw const FormatException('Missing provenance');
  }
  return List.unmodifiable(list.map(SamahaSource.fromJson));
}

void _requireReview(Map<String, dynamic> row) {
  if (PublicationStatus.parse(row['publication_status']) !=
          PublicationStatus.approved ||
      DateTime.tryParse(_string(row['reviewed_at'], optional: true)) == null ||
      _string(row['review_basis'], optional: true).trim().isEmpty) {
    throw const FormatException('Record is not reviewed for publication');
  }
}

void _uniqueIds(Iterable<String> ids) {
  final seen = <String>{};
  if (ids.any((id) => !seen.add(id))) {
    throw const FormatException('Duplicate directory ID');
  }
}

int _sort(int a, String aid, int b, String bid) =>
    a == b ? aid.compareTo(bid) : a.compareTo(b);
String _searchText(String value) =>
    value
        .toLowerCase()
        .replaceAll(RegExp(r'[\u064b-\u065f\u0670\u0640]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
