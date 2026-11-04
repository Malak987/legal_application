import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../commonwidgets/home_widget.dart';
import '../../commonwidgets/product_card.dart';
import '../../constants/colors.dart';
import '../../models/legal_category.dart';
import '../../models/paginated_result.dart';
import '../../services/api_client.dart';
import '../../services/app_repository.dart';
import '../../services/samaha_repository.dart';
import '../../state/session_scope.dart';
import '../../state/samaha_controller.dart';
import '../samaha/samaha_home_section.dart';
import '../samaha/samaha_widgets.dart';
import '../samaha/samaha_strings.dart';

import '../../commonwidgets/caregivercategories.dart';
import '../../models/product_model.dart';
import '../../widgets/drawer_widget.dart';

/// Home screen. Loads the lawyer/service list from the backend REST API
/// and falls back to a friendly empty state when the API is unreachable.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Future<PaginatedResult<Product>> _future;
  late final SamahaController _samaha;
  final List<Product> _additionalResults = <Product>[];
  List<LegalCategory> _categories = const <LegalCategory>[];
  String? _selectedCategoryId;
  String? _categoriesError;
  bool _categoriesLoading = true;
  final Set<String?> _seenLawyerIds = <String?>{};
  int _requestSeq = 0;
  String? _error;
  String? _loadMoreError;
  int _page = 1;
  bool _hasMore = false;
  bool _loadingMore = false;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Static directory assets load independently of authentication/network.
    // Only operational lawyers/categories use the shared session repository.
    if (_loaded) return;
    _loaded = true;
    _samaha = SamahaController(
      loader:
          SamahaRepository(bundle: DefaultAssetBundle.of(context)).fetchCatalog,
      language: WidgetsBinding.instance.platformDispatcher.locale.languageCode,
    );
    unawaited(_samaha.load());
    _load();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final repository = SessionScope.read(context).repository;
    setState(() {
      _categoriesLoading = true;
      _categoriesError = null;
    });
    try {
      final categories = await repository.fetchCategories();
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _categoriesLoading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _categoriesLoading = false;
        _categoriesError = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _categoriesLoading = false;
        _categoriesError = 'Could not load categories. Please try again.';
      });
    }
  }

  void _onCategorySelected(LegalCategory? category) {
    _selectedCategoryId = category?.id;
    _load();
  }

  Future<void> _load() async {
    final seq = ++_requestSeq;
    final repository = SessionScope.read(context).repository;
    final request = repository.fetchLawyerPage(
      categoryId: _selectedCategoryId,
      page: 1,
      limit: AppRepository.lawyerPageSize,
    );
    setState(() {
      _error = null;
      _loadMoreError = null;
      _additionalResults.clear();
      _seenLawyerIds.clear();
      _page = 1;
      _hasMore = false;
      _loadingMore = false;
      _future = request;
    });

    try {
      final result = await request;
      if (mounted && seq == _requestSeq) {
        setState(() {
          _seenLawyerIds.addAll(result.items.map((lawyer) => lawyer.id));
          _page = result.page;
          _hasMore = result.hasMore;
        });
      }
    } catch (e) {
      if (mounted && seq == _requestSeq) setState(() => _error = '$e');
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final seq = _requestSeq;
    final repository = SessionScope.read(context).repository;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final result = await repository.fetchLawyerPage(
        categoryId: _selectedCategoryId,
        page: _page + 1,
        limit: AppRepository.lawyerPageSize,
      );
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        for (final lawyer in result.items) {
          if (_seenLawyerIds.add(lawyer.id)) _additionalResults.add(lawyer);
        }
        _page = result.page;
        _hasMore = result.hasMore;
        _loadingMore = false;
      });
    } on ApiException catch (e) {
      if (mounted && seq == _requestSeq) {
        setState(() {
          _loadMoreError = e.message;
          _loadingMore = false;
        });
      }
    } catch (_) {
      if (mounted && seq == _requestSeq) {
        setState(() {
          _loadMoreError = 'Could not load more lawyers. Please try again.';
          _loadingMore = false;
        });
      }
    }
  }

  @override
  void dispose() {
    if (_loaded) _samaha.dispose();
    super.dispose();
  }

  Future<void> _refreshHome() async {
    await Future.wait([_load(), _loadCategories(), _samaha.load()]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _samaha,
      builder: (context, _) {
        final s = SamahaStrings(_samaha.language);
        return SamahaLocale(
          language: _samaha.language,
          corporateTheme: false,
          child: Scaffold(
            backgroundColor: AppColors.bgColor,
            drawer: DrawerWidget(),
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final padding = math.max(
                    16.0,
                    (constraints.maxWidth - 1200) / 2,
                  );
                  final width = constraints.maxWidth - padding * 2;
                  final scale = MediaQuery.textScalerOf(context).scale(1);
                  // Two-column layout for all screens where cards fit comfortably.
// Minimum card width adjusted to fit two columns on mobile devices
// while maintaining readability and avoiding overflow.
                  final minCardWidth = 150.0;
                  final columns = width >= minCardWidth * 2 + 16 ? 2 : 1;
                  final cardWidth = (width - (columns - 1) * 16) / columns;
                  final cardHeight =
                      math.min(520.0, math.max(340.0, cardWidth * .92)) +
                      math.max(0.0, scale - 1) * 160;
                  return RefreshIndicator(
                    onRefresh: _refreshHome,
                    child: CustomScrollView(
                      key: const PageStorageKey('legal-home-scroll'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(padding, 16, padding, 0),
                          sliver: SliverToBoxAdapter(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Original Home colors, header and artwork;
                                // operational content keeps its original order.
                                Container(
                                  key: const ValueKey('legal-home-header'),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [
                                        AppColors.buttonColor,
                                        Colors.blueAccent,
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Colors.black26,
                                        blurRadius: 6,
                                        offset: Offset(0, 3),
                                      ),
                                    ],
                                  ),
                                  child: HomeWidgte(language: _samaha.language),
                                ),
                                const SizedBox(height: 6),
                                _OriginalHomePromotion(
                                  language: _samaha.language,
                                ),
                                const SizedBox(height: 10),
                                LegalServiceCategories(
                                  language: _samaha.language,
                                  categories: _categories,
                                  selectedCategoryId: _selectedCategoryId,
                                  onSelected: _onCategorySelected,
                                  isLoading: _categoriesLoading,
                                  error: _categoriesError,
                                  onRetry: _loadCategories,
                                ),
                                _HomeCatalogueHeading(
                                  controller: _samaha,
                                  onRefresh: _load,
                                ),
                              ],
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(padding, 0, padding, 16),
                          sliver: FutureBuilder<PaginatedResult<Product>>(
                            future: _future,
                            builder: (context, snapshot) {
                              if (snapshot.connectionState ==
                                  ConnectionState.waiting) {
                                return const SliverToBoxAdapter(
                                  child: SizedBox(
                                    height: 160,
                                    child: Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  ),
                                );
                              }
                              if (snapshot.hasError) {
                                return SliverToBoxAdapter(
                                  child: _ErrorState(
                                    message:
                                        _error ?? 'Could not load services.',
                                    onRetry: _load,
                                    language: _samaha.language,
                                  ),
                                );
                              }
                              final products = <Product>[
                                ...(snapshot.data?.items ?? const <Product>[]),
                                ..._additionalResults,
                              ];
                              if (products.isEmpty) {
                                return SliverToBoxAdapter(
                                  child: SizedBox(
                                    height: 160,
                                    child: Center(
                                      child: Text(
                                        s.t(
                                          'No services available yet.',
                                          'لا تتوفر خدمات مسجلة بعد.',
                                        ),
                                        style: const TextStyle(
                                          color: Colors.grey,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }
                              return SliverMainAxisGroup(
                                slivers: [
                                  SliverGrid(
                                    key: const ValueKey('home-lawyer-grid'),
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: columns,
                                          crossAxisSpacing: 16,
                                          mainAxisSpacing: 16,
                                          mainAxisExtent: cardHeight,
                                        ),
                                    delegate: SliverChildBuilderDelegate((
                                      context,
                                      index,
                                    ) {
                                      final product = products[index];
                                      return ProductCard(
                                        key: ValueKey(
                                          'home-lawyer-${product.id}',
                                        ),
                                        imagePath: product.imagePath,
                                        name: product.name,
                                        price: product.price,
                                        lawyer: product,
                                        rating: product.rating,
                                        language: _samaha.language,
                                      );
                                    }, childCount: products.length),
                                  ),
                                  if (_hasMore ||
                                      _loadingMore ||
                                      _loadMoreError != null)
                                    SliverToBoxAdapter(
                                      child: Padding(
                                        key: const ValueKey(
                                          'home-lawyer-pagination',
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 20,
                                        ),
                                        child:
                                            _loadingMore
                                                ? const Center(
                                                  child:
                                                      CircularProgressIndicator(),
                                                )
                                                : _loadMoreError != null
                                                ? Column(
                                                  children: [
                                                    Text(
                                                      _loadMoreError!,
                                                      textAlign:
                                                          TextAlign.center,
                                                    ),
                                                    TextButton(
                                                      onPressed: _loadMore,
                                                      child: Text(
                                                        s.t(
                                                          'Retry',
                                                          'إعادة المحاولة',
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                )
                                                : Center(
                                                  child: TextButton.icon(
                                                    onPressed: _loadMore,
                                                    icon: const Icon(
                                                      Icons.expand_more,
                                                    ),
                                                    label: Text(
                                                      s.t(
                                                        'Load more',
                                                        'عرض المزيد',
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ),
                        // One directory, after all loaded lawyers and their
                        // paging/error controls, in every operational state.
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(padding, 0, padding, 24),
                          sliver: SliverToBoxAdapter(
                            child: SamahaHomeSection(
                              controller: _samaha,
                              showLanguageControl: false,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The exact original banner asset and gradient, with flexible text so the
/// legacy fixed Row does not overflow on narrow phones or enlarged Arabic.
class _OriginalHomePromotion extends StatelessWidget {
  const _OriginalHomePromotion({required this.language});
  final String language;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('legal-home-promotion'),
    margin: const EdgeInsets.only(top: 6),
    padding: const EdgeInsetsDirectional.only(start: 15, top: 10),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(10),
      gradient: const LinearGradient(
        colors: [Color(0xFFF8CA32), Color(0xFFE5B003)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      boxShadow: const [
        BoxShadow(
          color: Colors.black26,
          blurRadius: 8,
          spreadRadius: 2,
          offset: Offset(0, 4),
        ),
      ],
    ),
    width: double.infinity,
    child: LayoutBuilder(
      builder:
          (context, constraints) => Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8, bottom: 35),
                  child: Row(
                    children: [
                      const SizedBox(
                        height: 20,
                        width: 3,
                        child: ColoredBox(color: Colors.white),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          SamahaStrings(language).findLawyer,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Image.asset(
                'images/banner2.png',
                fit: BoxFit.contain,
                scale: 1.5,
                width: math.min(150.0, constraints.maxWidth * .35),
                excludeFromSemantics: true,
              ),
            ],
          ),
    ),
  );
}

class _HomeCatalogueHeading extends StatelessWidget {
  const _HomeCatalogueHeading({
    required this.controller,
    required this.onRefresh,
  });
  final SamahaController controller;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final s = SamahaStrings(controller.language);
    final title = Text(
      s.registeredServices,
      style: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: Colors.black87,
      ),
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SamahaLanguageButton(controller: controller),
        TextButton(
          onPressed: onRefresh,
          child: Text(
            s.t('Refresh', 'تحديث'),
            style: const TextStyle(color: AppColors.buttonColor),
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 420 ||
            MediaQuery.textScalerOf(context).scale(1) >= 1.3) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              Align(alignment: AlignmentDirectional.centerEnd, child: actions),
            ],
          );
        }
        return Row(children: [Expanded(child: title), actions]);
      },
    );
  }
}

/// Shown when the API call fails (no backend / no network).
class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.onRetry,
    this.language = 'en',
  });

  final String message;
  final String language;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              SamahaStrings(
                language,
              ).t('Unable to load services', 'تعذّر تحميل الخدمات'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(SamahaStrings(language).t('Retry', 'إعادة المحاولة')),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.buttonColor,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
