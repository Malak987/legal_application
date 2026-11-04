import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../services/api_client.dart';
import '../../state/session_scope.dart';

/// Detail view for one caller-authorized case, loaded by its stable API ID.
///
/// Hearing dates, documents, and case-history rows are intentionally not
/// shown: the current case model/API has no such data.
class CaseDetailsScreen extends StatefulWidget {
  const CaseDetailsScreen({super.key, required this.caseId});

  final String caseId;

  @override
  State<CaseDetailsScreen> createState() => _CaseDetailsScreenState();
}

class _CaseDetailsScreenState extends State<CaseDetailsScreen> {
  late Future<Map<String, dynamic>> _case;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _case = Future<Map<String, dynamic>>.value(const <String, dynamic>{});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _reload();
  }

  Future<void> _reload() {
    final future = SessionScope.read(context).repository.fetchCase(widget.caseId);
    setState(() {
      _case = future;
    });
    // FutureBuilder owns error presentation; do not rethrow through
    // RefreshIndicator and surface the same failure twice.
    return future.then<void>((_) {}, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Case Details'),
        centerTitle: true,
        backgroundColor: Colors.white,
        foregroundColor: AppColors.text1Color,
        elevation: 0,
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _case,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            final error = snapshot.error;
            final detail = error is ApiException ? error.message : 'Please try again.';
            return _CaseDetailMessage(
              icon: Icons.error_outline,
              title: 'Could not load this case',
              detail: detail,
              onRetry: _reload,
            );
          }

          final item = snapshot.data ?? const <String, dynamic>{};
          if (item.isEmpty) {
            return _CaseDetailMessage(
              icon: Icons.folder_open,
              title: 'Case not found',
              detail: 'This case is no longer available to your account.',
              onRetry: _reload,
            );
          }

          final title = _text(item['title']);
          final description = _text(item['description']);
          final category = _firstText(item['categoryName'], item['caseType']);
          final lawyer = _text(item['lawyerName']);
          final dueDate = _text(item['dueDate']);
          final createdAt = _text(item['createdAt']);

          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  title.isEmpty ? 'Untitled case' : title,
                  style: const TextStyle(
                    color: AppColors.text1Color,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  elevation: 1,
                  color: AppColors.bgColor,
                  child: Column(
                    children: [
                      _CaseField(label: 'Client', value: _text(item['clientName'])),
                      _CaseField(label: 'Category / case type', value: category),
                      _CaseField(
                        label: 'Assigned lawyer',
                        value: lawyer.isEmpty ? 'Not assigned' : lawyer,
                      ),
                      _CaseField(label: 'Status', value: _text(item['status'])),
                      _CaseField(label: 'Priority', value: _text(item['priority'])),
                      if (dueDate.isNotEmpty)
                        _CaseField(label: 'Due date', value: dueDate),
                      if (createdAt.isNotEmpty)
                        _CaseField(label: 'Created', value: createdAt, last: true),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Description',
                  style: TextStyle(
                    color: AppColors.text1Color,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  description.isEmpty ? 'No description provided.' : description,
                  style: const TextStyle(
                    color: AppColors.text2Color,
                    fontSize: 15,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _text(dynamic value) => value?.toString().trim() ?? '';

  static String _firstText(dynamic first, dynamic fallback) {
    final value = _text(first);
    return value.isNotEmpty ? value : _text(fallback);
  }
}

class _CaseField extends StatelessWidget {
  const _CaseField({required this.label, required this.value, this.last = false});

  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 132,
                child: Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.text2Color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  value.isEmpty ? '—' : value,
                  style: const TextStyle(color: AppColors.text1Color),
                ),
              ),
            ],
          ),
        ),
        if (!last) const Divider(height: 1, indent: 14, endIndent: 14),
      ],
    );
  }
}

class _CaseDetailMessage extends StatelessWidget {
  const _CaseDetailMessage({
    required this.icon,
    required this.title,
    required this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: AppColors.text3Color),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(detail, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
