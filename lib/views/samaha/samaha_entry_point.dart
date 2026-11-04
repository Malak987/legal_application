import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/samaha_repository.dart';
import '../../state/samaha_controller.dart';
import 'samaha_pages.dart';
import 'samaha_strings.dart';
import 'samaha_widgets.dart';

/// Public information only. This route never creates/reads a session or opens
/// the operational home screen. The owner keeps the controller alive while
/// company/service/person pages are pushed, then disposes it on return.
class SamahaOfflineDirectory extends StatefulWidget {
  const SamahaOfflineDirectory({super.key, this.language, this.repository});
  final String? language;
  final SamahaRepository? repository;

  @override
  State<SamahaOfflineDirectory> createState() => _SamahaOfflineDirectoryState();
}

class _SamahaOfflineDirectoryState extends State<SamahaOfflineDirectory> {
  late final SamahaController _controller;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _controller = SamahaController(
      loader:
          (widget.repository ??
                  SamahaRepository(bundle: DefaultAssetBundle.of(context)))
              .fetchCatalog,
      language:
          widget.language ??
          WidgetsBinding.instance.platformDispatcher.locale.languageCode,
    );
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    if (_initialized) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SamahaDirectoryPage(controller: _controller);
}

/// Gives offline users a directory route without relaxing any auth guard.
/// Scoped localization and the bundled font do not restyle the sign-in form.
class SamahaDirectoryEntryButton extends StatelessWidget {
  const SamahaDirectoryEntryButton({super.key});

  @override
  Widget build(BuildContext context) {
    final language =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'ar'
            ? 'ar'
            : 'en';
    final s = SamahaStrings(language);
    return SamahaLocale(
      language: language,
      child: OutlinedButton.icon(
        key: const ValueKey('samaha-public-entry'),
        onPressed:
            () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                settings: const RouteSettings(name: '/samaha/offline'),
                builder: (_) => SamahaOfflineDirectory(language: language),
              ),
            ),
        icon: const Icon(Icons.business_outlined),
        label: Text(s.browseOffline, textAlign: TextAlign.center),
      ),
    );
  }
}
