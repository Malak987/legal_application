import 'dart:async';

import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../models/legal_category.dart';
import '../../models/product_model.dart';
import '../../services/api_client.dart';
import '../../services/app_repository.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../home/details.dart';

/// Lawyer search using the public lawyer-catalogue repository.
///
/// The directory supports anonymous reads, debounced search across name,
/// specialty and location, paginated results, and typed loading/error states.
/// A request sequence prevents stale responses from replacing newer results.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();

  /// Matches the debounce used by the admin panel's search box.
  static const Duration _debounceDelay = Duration(milliseconds: 350);

  Timer? _debounce;

  /// Guards against an older, slower response overwriting a newer one.
  int _requestSeq = 0;

  List<Product> _results = const <Product>[];
  List<LegalCategory> _categories = const <LegalCategory>[];
  String? _selectedCategoryId;
  String? _categoryError;
  bool _categoriesLoading = true;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  String? _error;
  String? _loadMoreError;

  @override
  void initState() {
    super.initState();
    // The first load runs without a rebuild: `_loading` already starts true and
    // the tree has not been built yet.
    _search('', initial: true);
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    try {
      final categories = await SessionScope.read(context).repository.fetchCategories();
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _categoriesLoading = false;
        _categoryError = null;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _categoriesLoading = false;
        _categoryError = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _categoriesLoading = false;
        _categoryError = 'Could not load categories.';
      });
    }
  }

  void _onCategorySelected(String? categoryId) {
    setState(() => _selectedCategoryId = categoryId);
    _search(_controller.text.trim());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    // Invalidate an in-flight response immediately, not after the debounce, so
    // it cannot briefly replace results for the text now on screen.
    _requestSeq++;
    _debounce = Timer(_debounceDelay, () => _search(value));
    setState(() {
      _loading = true;
      _error = null;
      _loadingMore = false;
      _loadMoreError = null;
    });
  }

  Future<void> _search(String query, {bool initial = false}) async {
    final seq = ++_requestSeq;
    if (!initial && mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _loadingMore = false;
        _loadMoreError = null;
        _hasMore = false;
        _page = 1;
      });
    }

    // Read the repository before the await: `context` must not be used after an
    // asynchronous gap.
    final repository = SessionScope.read(context).repository;

    try {
      final result = await repository.fetchLawyerPage(
        search: query.trim(),
        categoryId: _selectedCategoryId,
        page: 1,
        limit: AppRepository.lawyerPageSize,
      );
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _results = result.items;
        _page = result.page;
        _hasMore = result.hasMore;
        _loadingMore = false;
        _loadMoreError = null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _error = e.message;
        _hasMore = false;
        _loadingMore = false;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _error = 'Could not search right now. Check your connection and retry.';
        _hasMore = false;
        _loadingMore = false;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final seq = _requestSeq;
    final nextPage = _page + 1;
    final query = _controller.text.trim();
    final repository = SessionScope.read(context).repository;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });

    try {
      final result = await repository.fetchLawyerPage(
        search: query,
        categoryId: _selectedCategoryId,
        page: nextPage,
        limit: AppRepository.lawyerPageSize,
      );
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        final seenIds = _results.map((lawyer) => lawyer.id).toSet();
        final appended = <Product>[];
        for (final lawyer in result.items) {
          if (seenIds.add(lawyer.id)) appended.add(lawyer);
        }
        _results = <Product>[..._results, ...appended];
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

  void _clear() {
    _controller.clear();
    _debounce?.cancel();
    _search('');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final query = _controller.text.trim();

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(text: 'Search', text1: ''),
              const SizedBox(height: 18),
              TextField(
                controller: _controller,
                onChanged: _onQueryChanged,
                textInputAction: TextInputAction.search,
                onSubmitted: (value) {
                  _debounce?.cancel();
                  _search(value);
                },
                decoration: InputDecoration(
                  hintText: 'Search by name, specialty or city',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close),
                          onPressed: _clear,
                        ),
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _buildCategoryFilters(),
              const SizedBox(height: 8),
              Expanded(child: _buildBody(query)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryFilters() {
    if (_categoriesLoading) {
      return const SizedBox(
        height: 34,
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_categories.isEmpty) {
      if (_categoryError == null) return const SizedBox.shrink();
      return SizedBox(
        height: 36,
        child: Row(
          children: [
            const Expanded(child: Text('Category filters are unavailable.')),
            IconButton(
              tooltip: 'Retry categories',
              onPressed: _loadCategories,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: const Text('All'),
              selected: _selectedCategoryId == null,
              onSelected: (_) => _onCategorySelected(null),
            ),
          ),
          for (final category in _categories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(category.name),
                selected: _selectedCategoryId == category.id,
                onSelected: (selected) => _onCategorySelected(
                  selected ? category.id : null,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(String query) {
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _SearchStatus(
        icon: Icons.error_outline,
        title: 'Search failed',
        detail: _error!,
        onRetry: () => _search(query),
      );
    }

    if (_results.isEmpty) {
      return _SearchStatus(
        icon: Icons.search_off,
        title: query.isEmpty ? 'No lawyers listed yet' : 'No lawyers found',
        detail: query.isEmpty
            ? 'Lawyers added by an administrator will appear here.'
            : 'Nothing matches "$query". Try a different name or city.',
      );
    }

    final hasFooter = !_loading &&
        (_hasMore || _loadingMore || _loadMoreError != null);
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _results.length + (hasFooter ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < _results.length) {
          return _LawyerResultCard(
            lawyer: _results[index],
            // A search request is in flight: dim the stale rows instead of
            // flickering them out, which keeps the list readable while typing.
            dimmed: _loading,
          );
        }
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
      },
    );
  }
}

class _LawyerResultCard extends StatelessWidget {
  const _LawyerResultCard({required this.lawyer, required this.dimmed});

  final Product lawyer;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final rating = lawyer.rating;
    final location = (lawyer.location ?? '').trim();
    final specialty = (lawyer.specialty ?? '').trim();
    final price = lawyer.price.trim();

    return Opacity(
      opacity: dimmed ? 0.55 : 1,
      child: GestureDetector(
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
          elevation: 4,
          shadowColor: Colors.black12,
          color: Colors.white,
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        lawyer.name.trim().isEmpty ? 'Unnamed lawyer' : lawyer.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppColors.text1Color,
                        ),
                      ),
                    ),
                    if (rating != null)
                      Row(
                        children: [
                          const Icon(Icons.star, size: 16, color: Colors.amber),
                          const SizedBox(width: 4),
                          Text(
                            rating.toStringAsFixed(1),
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                if (specialty.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    specialty,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.text2Color,
                    ),
                  ),
                ],
                if (location.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(
                        Icons.location_on_outlined,
                        size: 14,
                        color: AppColors.text3Color,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          location,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.text2Color,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (price.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    price,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.buttonColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Loading/empty/error placeholder with an optional retry action.
class _SearchStatus extends StatelessWidget {
  const _SearchStatus({
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
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 46, color: AppColors.text3Color),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.text1Color,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.text2Color),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 14),
              TextButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}
