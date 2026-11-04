import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../constants/colors.dart';
import '../../models/samaha_catalog.dart';
import '../../state/samaha_controller.dart';
import 'samaha_strings.dart';

typedef SamahaLinkOpener = Future<bool> Function(Uri uri);

/// One feature-scoped design system, also used by the existing Legal Home.
/// No global app/auth theme or backend configuration is replaced.
ThemeData samahaTheme(ThemeData base) {
  final text = base.textTheme.apply(
    fontFamily: 'DirectoryArabic',
    bodyColor: AppColors.corporateInk,
    displayColor: AppColors.corporateNavy,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.corporatePaper,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.corporateNavy,
    ).copyWith(
      primary: AppColors.corporateNavy,
      onPrimary: Colors.white,
      secondary: AppColors.corporateGold,
      surface: Colors.white,
      onSurface: AppColors.corporateInk,
      outline: AppColors.corporateLine,
    ),
    textTheme: text.copyWith(
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 14, height: 1.6),
      bodyLarge: text.bodyLarge?.copyWith(fontSize: 16, height: 1.65),
      titleLarge: text.titleLarge?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
      ),
    ),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: 'DirectoryArabic',
    ),
    dividerColor: AppColors.corporateLine,
    iconTheme: const IconThemeData(color: AppColors.corporateNavy),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.corporatePaper,
      foregroundColor: AppColors.corporateNavy,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 76,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.corporateLine),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.corporateNavy,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: shape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.corporateNavy,
        minimumSize: const Size(48, 48),
        side: const BorderSide(color: AppColors.corporateLine),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.corporateNavy,
        minimumSize: const Size(48, 48),
        shape: shape,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      labelStyle: const TextStyle(
        color: AppColors.corporateMuted,
        fontSize: 14,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.corporateLine),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.corporateLine),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(
          color: AppColors.corporateNavy,
          width: 1.5,
        ),
      ),
    ),
  );
}

class SamahaEyebrow extends StatelessWidget {
  const SamahaEyebrow(this.text, {super.key, this.light = false});
  final String text;
  final bool light;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.5,
      height: 1.6,
      color: light ? const Color(0xFFE7CB93) : AppColors.corporateGoldText,
    ),
  );
}

class SamahaEmptyState extends StatelessWidget {
  const SamahaEmptyState({
    super.key,
    required this.message,
    this.icon = Icons.search_off,
    this.action,
  });
  final String message;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(28),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.corporateLine),
    ),
    child: Column(
      children: [
        Icon(icon, size: 36, color: AppColors.corporateMuted),
        const SizedBox(height: 12),
        Text(message, textAlign: TextAlign.center),
        if (action != null) ...[const SizedBox(height: 12), action!],
      ],
    ),
  );
}

class SamahaPanel extends StatelessWidget {
  const SamahaPanel({super.key, required this.child, this.padding = 24});
  final Widget child;
  final double padding;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(padding),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: AppColors.corporateLine),
    ),
    child: child,
  );
}

class SamahaLocale extends StatelessWidget {
  const SamahaLocale({
    super.key,
    required this.language,
    required this.child,
    this.corporateTheme = true,
  });
  final String language;
  final Widget child;

  /// Home keeps the original application theme; only its bottom directory
  /// and directory routes use the corporate theme. Locale/RTL stay shared.
  final bool corporateTheme;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final localFont = corporateTheme || language == 'ar';
    final theme =
        corporateTheme
            ? samahaTheme(base)
            : language == 'ar'
            ? base.copyWith(
              textTheme: base.textTheme.apply(fontFamily: 'DirectoryArabic'),
              primaryTextTheme: base.primaryTextTheme.apply(
                fontFamily: 'DirectoryArabic',
              ),
            )
            : base;
    return Localizations.override(
      context: context,
      locale: Locale(language),
      delegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      child: Theme(
        data: theme,
        child: Directionality(
          textDirection:
              language == 'ar' ? TextDirection.rtl : TextDirection.ltr,
          // A plain heading also needs the bundled Arabic font. English Home
          // inherits its original app typography rather than corporate fonts.
          child: DefaultTextStyle.merge(
            style:
                localFont
                    ? const TextStyle(fontFamily: 'DirectoryArabic')
                    : base.textTheme.bodyMedium ?? const TextStyle(),
            child: child,
          ),
        ),
      ),
    );
  }
}

class SamahaLanguageButton extends StatelessWidget {
  const SamahaLanguageButton({super.key, required this.controller});
  final SamahaController controller;
  @override
  Widget build(BuildContext context) {
    final label = controller.language == 'ar' ? 'English' : 'العربية';
    void toggle() =>
        controller.setLanguage(controller.language == 'ar' ? 'en' : 'ar');
    if (MediaQuery.sizeOf(context).width < 480 &&
        MediaQuery.textScalerOf(context).scale(1) > 1.2) {
      return IconButton(
        key: const ValueKey('samaha-language'),
        tooltip: label,
        onPressed: toggle,
        icon: const Icon(Icons.translate),
      );
    }
    return TextButton.icon(
      key: const ValueKey('samaha-language'),
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: AppColors.corporateNavy,
      ),
      onPressed: toggle,
      icon: const Icon(Icons.translate, size: 18),
      label: Text(label),
    );
  }
}

class SamahaText extends StatelessWidget {
  const SamahaText(
    this.content, {
    super.key,
    required this.language,
    this.style,
    this.maxLines,
    this.selectable = false,
  });
  final LocalizedContent content;
  final String language;
  final TextStyle? style;
  final int? maxLines;
  final bool selectable;
  @override
  Widget build(BuildContext context) {
    final direction =
        content.languageFor(language) == 'ar'
            ? TextDirection.rtl
            : TextDirection.ltr;
    if (selectable) {
      return SelectableText(
        // A selectable's internal scroll offset must not share its parent's
        // PageStorage entry (an ExpansionTile stores a bool there).
        key: PageStorageKey('samaha-text:${content.text(language)}'),
        content.text(language),
        style: style,
        textDirection: direction,
        textAlign: language == 'ar' ? TextAlign.right : TextAlign.left,
      );
    }
    return Text(
      content.text(language),
      style: style,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      textDirection: direction,
      textAlign: language == 'ar' ? TextAlign.right : TextAlign.left,
    );
  }
}

class SamahaStatus extends StatelessWidget {
  const SamahaStatus({
    super.key,
    required this.controller,
    this.compact = false,
  });
  final SamahaController controller;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final s = SamahaStrings(controller.language);
    final loading =
        controller.state == SamahaLoadState.loading ||
        controller.state == SamahaLoadState.idle;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 16 : 32),
        child: SamahaPanel(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(
                  Icons.folder_off_outlined,
                  size: 36,
                  color: AppColors.corporateMuted,
                ),
              const SizedBox(height: 20),
              Text(
                loading ? s.loading : s.unavailable,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.corporateNavy,
                ),
              ),
              if (!loading) ...[
                const SizedBox(height: 12),
                Text(
                  s.assetHelp,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.corporateMuted,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: controller.load,
                  icon: const Icon(Icons.refresh),
                  label: Text(s.retry),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SamahaNotice extends StatelessWidget {
  const SamahaNotice(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFEFF2F3),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.info_outline,
          size: 18,
          color: AppColors.corporateMuted,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              height: 1.6,
              color: Color(0xFF35455E),
            ),
          ),
        ),
      ],
    ),
  );
}

class SamahaHeading extends StatelessWidget {
  const SamahaHeading(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Semantics(
      header: true,
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: AppColors.corporateNavy,
        ),
      ),
    ),
  );
}

IconData samahaCompanyIcon(SamahaCompany company) => switch (company.id) {
  'company_legal' => Icons.balance_outlined,
  'company_debt' => Icons.account_balance_wallet_outlined,
  'company_businessmen' => Icons.business_center_outlined,
  'company_immigration' => Icons.public,
  'company_translation' => Icons.translate,
  _ => Icons.hub_outlined,
};
IconData samahaEntryIcon(SamahaEntryKind kind) => switch (kind) {
  SamahaEntryKind.person => Icons.person_outline,
  SamahaEntryKind.branch => Icons.location_on_outlined,
  SamahaEntryKind.faq => Icons.help_outline,
  SamahaEntryKind.article => Icons.article_outlined,
  _ => Icons.description_outlined,
};

class SamahaImage extends StatelessWidget {
  const SamahaImage({
    super.key,
    required this.media,
    required this.language,
    required this.fallback,
    this.size = 56,
    this.height,
    this.radius = 12,
  });
  final SamahaMedia? media;
  final String language;
  final IconData fallback;
  final double size;
  final double? height;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final item = media;
    final portrait =
        fallback == Icons.person_outline || item?.role == 'portrait';
    final fallbackWidget = Container(
      width: size,
      height: height ?? size,
      decoration: BoxDecoration(
        color: AppColors.corporateSoft,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Center(
        child: Icon(
          fallback,
          color: AppColors.corporateMuted,
          size: portrait ? (size * .28).clamp(32.0, 64.0) : size * .48,
        ),
      ),
    );
    if (item == null || !item.isDisplayable) {
      return Semantics(
        label: portrait ? SamahaStrings(language).portraitUnavailable : null,
        child: ExcludeSemantics(child: fallbackWidget),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Semantics(
        image: true,
        label:
            '${item.altText.text(language)}${item.isSourceReference ? '. ${SamahaStrings(language).rightsUnknown}' : ''}',
        child: Image.asset(
          item.assetPath,
          width: size,
          height: height ?? size,
          fit: portrait ? BoxFit.cover : BoxFit.contain,
          alignment: portrait ? Alignment.topCenter : Alignment.center,
          errorBuilder: (_, _, _) => fallbackWidget,
        ),
      ),
    );
  }
}

class SamahaCompanyCard extends StatelessWidget {
  const SamahaCompanyCard({
    super.key,
    required this.company,
    required this.catalog,
    required this.language,
    required this.onTap,
    this.bounded = false,
  });
  final SamahaCompany company;
  final SamahaCatalog catalog;
  final String language;
  final VoidCallback onTap;
  final bool bounded;
  @override
  Widget build(BuildContext context) {
    final s = SamahaStrings(language);
    final large = MediaQuery.textScalerOf(context).scale(1) > 1.25;
    return Semantics(
      button: true,
      onTap: onTap,
      label:
          '${company.name.text(language)}. ${company.summary.text(language)}. ${s.details}',
      excludeSemantics: true,
      child: Material(
        color: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.corporateLine),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SamahaImage(
                      media: catalog.image(company.id),
                      language: language,
                      fallback: samahaCompanyIcon(company),
                      size: 42,
                    ),
                    const Spacer(),
                    const Icon(
                      Icons.north_east,
                      size: 17,
                      color: AppColors.corporateGold,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SamahaText(
                  company.name,
                  language: language,
                  maxLines: large ? null : 3,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.45,
                    fontWeight: FontWeight.w700,
                    color: AppColors.corporateNavy,
                  ),
                ),
                const SizedBox(height: 10),
                SamahaText(
                  company.summary,
                  language: language,
                  maxLines: large ? null : 3,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: AppColors.corporateMuted,
                  ),
                ),
                if (bounded) const Spacer() else const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.details,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.corporateBlue,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.arrow_forward,
                      size: 17,
                      color: AppColors.corporateBlue,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SamahaResponsiveCards extends StatelessWidget {
  const SamahaResponsiveCards({
    super.key,
    required this.children,
    this.minimumWidth = 280,
  });
  final List<Widget> children;
  final double minimumWidth;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final large = MediaQuery.textScalerOf(context).scale(1) > 1.4;
      final columns =
          large
              ? 1
              : ((constraints.maxWidth + 16) / (minimumWidth + 16))
                  .floor()
                  .clamp(1, 4);
      final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

Future<void> openSamahaLink(
  BuildContext context,
  Uri uri,
  SamahaStrings s, {
  SamahaLinkOpener? opener,
}) async {
  bool opened = false;
  final safe =
      samahaWebUri(uri.toString()) != null ||
      RegExp(r'^tel:\+?[0-9]{7,15}$').hasMatch(uri.toString()) ||
      (uri.scheme == 'mailto' &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          RegExp(r'^[^@\s?,]+@[^@\s?,]+\.[^@\s?,]+$').hasMatch(uri.path));
  if (safe) {
    try {
      opened = await (opener ??
          (uri) => launchUrl(uri, mode: LaunchMode.externalApplication))(uri);
    } catch (_) {
      opened = false;
    }
  }
  if (!context.mounted || opened) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(s.linkFailed)));
}

class SamahaContacts extends StatelessWidget {
  const SamahaContacts({
    super.key,
    required this.entries,
    required this.language,
    this.opener,
  });
  final List<SamahaEntry> entries;
  final String language;
  final SamahaLinkOpener? opener;
  @override
  Widget build(BuildContext context) {
    final s = SamahaStrings(language);
    if (entries.isEmpty) {
      return Text(s.noContacts, style: const TextStyle(height: 1.6));
    }
    return SamahaResponsiveCards(
      minimumWidth: 320,
      children: [
        for (final entry in entries)
          if (entry.contact != null)
            Card(
              key: ValueKey('samaha-contact-card-${entry.id}'),
              margin: EdgeInsets.zero,
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SamahaText(
                      entry.title,
                      language: language,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.corporateNavy,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      key: PageStorageKey('samaha-contact-value:${entry.id}'),
                      entry.contact!.displayValue,
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(fontSize: 14, height: 1.6),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        OutlinedButton.icon(
                          key: ValueKey('samaha-contact-${entry.id}'),
                          onPressed:
                              () => openSamahaLink(
                                context,
                                entry.contact!.uri,
                                s,
                                opener: opener,
                              ),
                          icon: Icon(
                            entry.contact!.kind == 'phone'
                                ? Icons.phone_outlined
                                : entry.contact!.kind == 'email'
                                ? Icons.mail_outline
                                : Icons.open_in_new,
                            size: 18,
                          ),
                          label: Text(s.action(entry.contact!.kind)),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: entry.contact!.displayValue),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(SnackBar(content: Text(s.copied)));
                            }
                          },
                          icon: const Icon(Icons.copy_outlined, size: 18),
                          label: Text(s.copy),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

class SamahaSources extends StatelessWidget {
  const SamahaSources({
    super.key,
    required this.sources,
    required this.language,
  });
  final List<SamahaSource> sources;
  final String language;
  @override
  Widget build(BuildContext context) {
    final urls = sources.map((s) => s.url).toSet();
    return SamahaPanel(
      padding: 8,
      child: ExpansionTile(
        // Expansion bool, outer-list offset and selectable offsets must NEVER
        // share a PageStorage identity. ValueKey alone does not isolate it.
        key: PageStorageKey('samaha-sources:${urls.join('|')}'),
        leading: const Icon(
          Icons.fact_check_outlined,
          color: AppColors.corporateGold,
        ),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(
          SamahaStrings(language).sources,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        children: [
          for (final url in urls)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: SelectableText(
                  Uri.decodeFull(url),
                  key: PageStorageKey('samaha-source-url:$url'),
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: AppColors.corporateBlue,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The final section of every company profile, including the parent group.
/// An unavailable company URL is an explicit disabled action, never a redirect
/// to another division. No launch occurs until the user taps the button.
class SamahaWebsiteFooter extends StatelessWidget {
  const SamahaWebsiteFooter({
    super.key,
    required this.company,
    required this.language,
    this.opener,
  });
  final SamahaCompany company;
  final String language;
  final SamahaLinkOpener? opener;

  @override
  Widget build(BuildContext context) {
    final s = SamahaStrings(language);
    final website = company.website;
    return Padding(
      key: ValueKey('samaha-website-footer-${company.id}'),
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(),
          const SizedBox(height: 16),
          if (website == null) ...[
            Text(
              s.websiteUnavailable,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (company.websiteUnavailableReason.isEmpty)
              Text(s.noWebsite)
            else
              SamahaText(company.websiteUnavailableReason, language: language),
          ] else ...[
            Text(
              website.host,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(s.externalWebsite),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            key: ValueKey('samaha-website-${company.id}'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.corporateNavy,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              minimumSize: const Size(48, 56),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed:
                website == null
                    ? null
                    : () => openSamahaLink(context, website, s, opener: opener),
            icon: const Icon(Icons.open_in_new, size: 20),
            label: Text(s.officialWebsite, textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }
}
