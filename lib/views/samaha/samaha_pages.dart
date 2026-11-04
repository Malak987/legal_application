import 'package:flutter/material.dart';
import '../../constants/colors.dart';
import '../../models/samaha_catalog.dart';
import '../../state/samaha_controller.dart';
import 'samaha_strings.dart';
import 'samaha_widgets.dart';

void openSamahaDirectory(
  BuildContext context,
  SamahaController controller, {
  SamahaEntryKind? kind,
  String? companyId,
  SamahaLinkOpener? opener,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: RouteSettings(name: '/samaha/${kind?.name ?? 'companies'}'),
      builder:
          (_) => SamahaDirectoryPage(
            controller: controller,
            kind: kind,
            companyId: companyId,
            opener: opener,
          ),
    ),
  );
}

void openSamahaCompany(
  BuildContext context,
  SamahaController controller,
  String id, {
  SamahaLinkOpener? opener,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: RouteSettings(name: '/samaha/companies/$id'),
      builder:
          (_) => SamahaDetailPage(
            controller: controller,
            companyId: id,
            opener: opener,
          ),
    ),
  );
}

void openSamahaEntry(
  BuildContext context,
  SamahaController controller,
  String id, {
  SamahaLinkOpener? opener,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: RouteSettings(name: '/samaha/entries/$id'),
      builder:
          (_) => SamahaDetailPage(
            controller: controller,
            entryId: id,
            opener: opener,
          ),
    ),
  );
}

class _DirectoryFrame extends StatelessWidget {
  const _DirectoryFrame({
    required this.controller,
    required this.title,
    required this.builder,
  });
  final SamahaController controller;
  final String Function(SamahaCatalog? catalog, SamahaStrings strings) title;
  final Widget Function(
    BuildContext context,
    SamahaCatalog catalog,
    SamahaStrings strings,
  )
  builder;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final s = SamahaStrings(controller.language);
      return SamahaLocale(
        language: controller.language,
        child: Builder(
          builder:
              (context) => Scaffold(
                backgroundColor: AppColors.corporatePaper,
                appBar: AppBar(
                  backgroundColor: AppColors.corporatePaper,
                  foregroundColor: AppColors.corporateNavy,
                  title: Text(
                    title(controller.catalog, s),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  actions: [
                    SamahaLanguageButton(controller: controller),
                    IconButton(
                      tooltip: s.refresh,
                      onPressed:
                          controller.state == SamahaLoadState.loading
                              ? null
                              : controller.load,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                body: SafeArea(
                  child: RefreshIndicator(
                    onRefresh: controller.load,
                    child: ListView(
                      key: const PageStorageKey('samaha-page-scroll'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                      children: [
                        Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1160),
                            child:
                                controller.state == SamahaLoadState.ready &&
                                        controller.catalog != null
                                    ? builder(context, controller.catalog!, s)
                                    : SamahaStatus(controller: controller),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        ),
      );
    },
  );
}

class SamahaDirectoryPage extends StatefulWidget {
  const SamahaDirectoryPage({
    super.key,
    required this.controller,
    this.kind,
    this.companyId,
    this.opener,
  });
  final SamahaController controller;
  final SamahaEntryKind? kind;
  final String? companyId;
  final SamahaLinkOpener? opener;
  @override
  State<SamahaDirectoryPage> createState() => _SamahaDirectoryPageState();
}

class _SamahaDirectoryPageState extends State<SamahaDirectoryPage> {
  final _search = TextEditingController();
  String _query = '';
  String? _company;
  SamahaTeamCategory? _role;
  @override
  void initState() {
    super.initState();
    _company = widget.companyId;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _DirectoryFrame(
    controller: widget.controller,
    title: (_, s) => widget.kind == null ? s.companies : s.kind(widget.kind!),
    builder: _content,
  );

  Widget _content(
    BuildContext context,
    SamahaCatalog catalog,
    SamahaStrings s,
  ) {
    final kind = widget.kind;
    if (kind == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.explore,
            style: const TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w700,
              color: AppColors.corporateNavy,
            ),
          ),
          const SizedBox(height: 12),
          SamahaNotice(s.sourceNotice),
          const SizedBox(height: 20),
          if (catalog.companies.isEmpty)
            SamahaEmptyState(message: s.empty)
          else
            SamahaResponsiveCards(
              children: [
                for (final company in catalog.companies)
                  SamahaCompanyCard(
                    key: ValueKey('samaha-company-${company.id}'),
                    company: company,
                    catalog: catalog,
                    language: s.language,
                    onTap:
                        () => openSamahaCompany(
                          context,
                          widget.controller,
                          company.id,
                          opener: widget.opener,
                        ),
                  ),
              ],
            ),
        ],
      );
    }
    final entries =
        catalog
            .find(kind, companyId: _company, query: _query)
            .where((entry) => _role == null || entry.teamCategory == _role)
            .toList();
    final missingSelection =
        _company != null &&
        !catalog.divisions.any((company) => company.id == _company);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          kind == SamahaEntryKind.person
              ? s.peopleHeadline
              : kind == SamahaEntryKind.service
              ? s.servicesHeadline
              : kind == SamahaEntryKind.branch
              ? s.locationHeadline
              : s.kind(kind),
          style: const TextStyle(
            fontSize: 27,
            fontWeight: FontWeight.w700,
            color: AppColors.corporateNavy,
          ),
        ),
        const SizedBox(height: 12),
        if (kind == SamahaEntryKind.branch)
          SamahaNotice(s.locationNotice)
        else if (kind == SamahaEntryKind.person)
          SamahaNotice(s.teamDirectoryNotice)
        else
          SamahaNotice(s.sourceNotice),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, constraints) {
            final search = TextField(
              key: const ValueKey('samaha-search'),
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                labelText: s.search,
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            );
            final filter = DropdownButtonFormField<String>(
              key: ValueKey('samaha-filter-${_company ?? 'all'}'),
              initialValue: _company ?? '',
              isExpanded: true,
              decoration: InputDecoration(
                labelText: s.filterCompany,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              items: [
                DropdownMenuItem(value: '', child: Text(s.allCompanies)),
                if (missingSelection)
                  DropdownMenuItem(
                    value: _company,
                    child: Text(
                      s.notFound,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                for (final company in catalog.divisions)
                  DropdownMenuItem(
                    value: company.id,
                    child: SamahaText(
                      company.name,
                      language: s.language,
                      maxLines: 1,
                    ),
                  ),
              ],
              onChanged:
                  (value) =>
                      setState(() => _company = value == '' ? null : value),
            );
            if (constraints.maxWidth >= 760 &&
                MediaQuery.textScalerOf(context).scale(1) < 1.4) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 2, child: search),
                  const SizedBox(width: 16),
                  Expanded(child: filter),
                ],
              );
            }
            return Column(
              children: [search, const SizedBox(height: 12), filter],
            );
          },
        ),
        if (kind == SamahaEntryKind.person) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: Text(s.allRoles),
                selected: _role == null,
                onSelected: (_) => setState(() => _role = null),
              ),
              for (final role in SamahaTeamCategory.values)
                if (catalog
                    .find(SamahaEntryKind.person)
                    .any((p) => p.teamCategory == role))
                  ChoiceChip(
                    key: ValueKey('samaha-role-${role.name}'),
                    label: Text(s.teamCategory(role)),
                    selected: _role == role,
                    onSelected:
                        (_) =>
                            setState(() => _role = _role == role ? null : role),
                  ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Text(
          '${entries.length} ${s.results}',
          style: const TextStyle(fontSize: 12, color: AppColors.corporateMuted),
        ),
        if (_query.isNotEmpty || _company != null || _role != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () {
                _search.clear();
                setState(() {
                  _query = '';
                  _company = null;
                  _role = null;
                });
              },
              child: Text(s.clearFilters),
            ),
          ),
        const SizedBox(height: 20),
        if (entries.isEmpty)
          SamahaEmptyState(
            message:
                _query.isNotEmpty || _company != null || _role != null
                    ? s.noResults
                    : s.empty,
          )
        else
          SamahaResponsiveCards(
            minimumWidth: kind == SamahaEntryKind.person ? 230 : 280,
            children: [
              for (final entry in entries)
                _EntryCard(
                  entry: entry,
                  compact:
                      kind == SamahaEntryKind.person &&
                      (MediaQuery.sizeOf(context).width < 600 ||
                          MediaQuery.textScalerOf(context).scale(1) >= 1.6),
                  catalog: catalog,
                  language: s.language,
                  onTap:
                      () => openSamahaEntry(
                        context,
                        widget.controller,
                        entry.id,
                        opener: widget.opener,
                      ),
                ),
            ],
          ),
      ],
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.entry,
    required this.catalog,
    required this.language,
    required this.onTap,
    this.compact = false,
  });
  final SamahaEntry entry;
  final SamahaCatalog catalog;
  final String language;
  final VoidCallback onTap;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final company = catalog.company(entry.companyId)!;
    final media = catalog.image(company.id, entryId: entry.id);
    final s = SamahaStrings(language);
    final person = entry.kind == SamahaEntryKind.person;
    final title = SamahaText(
      entry.title,
      language: language,
      style: const TextStyle(
        fontSize: 17,
        height: 1.5,
        fontWeight: FontWeight.w700,
        color: AppColors.corporateNavy,
      ),
    );
    final role =
        entry.role.isEmpty
            ? Text(
              s.roleUnderReview,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.corporateMuted,
              ),
            )
            : SamahaText(
              entry.role,
              language: language,
              style: const TextStyle(
                fontSize: 13,
                height: 1.6,
                color: AppColors.corporateMuted,
              ),
            );
    return Material(
      key: ValueKey('samaha-entry-${entry.id}'),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.corporateLine),
      ),
      child: InkWell(
        onTap: onTap,
        child:
            person && compact
                ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SamahaImage(
                        media: media,
                        language: language,
                        fallback: Icons.person_outline,
                        size: 80,
                        height: 104,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [title, const SizedBox(height: 6), role],
                        ),
                      ),
                    ],
                  ),
                )
                : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (person)
                      LayoutBuilder(
                        builder:
                            (context, constraints) => SamahaImage(
                              media: media,
                              language: language,
                              fallback: Icons.person_outline,
                              size: constraints.maxWidth,
                              height: constraints.maxWidth * 1.2,
                              radius: 0,
                            ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!person) ...[
                            Row(
                              children: [
                                SamahaImage(
                                  media: media,
                                  language: language,
                                  fallback: samahaEntryIcon(entry.kind),
                                  size: 44,
                                ),
                                const Spacer(),
                                const Icon(
                                  Icons.north_east,
                                  size: 18,
                                  color: AppColors.corporateGold,
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                          ],
                          title,
                          const SizedBox(height: 8),
                          if (person)
                            role
                          else if (!entry.summary.isEmpty)
                            SamahaText(
                              entry.summary,
                              language: language,
                              maxLines: 3,
                              style: const TextStyle(
                                fontSize: 13,
                                height: 1.7,
                                color: AppColors.corporateMuted,
                              ),
                            ),
                          const SizedBox(height: 18),
                          Row(
                            children: [
                              Expanded(
                                child:
                                    person
                                        ? Text(
                                          media == null
                                              ? s.portraitUnavailable
                                              : s.sourcePhoto,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: AppColors.corporateMuted,
                                          ),
                                        )
                                        : SamahaText(
                                          company.name,
                                          language: language,
                                          maxLines: 2,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: AppColors.corporateMuted,
                                          ),
                                        ),
                              ),
                              const Icon(
                                Icons.arrow_forward,
                                size: 16,
                                color: AppColors.corporateNavy,
                              ),
                            ],
                          ),
                          if (person && media?.isSourceReference == true)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                s.rightsUnknown,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: AppColors.corporateMuted,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
      ),
    );
  }
}

class SamahaDetailPage extends StatelessWidget {
  const SamahaDetailPage({
    super.key,
    required this.controller,
    this.companyId,
    this.entryId,
    this.opener,
  }) : assert((companyId == null) != (entryId == null));
  final SamahaController controller;
  final String? companyId;
  final String? entryId;
  final SamahaLinkOpener? opener;

  @override
  Widget build(BuildContext context) => _DirectoryFrame(
    controller: controller,
    title:
        (catalog, s) =>
            (companyId == null
                    ? catalog?.entry(entryId!)?.title
                    : catalog?.company(companyId!)?.name)
                ?.text(s.language) ??
            s.details,
    builder: (context, catalog, s) {
      if (companyId != null) {
        final company = catalog.company(companyId!);
        return company == null
            ? SamahaNotice(s.notFound)
            : _company(context, catalog, company, s);
      }
      final entry = catalog.entry(entryId!);
      return entry == null
          ? SamahaNotice(s.notFound)
          : _entry(context, catalog, entry, s);
    },
  );

  Widget _company(
    BuildContext context,
    SamahaCatalog catalog,
    SamahaCompany company,
    SamahaStrings s,
  ) {
    final services = catalog.find(
      SamahaEntryKind.service,
      companyId: company.id,
    );
    final people = catalog.find(SamahaEntryKind.person, companyId: company.id);
    final locations = catalog.find(
      SamahaEntryKind.branch,
      companyId: company.id,
    );
    final faqs = catalog.find(SamahaEntryKind.faq, companyId: company.id);
    Widget cards(List<SamahaEntry> entries) => SamahaResponsiveCards(
      children: [
        for (final entry in entries)
          _EntryCard(
            entry: entry,
            catalog: catalog,
            language: s.language,
            compact: true,
            onTap:
                () => openSamahaEntry(
                  context,
                  controller,
                  entry.id,
                  opener: opener,
                ),
          ),
      ],
    );
    return Column(
      key: ValueKey('samaha-company-profile-${company.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (company.parentId != null)
          TextButton.icon(
            onPressed:
                () => openSamahaCompany(
                  context,
                  controller,
                  company.parentId!,
                  opener: opener,
                ),
            icon: const Icon(Icons.hub_outlined, size: 18),
            label: Text(s.aboutGroup),
          ),
        _hero(
          company.name,
          company.summary,
          catalog.image(company.id),
          samahaCompanyIcon(company),
          s,
        ),
        SamahaHeading(s.overview),
        if (company.description.isEmpty)
          Text(s.empty)
        else
          SamahaText(
            company.description,
            language: s.language,
            selectable: true,
            style: const TextStyle(fontSize: 16, height: 1.8),
          ),
        if (company.name.isFallback(s.language) ||
            company.summary.isFallback(s.language) ||
            company.description.isFallback(s.language))
          Text(s.originalLanguage),
        const SizedBox(height: 16),
        SamahaNotice(s.sourceNotice),
        if (company.isGroup) ...[
          SamahaHeading(s.companies),
          SamahaResponsiveCards(
            children: [
              for (final child in catalog.divisions.where(
                (child) => child.parentId == company.id,
              ))
                SamahaCompanyCard(
                  company: child,
                  catalog: catalog,
                  language: s.language,
                  onTap:
                      () => openSamahaCompany(
                        context,
                        controller,
                        child.id,
                        opener: opener,
                      ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          // Explicit browse-all navigation, not inherited group memberships.
          _browse(context, s),
        ] else ...[
          const SizedBox(height: 16),
          _browse(context, s, companyId: company.id),
        ],
        SamahaHeading(s.servicesAndSpecializations),
        if (services.isEmpty) Text(s.empty) else cards(services),
        SamahaHeading(s.foundersAndTeam),
        SamahaNotice(s.teamNotice),
        // A section is always shown for founders; an absent profile is not
        // synthesized from a chairman title, surname, portrait or parent group.
        for (final category in SamahaTeamCategory.values)
          if (category == SamahaTeamCategory.founder ||
              people.any((person) => person.teamCategory == category)) ...[
            SamahaHeading(s.teamCategory(category)),
            if (category == SamahaTeamCategory.founder &&
                !people.any((person) => person.teamCategory == category))
              Text(s.noFounders)
            else
              cards(
                people
                    .where((person) => person.teamCategory == category)
                    .toList(),
              ),
          ],
        if (people.isEmpty) ...[const SizedBox(height: 12), Text(s.noTeam)],
        SamahaHeading(s.faqs),
        if (faqs.isEmpty) Text(s.empty),
        for (final faq in faqs)
          Card(
            color: Colors.white,
            child: ExpansionTile(
              key: PageStorageKey('samaha-faq-${faq.id}'),
              title: SamahaText(faq.title, language: s.language),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              children: [
                SamahaText(faq.body, language: s.language, selectable: true),
              ],
            ),
          ),
        SamahaHeading(s.branches),
        if (locations.isEmpty) Text(s.empty),
        for (final location in locations)
          Card(
            key: ValueKey('samaha-location-${location.id}'),
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SamahaText(
                    location.title,
                    language: s.language,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SamahaText(
                    location.address.isEmpty ? location.city : location.address,
                    language: s.language,
                    selectable: true,
                  ),
                  const SizedBox(height: 12),
                  SamahaNotice(s.locationNotice),
                  SamahaHeading(s.branchContacts),
                  SamahaContacts(
                    entries: catalog.contacts(
                      company.id,
                      branchId: location.id,
                    ),
                    language: s.language,
                    opener: opener,
                  ),
                  TextButton(
                    onPressed:
                        () => openSamahaEntry(
                          context,
                          controller,
                          location.id,
                          opener: opener,
                        ),
                    child: Text(s.details),
                  ),
                ],
              ),
            ),
          ),
        SamahaHeading(s.contacts),
        SamahaContacts(
          entries: catalog.contacts(company.id),
          language: s.language,
          opener: opener,
        ),
        const SizedBox(height: 24),
        SamahaSources(sources: company.sources, language: s.language),
        // Last profile child by contract. Never move above the directory content
        // or substitute the parent website for an unverified division URL.
        SamahaWebsiteFooter(
          company: company,
          language: s.language,
          opener: opener,
        ),
      ],
    );
  }

  Widget _entry(
    BuildContext context,
    SamahaCatalog catalog,
    SamahaEntry entry,
    SamahaStrings s,
  ) {
    final company = catalog.company(entry.companyId)!;
    final related = catalog.related(entry.id);
    final enquiries =
        catalog
            .contacts(company.id)
            .where(
              (e) => ['phone', 'email', 'whatsapp'].contains(e.contact?.kind),
            )
            .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed:
              () => openSamahaCompany(
                context,
                controller,
                company.id,
                opener: opener,
              ),
          icon: const Icon(Icons.business_outlined, size: 18),
          label: SamahaText(company.name, language: s.language),
        ),
        const SizedBox(height: 10),
        _hero(
          entry.title,
          entry.summary,
          catalog.image(company.id, entryId: entry.id),
          samahaEntryIcon(entry.kind),
          s,
        ),
        if (!entry.sourceNote.isEmpty) ...[
          const SizedBox(height: 16),
          SamahaNotice(entry.sourceNote.text(s.language)),
        ],
        if (entry.roleVariants.isNotEmpty) ...[
          SamahaHeading(s.sourceVariants),
          for (final variant in entry.roleVariants)
            SamahaText(variant, language: s.language, selectable: true),
        ],
        if (entry.title.isFallback(s.language) ||
            entry.summary.isFallback(s.language) ||
            entry.body.isFallback(s.language) ||
            entry.role.isFallback(s.language)) ...[
          const SizedBox(height: 12),
          Text(
            s.originalLanguage,
            style: const TextStyle(
              fontStyle: FontStyle.italic,
              color: Color(0xFF596478),
            ),
          ),
        ],
        if (!entry.role.isEmpty) ...[
          SamahaHeading(s.publishedRole),
          SamahaText(
            entry.role,
            language: s.language,
            selectable: true,
            style: const TextStyle(fontSize: 18, height: 1.6),
          ),
        ],
        if (!entry.office.isEmpty) ...[
          SamahaHeading(s.publishedOffice),
          SamahaText(entry.office, language: s.language, selectable: true),
        ],
        if (!entry.body.isEmpty) ...[
          SamahaHeading(
            entry.kind == SamahaEntryKind.faq
                ? s.faqs
                : entry.kind == SamahaEntryKind.person
                ? s.biography
                : s.overview,
          ),
          SamahaText(
            entry.body,
            language: s.language,
            selectable: true,
            style: const TextStyle(fontSize: 16, height: 1.8),
          ),
        ],
        if (entry.publishedDate != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              MaterialLocalizations.of(
                context,
              ).formatMediumDate(entry.publishedDate!),
            ),
          ),
        if (entry.kind == SamahaEntryKind.person) ...[
          if (entry.role.isEmpty) ...[
            SamahaHeading(s.publishedRole),
            Text(s.noRole),
          ],
          if (entry.body.isEmpty) ...[
            SamahaHeading(s.biography),
            Text(s.noBiography),
          ],
          SamahaHeading(s.specialties),
          if (entry.specialties.isEmpty)
            Text(s.noSpecialties)
          else
            for (final specialty in entry.specialties)
              SamahaText(specialty, language: s.language, selectable: true),
          const SizedBox(height: 24),
          SamahaNotice(s.teamNotice),
        ],
        if (entry.kind == SamahaEntryKind.branch) ...[
          SamahaHeading(s.publishedAddress),
          if (!entry.address.isEmpty)
            SamahaText(
              entry.address,
              language: s.language,
              selectable: true,
              style: const TextStyle(fontSize: 17, height: 1.8),
            )
          else
            SamahaText(entry.city, language: s.language, selectable: true),
          const SizedBox(height: 20),
          SamahaNotice(s.locationNotice),
          SamahaHeading(s.branchContacts),
          SamahaContacts(
            entries: catalog.contacts(company.id, branchId: entry.id),
            language: s.language,
            opener: opener,
          ),
        ],
        if (related.isNotEmpty) ...[
          SamahaHeading(s.related),
          SamahaResponsiveCards(
            children: [
              for (final item in related)
                _EntryCard(
                  entry: item,
                  catalog: catalog,
                  language: s.language,
                  onTap:
                      () => openSamahaEntry(
                        context,
                        controller,
                        item.id,
                        opener: opener,
                      ),
                ),
            ],
          ),
        ],
        if (entry.kind == SamahaEntryKind.service) ...[
          const SizedBox(height: 20),
          SamahaNotice(s.sourceNotice),
          SamahaHeading(s.contacts),
          SamahaContacts(
            entries: enquiries,
            language: s.language,
            opener: opener,
          ),
        ],
        const SizedBox(height: 24),
        if (catalog.image(company.id, entryId: entry.id) case final image?) ...[
          if (image.isSourceReference) ...[
            SamahaHeading(s.sourcePhoto),
            SamahaNotice(s.rightsUnknown),
            const SizedBox(height: 12),
            SelectableText(
              image.originalImageUrl,
              key: PageStorageKey('samaha-original-image:${image.id}'),
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 11),
            ),
            const SizedBox(height: 20),
          ],
        ],
        SamahaSources(sources: entry.sources, language: s.language),
      ],
    );
  }

  Widget _browse(BuildContext context, SamahaStrings s, {String? companyId}) =>
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final kind in [
            SamahaEntryKind.service,
            SamahaEntryKind.person,
            SamahaEntryKind.branch,
          ])
            OutlinedButton.icon(
              onPressed:
                  () => openSamahaDirectory(
                    context,
                    controller,
                    kind: kind,
                    companyId: companyId,
                    opener: opener,
                  ),
              icon: Icon(samahaEntryIcon(kind), size: 18),
              label: Text(s.kind(kind)),
            ),
        ],
      );

  Widget _hero(
    LocalizedContent title,
    LocalizedContent summary,
    SamahaMedia? media,
    IconData icon,
    SamahaStrings s,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final portrait = icon == Icons.person_outline;
      final wide =
          constraints.maxWidth >= 650 &&
          MediaQuery.textScalerOf(context).scale(1) < 1.5;
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SamahaEyebrow(
            portrait ? s.publishedProfiles : s.directoryLabel,
            light: true,
          ),
          const SizedBox(height: 14),
          Semantics(
            header: true,
            child: SamahaText(
              title,
              language: s.language,
              style: TextStyle(
                fontSize: wide ? 34 : 26,
                height: 1.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
          if (!summary.isEmpty) ...[
            const SizedBox(height: 14),
            SamahaText(
              summary,
              language: s.language,
              style: const TextStyle(
                fontSize: 15,
                height: 1.8,
                color: Color(0xFFD9E2EB),
              ),
            ),
          ],
          if (media?.isSourceReference == true) ...[
            const SizedBox(height: 16),
            Text(
              s.rightsUnknown,
              style: const TextStyle(fontSize: 11, color: Color(0xFFD9E2EB)),
            ),
          ],
        ],
      );
      final image = SamahaImage(
        media: media,
        language: s.language,
        fallback: icon,
        size: portrait ? 156 : 60,
        height: portrait ? 190 : 60,
        radius: 14,
      );
      return Container(
        width: double.infinity,
        padding: EdgeInsets.all(wide ? 32 : 24),
        decoration: BoxDecoration(
          color: AppColors.corporateNavy,
          borderRadius: BorderRadius.circular(22),
        ),
        child:
            wide
                ? Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    image,
                    const SizedBox(width: 28),
                    Expanded(child: content),
                  ],
                )
                : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [image, const SizedBox(height: 22), content],
                ),
      );
    },
  );
}
