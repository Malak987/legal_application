import 'package:flutter/material.dart';

import '../../config/supabase_client_config.dart';
import '../../constants/colors.dart';
import '../samaha/samaha_entry_point.dart';

/// Root app shown when the compiled Supabase configuration is invalid.
///
/// Rendered instead of the splash/auth flow so no Auth or data request is made
/// with incomplete credentials. Retrying cannot help: Dart defines are fixed
/// at compile time, so the screen explains how to rebuild.
class SupabaseConfigErrorApp extends StatelessWidget {
  const SupabaseConfigErrorApp({super.key, required this.config});

  final SupabaseClientConfig config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Legal Services App',
      theme: ThemeData(
        scaffoldBackgroundColor: AppColors.bgColor,
        useMaterial3: true,
      ),
      home: SupabaseConfigErrorScreen(config: config),
    );
  }
}

class SupabaseConfigErrorScreen extends StatelessWidget {
  const SupabaseConfigErrorScreen({super.key, required this.config});

  final SupabaseClientConfig config;

  static const String _commands =
      '# Defines file (git-ignored; copy supabase.local.example.json)\n'
      '${SupabaseClientConfig.runCommandHint}\n'
      'flutter build apk --release --dart-define-from-file=supabase.local.json\n'
      '\n'
      '# Or validated by the helper\n'
      'dart run tool/supabase_flutter.dart run';

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      key: const Key('supabase-config-error'),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Card(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.settings_suggest_outlined,
                            color: AppColors.buttonColor,
                            size: 28,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Supabase is not configured for this build',
                              style: textTheme.titleLarge?.copyWith(
                                color: AppColors.text1Color,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      for (final issue in config.issueDescriptions)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(top: 2),
                                child: Icon(
                                  Icons.error_outline,
                                  size: 18,
                                  color: Colors.red,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(child: Text(issue)),
                            ],
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        'Compiled values — URL: '
                        '${config.url.isEmpty ? '(missing)' : config.url} · '
                        'key: ${config.redactedKey}',
                        style: textTheme.bodySmall?.copyWith(
                          color: AppColors.text2Color,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const SamahaDirectoryEntryButton(),
                      const SizedBox(height: 20),
                      Text('How to fix', style: textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.bgColor,
                          border: Border.all(color: AppColors.strokeColor),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const SelectableText(
                          _commands,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Dart defines are compiled into the app. Stop the app '
                        'and run or build it again with the defines — hot '
                        'restart, shell environment variables and builds '
                        'started directly from Xcode or Gradle do not apply new '
                        'values. Use only the public anon/publishable key, '
                        'never a secret or service-role key.',
                        style: textTheme.bodyMedium?.copyWith(
                          color: AppColors.text2Color,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
