import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../services/api_client.dart';
import '../../services/app_repository.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/detailstext1.dart';

/// The signed-in user's favorite lawyers, from the legacy API or (when
/// explicitly enabled) owner-scoped Supabase favorites joined to public lawyer
/// records. A favorite whose lawyer was deleted is skipped.
class FavoriteScreen extends StatefulWidget {
  const FavoriteScreen({super.key});

  @override
  FavoriteScreenState createState() => FavoriteScreenState();
}

class FavoriteScreenState extends State<FavoriteScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideFromLeftAnimation;

  late Future<List<FavoriteEntry>> _favorites;
  bool _loaded = false;
  String? _removingId;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _slideFromLeftAnimation = Tween<Offset>(
      begin: const Offset(-1.0, 0.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));

    _controller.forward();
    _favorites = Future.value(const <FavoriteEntry>[]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _reload();
  }

  Future<void> _reload() {
    final future = SessionScope.read(context).repository.fetchMyFavorites();
    setState(() {
      _favorites = future;
    });
    return future.then((_) {}, onError: (_) {});
  }

  /// Removes one favorite, then refreshes. The card disappears only after the
  /// backend confirms, so a failed removal does not lie about the state.
  Future<void> _remove(FavoriteEntry entry) async {
    setState(() => _removingId = entry.favoriteId);
    try {
      await SessionScope.read(context).repository.removeFavorite(
            entry.favoriteId,
          );
      if (!mounted) return;
      await _reload();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _removingId = null);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(text: 'Favorite ', text1: ''),
              const SizedBox(height: 20),
              Expanded(
                child: FutureBuilder<List<FavoriteEntry>>(
                  future: _favorites,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return _Placeholder(
                        icon: Icons.error_outline,
                        title: 'Could not load your favorites',
                        detail: snapshot.error is ApiException
                            ? (snapshot.error as ApiException).message
                            : 'Please try again.',
                        onRetry: () => _reload(),
                      );
                    }
                    final favorites = snapshot.data ?? const <FavoriteEntry>[];
                    if (favorites.isEmpty) {
                      return const _Placeholder(
                        icon: Icons.favorite_border,
                        title: 'No favorites yet',
                        detail:
                            'Lawyers you save will appear here.',
                      );
                    }

                    return RefreshIndicator(
                      onRefresh: _reload,
                      child: AnimatedBuilder(
                        animation: _controller,
                        builder: (context, child) {
                          return ListView.builder(
                            itemCount: favorites.length,
                            itemBuilder: (context, index) {
                              final entry = favorites[index];
                              return SlideTransition(
                                position: _slideFromLeftAnimation,
                                child: Card(
                                  color: Colors.white,
                                  elevation: 3,
                                  child: Padding(
                                    padding: const EdgeInsets.all(10.0),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(
                                          height: 80,
                                          width: 110,
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            child: _LawyerImage(
                                              path: entry.lawyer.imagePath,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 14),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text1(
                                                text1: entry.lawyer.name.isEmpty
                                                    ? 'Lawyer'
                                                    : entry.lawyer.name,
                                              ),
                                              Text1(
                                                text1: entry.lawyer.price.isEmpty
                                                    ? 'Contact for pricing'
                                                    : entry.lawyer.price,
                                              ),
                                              Text(
                                                (entry.lawyer.specialty ?? '')
                                                        .isEmpty
                                                    ? 'Legal services'
                                                    : entry.lawyer.specialty!,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: AppColors.text2Color,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        _removingId == entry.favoriteId
                                            ? const Padding(
                                                padding:
                                                    EdgeInsets.all(8.0),
                                                child: SizedBox(
                                                  height: 18,
                                                  width: 18,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                  ),
                                                ),
                                              )
                                            : IconButton(
                                                icon: const Icon(
                                                  Icons.favorite,
                                                  color: Colors.red,
                                                ),
                                                onPressed: () =>
                                                    _remove(entry),
                                              ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
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
      ),
    );
  }
}

/// A lawyer photo from the backend, with a bundled fallback.
///
/// `Product.imagePath` holds whatever the `lawyers` document stores: a remote
/// URL for real records, or a bundled path for the older seeded data. Both are
/// handled, and a broken value falls back to the bundled portrait.
class _LawyerImage extends StatelessWidget {
  const _LawyerImage({required this.path});

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

class _Placeholder extends StatelessWidget {
  const _Placeholder({
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
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.text2Color,
              ),
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
