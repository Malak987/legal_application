import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../constants/colors.dart';
import '../../models/samaha_catalog.dart';
import '../../state/samaha_controller.dart';
import 'samaha_pages.dart';
import 'samaha_strings.dart';
import 'samaha_widgets.dart';

/// The directory remains part of the real Home, independent of account data.
class SamahaHomeSection extends StatefulWidget {
  const SamahaHomeSection({
    super.key,
    required this.controller,
    this.showLanguageControl = true,
  });
  final SamahaController controller;
  // Home exposes the same control beside its catalogue heading, so it remains
  // reachable before scrolling through lawyers. Standalone sections retain it.
  final bool showLanguageControl;
  @override
  State<SamahaHomeSection> createState() => _SamahaHomeSectionState();
}

class _SamahaHomeSectionState extends State<SamahaHomeSection> {
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final s = SamahaStrings(c.language);
      final catalog = c.catalog;
      return SamahaLocale(
        language: s.language,
        child: Builder(
          builder:
              (context) => Padding(
                key: const ValueKey('samaha-home-section'),
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final wide =
                            constraints.maxWidth >= 820 &&
                            MediaQuery.textScalerOf(context).scale(1) < 1.3;
                        final intro = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SamahaEyebrow(s.directoryLabel, light: true),
                            const SizedBox(height: 16),
                            Semantics(
                              header: true,
                              child: Text(
                                s.homeHeadline,
                                style: TextStyle(
                                  fontSize: wide ? 34 : 24,
                                  fontWeight: FontWeight.w700,
                                  height: 1.4,
                                  color: Colors.white,
                                  letterSpacing: -.5,
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              s.homeIntro,
                              style: const TextStyle(
                                color: Color(0xFFD9E2EB),
                                fontSize: 14,
                                height: 1.7,
                              ),
                            ),
                            if (catalog != null &&
                                catalog.companies.any(
                                  (company) => company.isGroup,
                                )) ...[
                              const SizedBox(height: 20),
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFFE7CB93),
                                  foregroundColor: AppColors.corporateNavy,
                                ),
                                onPressed:
                                    () => openSamahaCompany(
                                      context,
                                      c,
                                      catalog.companies
                                          .firstWhere((x) => x.isGroup)
                                          .id,
                                    ),
                                icon: const Icon(Icons.arrow_forward, size: 18),
                                label: Text(s.aboutGroup),
                              ),
                            ],
                          ],
                        );
                        Widget metric(String value, String label) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 62,
                                child: Text(
                                  value,
                                  style: const TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFFE7CB93),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  label,
                                  style: const TextStyle(
                                    color: Color(0xFFD9E2EB),
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                        return Container(
                          width: double.infinity,
                          padding: EdgeInsets.all(wide ? 28 : 20),
                          decoration: BoxDecoration(
                            color: AppColors.corporateNavy,
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child:
                              wide && catalog != null
                                  ? Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      Expanded(flex: 3, child: intro),
                                      const SizedBox(width: 56),
                                      Expanded(
                                        child: Column(
                                          children: [
                                            metric(
                                              catalog.divisions.length
                                                  .toString()
                                                  .padLeft(2, '0'),
                                              s.companies,
                                            ),
                                            const Divider(
                                              color: Color(0xFF365068),
                                            ),
                                            metric(
                                              catalog
                                                  .find(SamahaEntryKind.service)
                                                  .length
                                                  .toString(),
                                              s.services,
                                            ),
                                            const Divider(
                                              color: Color(0xFF365068),
                                            ),
                                            metric(
                                              catalog
                                                  .find(SamahaEntryKind.person)
                                                  .length
                                                  .toString(),
                                              s.publishedProfiles,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  )
                                  : intro,
                        );
                      },
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            s.offlineDirectory,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.corporateMuted,
                            ),
                          ),
                        ),
                        if (widget.showLanguageControl)
                          SamahaLanguageButton(controller: c),
                      ],
                    ),
                    if (c.state != SamahaLoadState.ready || catalog == null)
                      SamahaStatus(controller: c, compact: true)
                    else ...[
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
                              key: ValueKey('samaha-open-${kind.name}'),
                              onPressed:
                                  () => openSamahaDirectory(
                                    context,
                                    c,
                                    kind: kind,
                                  ),
                              icon: Icon(samahaEntryIcon(kind), size: 18),
                              label: Text(s.kind(kind)),
                            ),
                          if (catalog.find(SamahaEntryKind.faq).isNotEmpty)
                            TextButton(
                              onPressed:
                                  () => openSamahaDirectory(
                                    context,
                                    c,
                                    kind: SamahaEntryKind.faq,
                                  ),
                              child: Text(s.faqs),
                            ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: Semantics(
                              header: true,
                              child: Text(
                                s.companies,
                                style: const TextStyle(
                                  fontSize: 21,
                                  height: 1.4,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.corporateNavy,
                                ),
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () => openSamahaDirectory(context, c),
                            child: Text(s.viewAll),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      if (catalog.divisions.isEmpty)
                        SamahaEmptyState(message: s.empty)
                      else
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final large =
                                MediaQuery.textScalerOf(context).scale(1) >=
                                1.2;
                            Widget card(
                              SamahaCompany company, {
                              bool bounded = false,
                            }) => SamahaCompanyCard(
                              key: ValueKey('samaha-company-${company.id}'),
                              company: company,
                              catalog: catalog,
                              language: s.language,
                              bounded: bounded,
                              onTap:
                                  () =>
                                      openSamahaCompany(context, c, company.id),
                            );
                            if (large) {
                              return SamahaResponsiveCards(
                                children: catalog.divisions.map(card).toList(),
                              );
                            }
                            if (constraints.maxWidth >= 1080 &&
                                catalog.divisions.length <= 5) {
                              final width =
                                  (constraints.maxWidth -
                                      (catalog.divisions.length - 1) * 12) /
                                  catalog.divisions.length;
                              return Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  for (final company in catalog.divisions)
                                    SizedBox(
                                      width: width,
                                      height: 290,
                                      child: card(company, bounded: true),
                                    ),
                                ],
                              );
                            }
                            final width = math.min(
                              310.0,
                              math.max(250.0, constraints.maxWidth * .86),
                            );
                            return SizedBox(
                              height: 306,
                              child: Scrollbar(
                                controller: _scroll,
                                thumbVisibility: true,
                                child: SingleChildScrollView(
                                  controller: _scroll,
                                  scrollDirection: Axis.horizontal,
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Row(
                                    children: [
                                      for (final company in catalog.divisions)
                                        Padding(
                                          padding:
                                              const EdgeInsetsDirectional.only(
                                                end: 12,
                                              ),
                                          child: SizedBox(
                                            width: width,
                                            height: 290,
                                            child: card(company, bounded: true),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                    ],
                  ],
                ),
              ),
        ),
      );
    },
  );
}
