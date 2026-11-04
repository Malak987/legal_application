import 'package:flutter/material.dart';

import '../../services/api_client.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import 'act.dart';

// Define consistent colors based on the screenshot
const Color primaryRed = Color(0xFFB71C1C); // Dark red for AppBar
const Color cardRed = Color(0xFFD32F2F);   // Slightly lighter red for cards
const Color searchBgGrey = Color(0xFFF0F0F0); // Light grey for search background
const Color hintGrey = Colors.grey;
const Color cardTextWhite = Colors.white;

/// The signed-in user's cases, read from the Supabase cases table under RLS.
///
/// PostgreSQL RLS scopes the query to the signed-in caller, so the app never
/// sends an owner ID. Tapping a row opens the case detail view by its stable
/// ID; unbacked hearing/document/history content is not shown.
class MyCasesScreen extends StatefulWidget {
  const MyCasesScreen({super.key});

  @override
  State<MyCasesScreen> createState() => _MyCasesScreenState();
}

class _MyCasesScreenState extends State<MyCasesScreen> {
  late Future<List<Map<String, dynamic>>> _cases;

  @override
  void initState() {
    super.initState();
    // Deferred: the session is only reachable through context.
    _cases = Future.value(const <Map<String, dynamic>>[]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadIfNeeded();
  }

  bool _loaded = false;

  void _loadIfNeeded() {
    if (_loaded) return;
    _loaded = true;
    _reload();
  }

  /// Re-runs the query. Also used as the pull-to-refresh handler, so it
  /// returns the future it started.
  Future<void> _reload() {
    final session = SessionScope.read(context);
    final future = session.repository.fetchMyCases();
    setState(() {
      _cases = future;
    });
    // Errors are rendered by the FutureBuilder; awaiting here would surface
    // them a second time as an unhandled exception from RefreshIndicator.
    return future.then((_) {}, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13),
              child: CustomAppBar(text: 'My Cases', text1: ''),
            ),
            Expanded(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _cases,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return _Message(
                      icon: Icons.error_outline,
                      title: 'Could not load your cases',
                      detail: snapshot.error is ApiException
                          ? (snapshot.error as ApiException).message
                          : 'Please try again.',
                      onRetry: () => _reload(),
                    );
                  }
                  final cases = snapshot.data ?? const <Map<String, dynamic>>[];
                  if (cases.isEmpty) {
                    return const _Message(
                      icon: Icons.folder_open,
                      title: 'No cases yet',
                      detail: 'Cases created for your account will appear here.',
                    );
                  }
                  return RefreshIndicator(
                    onRefresh: _reload,
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12.0, vertical: 8.0),
                      itemCount: cases.length,
                      itemBuilder: (context, index) {
                        final item = cases[index];
                        final title = _text(item['title']);
                        final description = _text(item['description']);
                        final type = _text(item['caseType']);
                        final status = _text(item['status']);
                        final caseId = _text(item['id']);
                        return GestureDetector(
                          onTap: () {
                            if (caseId.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('This case has no usable ID.'),
                                ),
                              );
                              return;
                            }
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => CaseDetailsScreen(caseId: caseId),
                              ),
                            );
                          },
                          child: _buildCaseCard(
                            context: context,
                            title: title.isEmpty ? 'Untitled case' : title,
                            description: description.isEmpty
                                ? [type, status]
                                    .where((part) => part.isNotEmpty)
                                    .join(' • ')
                                : description,
                            date: _createdLabel(item['createdAt']),
                            status: status,
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _text(dynamic value) => value?.toString().trim() ?? '';

  /// Formats `createdAt`, which can be an ISO string or a serialized timestamp
  /// as `{_seconds: n}`). Unknown shapes are shown as-is rather than hidden.
  static String _createdLabel(dynamic value) {
    if (value == null) return '';
    var raw = value.toString();
    if (value is Map && value['_seconds'] is num) {
      raw = DateTime.fromMillisecondsSinceEpoch(
        (value['_seconds'] as num).toInt() * 1000,
      ).toIso8601String();
    }
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    final now = DateTime.now();
    final sameDay =
        local.year == now.year && local.month == now.month && local.day == now.day;
    if (sameDay) {
      final hhmm = '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
      return '$hhmm, Today';
    }
    return '${local.day}/${local.month}/${local.year}';
  }

  Widget _buildCaseCard({
    required BuildContext context,
    required String title,
    required String description,
    required String date,
    required String status,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2.0), // Spacing between cards
      child: Card(
        color: Colors.white,
        child: IntrinsicHeight( // Ensures Row children have same height
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch, // Stretch children vertically
            children: [
              // Image part (bundled illustration, not backend data)
              ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(10.0),
                  bottomLeft: Radius.circular(10.0),
                ),
                child: Image.asset(
                  'images/case.png',
                  width: 100, // Adjust width as needed
                  height: 80, // Make it square or adjust aspect ratio
                  fit: BoxFit.cover,
                  // Error handling for image loading
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      width: 100,
                      height: 80,
                      color: Colors.grey[300],
                      child: const Icon(Icons.broken_image, color: Colors.grey),
                    );
                  },
                ),
              ),

              // Text content part
              const SizedBox(width: 10,),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(0.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center, // Center text vertically
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6.0),
                      Text(
                        description,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 13,
                        ),
                        maxLines: 2, // Allow description to wrap slightly
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6.0),
                      Row(
                        children: [
                          Text(
                            date,
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (status.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                status,
                                style: const TextStyle(
                                  color: cardRed,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared loading/empty/error placeholder.
class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: hintGrey),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: hintGrey),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}

// --- To Run this Screen (Example Usage) ---
