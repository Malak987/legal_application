import 'package:legalserviceapp/widgets/customapp_bar.dart';
import 'package:legalserviceapp/views/messages/chat_screen.dart';
import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../models/product_model.dart';
import '../../services/api_client.dart';
import '../../services/app_repository.dart';
import '../../state/session_scope.dart';
import '../../widgets/detailstext1.dart';
import '../home/details.dart';

/// The lawyer directory, read from the public lawyer-catalogue repository.
///
/// The same widget serves two menu entries: "Popular Lawyers"
/// (`onlyTop: false`, `isPopular=true`) and "Top Lawyers" (`onlyTop: true`,
/// `isTop=true`). Both use server-side filters and preserve them while paging.
class PopularLawyersScreen extends StatefulWidget {
  const PopularLawyersScreen({
    super.key,
    this.onlyTop = false,
    this.title = 'Popular Lawyers',
  });

  /// When true, lists `isTop` lawyers instead of `isPopular` ones.
  final bool onlyTop;

  /// Header text, so one screen can serve both menu entries.
  final String title;

  @override
  State<PopularLawyersScreen> createState() => _PopularLawyersScreenState();
}

class _PopularLawyersScreenState extends State<PopularLawyersScreen> {
  List<Product> _lawyers = const <Product>[];
  bool _loaded = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  int _requestSeq = 0;
  String? _error;
  String? _loadMoreError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _reload();
  }

  Future<void> _reload() async {
    final seq = ++_requestSeq;
    final repository = SessionScope.read(context).repository;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _hasMore = false;
      _page = 1;
      _error = null;
      _loadMoreError = null;
    });

    try {
      final result = await repository.fetchLawyerPage(
        isPopular: widget.onlyTop ? null : true,
        isTop: widget.onlyTop ? true : null,
        page: 1,
        limit: AppRepository.lawyerPageSize,
      );
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _lawyers = result.items;
        _page = result.page;
        _hasMore = result.hasMore;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _error = 'Please check your connection and try again.';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final seq = _requestSeq;
    final repository = SessionScope.read(context).repository;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });

    try {
      final result = await repository.fetchLawyerPage(
        isPopular: widget.onlyTop ? null : true,
        isTop: widget.onlyTop ? true : null,
        page: _page + 1,
        limit: AppRepository.lawyerPageSize,
      );
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        final seenIds = _lawyers.map((lawyer) => lawyer.id).toSet();
        final appended = <Product>[];
        for (final lawyer in result.items) {
          if (seenIds.add(lawyer.id)) appended.add(lawyer);
        }
        _lawyers = <Product>[..._lawyers, ...appended];
        _page = result.page;
        _hasMore = result.hasMore;
        _loadingMore = false;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _loadMoreError = e.message;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _loadMoreError = 'Could not load more lawyers. Please try again.';
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14.0),
          child: Column(
            children: [
              const SizedBox(height: 12),
              CustomAppBar(text: widget.title, text1: ''),
              const SizedBox(height: 12),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _lawyers.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _Status(
        icon: Icons.error_outline,
        title: 'Could not load lawyers',
        detail: _error!,
        onRetry: _reload,
      );
    }
    if (_lawyers.isEmpty) {
      return _Status(
        icon: Icons.search_off,
        title: widget.onlyTop ? 'No top-rated lawyers yet' : 'No lawyers listed yet',
        detail: widget.onlyTop
            ? 'Lawyers marked as top-rated by an administrator will appear here.'
            : 'Lawyers added by an administrator will appear here.',
      );
    }

    final hasFooter = _hasMore || _loadingMore || _loadMoreError != null;
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: _lawyers.length + (hasFooter ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _lawyers.length) return _buildLoadMoreFooter();
          final lawyer = _lawyers[index];
          return GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => LegalServiceDetailsScreen(
                    lawyer: lawyer,
                    lawyerId: lawyer.id,
                  ),
                ),
              );
            },
            child: Card(
              elevation: 6,
              shadowColor: Colors.black12,
              color: Colors.white,
              margin: const EdgeInsets.only(bottom: 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10.0),
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: SizedBox(
                        height: 80,
                        width: 110,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: _LawyerPhoto(path: lawyer.imagePath),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text1(
                            text1: lawyer.name.isEmpty ? 'Lawyer' : lawyer.name,
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(Icons.star, color: Colors.amber, size: 18),
                              Text(
                                (lawyer.rating ?? 0) > 0
                                    ? lawyer.rating!.toStringAsFixed(1)
                                    : 'New',
                                style: const TextStyle(fontSize: 14),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(
                                Icons.location_on,
                                color: Colors.grey.shade600,
                                size: 18,
                              ),
                              Expanded(
                                child: Text(
                                  (lawyer.location ?? '').isEmpty
                                      ? 'Location not set'
                                      : lawyer.location!,
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 13,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text1(
                          text1: lawyer.price.isEmpty
                              ? 'Contact for pricing'
                              : lawyer.price,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: Colors.purple.shade50,
                              child: IconButton(
                                tooltip: 'Message lawyer',
                                icon: const Icon(Icons.message, color: Colors.purple),
                                onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const ChatScreen(),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            CircleAvatar(
                              backgroundColor: Colors.green.shade50,
                              child: IconButton(
                                tooltip: 'Contact lawyer',
                                icon: const Icon(Icons.phone, color: Colors.green),
                                onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const ChatScreen(),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLoadMoreFooter() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(18),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_loadMoreError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_loadMoreError!, textAlign: TextAlign.center),
            TextButton(onPressed: _loadMore, child: const Text('Retry loading more')),
          ],
        ),
      );
    }
    return Center(
      child: TextButton.icon(
        onPressed: _loadMore,
        icon: const Icon(Icons.expand_more),
        label: const Text('Load more'),
      ),
    );
  }

}

/// Lawyer photo with a bundled fallback.
///
/// The `image` field is a remote URL for real records and a bundled path for
/// the older seeded data, so both forms are accepted.
class _LawyerPhoto extends StatelessWidget {
  const _LawyerPhoto({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final fallback = Image.asset(
      'images/lawyer2.png',
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        color: AppColors.bgColor,
        child: const Icon(Icons.person, color: AppColors.text3Color),
      ),
    );
    if (path.isEmpty) return fallback;
    if (path.startsWith('http')) {
      return Image.network(
        path,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      );
    }
    return Image.asset(
      path,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => fallback,
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({
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
            Icon(icon, size: 42, color: AppColors.text3Color),
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
              style:
                  const TextStyle(fontSize: 13, color: AppColors.text2Color),
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
