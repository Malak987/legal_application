import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../models/lawyer_availability.dart';
import '../../models/product_model.dart';
import '../../services/api_client.dart';
import '../../services/chat_realtime.dart';
import '../../state/session_scope.dart';
import '../messages/chatdetailsscreen.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';
import '../availablitycalendar/avaialblity_calendar.dart';
import '../messages/chat_screen.dart';
import '../reviews/reviews.dart';

/// Lawyer profile and service details backed by the public lawyer catalogue,
/// legacy reviews/availability routes, and the legacy or opt-in Supabase
/// favorites adapter.
class LegalServiceDetailsScreen extends StatefulWidget {
  final Product? lawyer;
  final String? lawyerId;

  const LegalServiceDetailsScreen({
    super.key,
    this.lawyer,
    this.lawyerId,
  });

  @override
  State<LegalServiceDetailsScreen> createState() =>
      _LegalServiceDetailsScreenState();
}

class _LegalServiceDetailsScreenState extends State<LegalServiceDetailsScreen> {
  Product? _lawyer;
  List<Map<String, dynamic>> _reviews = const <Map<String, dynamic>>[];
  List<LawyerAvailability> _availability = const <LawyerAvailability>[];
  String? _favoriteId;
  bool _togglingFavorite = false;
  bool _startingChat = false;
  bool _loading = true;
  String? _error;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _lawyer = widget.lawyer;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final session = SessionScope.read(context);
    final repo = session.repository;
    var targetId = (widget.lawyerId ?? widget.lawyer?.id ?? '').trim();

    try {
      Product? loaded = widget.lawyer;
      if (targetId.isNotEmpty) {
        final fetched = await repo.fetchLawyer(targetId);
        if (fetched == null) {
          if (!mounted) return;
          setState(() {
            _lawyer = null;
            _reviews = const <Map<String, dynamic>>[];
            _availability = const <LawyerAvailability>[];
            _favoriteId = null;
            _error = 'This lawyer is no longer available.';
            _loading = false;
          });
          return;
        }
        loaded = fetched;
      } else if (loaded == null) {
        final list = await repo.fetchLawyers();
        if (list.isNotEmpty) {
          loaded = list.first;
          targetId = (loaded.id ?? '').trim();
        }
      }

      var reviews = const <Map<String, dynamic>>[];
      var availability = const <LawyerAvailability>[];
      String? favId;

      if (targetId.isNotEmpty) {
        try {
          reviews = await repo.fetchReviews(lawyerId: targetId);
        } catch (_) {
          reviews = const <Map<String, dynamic>>[];
        }
        try {
          availability = await repo.fetchAvailability(targetId);
        } catch (_) {
          availability = const <LawyerAvailability>[];
        }
        if (session.isSignedIn) {
          try {
            final favs = await repo.fetchFavorites(repo.currentUid ?? '');
            for (final row in favs) {
              if (row['lawyerId']?.toString() == targetId) {
                favId = row['id']?.toString();
                break;
              }
            }
          } catch (_) {}
        }
      }

      if (!mounted) return;
      setState(() {
        _lawyer = loaded;
        _reviews = reviews;
        _availability = availability;
        _favoriteId = favId;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load lawyer details. Please try again.';
        _loading = false;
      });
    }
  }

  Future<void> _toggleFavorite() async {
    final lawyerId = (_lawyer?.id ?? widget.lawyerId ?? '').trim();
    if (lawyerId.isEmpty || _togglingFavorite) return;

    final session = SessionScope.read(context);
    if (!session.isSignedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to save favorites.')),
      );
      return;
    }

    setState(() => _togglingFavorite = true);
    final repo = session.repository;
    final messenger = ScaffoldMessenger.of(context);

    try {
      if (_favoriteId != null && _favoriteId!.isNotEmpty) {
        await repo.removeFavorite(_favoriteId!);
        if (!mounted) return;
        setState(() => _favoriteId = null);
        messenger.showSnackBar(
          const SnackBar(content: Text('Removed from favorites.')),
        );
      } else {
        var newFavId = await repo.addFavorite(lawyerId);
        if (newFavId == null) {
          // The Supabase RPC may omit the favorite ID in a compatible response;
          // resolve it through the caller-scoped favorite list instead.
          final rows = await repo.fetchFavorites(repo.currentUid ?? '');
          for (final row in rows) {
            if (row['lawyerId']?.toString() == lawyerId) {
              newFavId = row['id']?.toString();
              break;
            }
          }
        }
        if (newFavId == null || newFavId.isEmpty) {
          throw ApiException.invalidResponse(
            'The favorite was saved but its row ID was not returned.',
          );
        }
        if (!mounted) return;
        setState(() => _favoriteId = newFavId);
        messenger.showSnackBar(
          const SnackBar(content: Text('Added to favorites.')),
        );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _togglingFavorite = false);
    }
  }

  /// Opens (or reuses) the client↔lawyer conversation for this profile.
  /// The server resolves the lawyer's linked account and checks the caller's
  /// role; the client never supplies a user id.
  Future<void> _openChat() async {
    final lawyerId = (_lawyer?.id ?? widget.lawyer?.id ?? widget.lawyerId ?? '').trim();
    if (lawyerId.isEmpty || _startingChat) return;
    final session = SessionScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    if (!session.isSignedIn) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Sign in to message a lawyer.')),
      );
      return;
    }
    setState(() => _startingChat = true);
    try {
      final chat = await session.repository.startChatWithLawyer(lawyerId: lawyerId);
      final chatId = chat['id']?.toString() ?? '';
      if (chatId.isEmpty) {
        throw ApiException.invalidResponse('The conversation was not created.');
      }
      if (!mounted) return;
      final name = (_lawyer?.name ?? '').trim();
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatDetailsScreen(
            chatId: chatId,
            userName: name.isEmpty ? 'Lawyer' : name,
            realtimeEvents: ChatRealtimeScope.maybeOf(context)?.events,
            enablePolling: true,
          ),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Could not open the conversation. Please retry.')),
        );
      }
    } finally {
      if (mounted) setState(() => _startingChat = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgColor,
      body: SafeArea(
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    if (_loading && _lawyer == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _lawyer == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 46,
                color: AppColors.text3Color,
              ),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.text2Color),
              ),
              const SizedBox(height: 12),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final lawyer = _lawyer;
    if (lawyer == null) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(14.0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
          const Expanded(
            child: Center(
              child: Text(
                'No lawyer details available.',
                style: TextStyle(color: AppColors.text2Color),
              ),
            ),
          ),
        ],
      );
    }

    final name = lawyer.name.isEmpty ? 'Lawyer' : lawyer.name;
    final specialty = (lawyer.specialty ?? '').trim().isEmpty
        ? 'Legal Consultation'
        : lawyer.specialty!.trim();
    final location = (lawyer.location ?? '').trim().isEmpty
        ? 'Location not specified'
        : lawyer.location!.trim();
    final price =
        lawyer.price.trim().isEmpty ? 'Contact for pricing' : lawyer.price;
    final rating = lawyer.rating ?? 0.0;
    final experience = (lawyer.experience ?? '').trim();
    final bio = (lawyer.bio ?? '').trim();
    final isFavorited = _favoriteId != null;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              SizedBox(
                width: double.infinity,
                height: 260,
                child: _LawyerBannerImage(path: lawyer.imagePath),
              ),
              Positioned(
                top: 15,
                left: 15,
                child: CircleAvatar(
                  backgroundColor: Colors.white,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.black),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ),
              Positioned(
                top: 15,
                right: 15,
                child: CircleAvatar(
                  backgroundColor: Colors.white,
                  child: _togglingFavorite
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          icon: Icon(
                            isFavorited
                                ? Icons.favorite
                                : Icons.favorite_border,
                            color: Colors.redAccent,
                          ),
                          onPressed: _toggleFavorite,
                        ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text1(text1: name, size: 22),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.gavel, color: Colors.blue, size: 18),
                    const SizedBox(width: 6),
                    Text2(text2: specialty),
                    const Spacer(),
                    const Icon(Icons.location_on, color: Colors.red, size: 18),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        location,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.text2Color,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text1(
                      text1: price,
                      size: 20,
                      color: AppColors.buttonColor,
                    ),
                    const Spacer(),
                    const Icon(Icons.star, color: Colors.amber, size: 20),
                    const SizedBox(width: 4),
                    Text1(
                      text1: rating > 0
                          ? '${rating.toStringAsFixed(1)} (${_reviews.length} review${_reviews.length == 1 ? '' : 's'})'
                          : 'New (${_reviews.length} reviews)',
                      size: 15,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Divider(),
                const SizedBox(height: 10),
                const Text1(text1: 'About Lawyer', size: 18),
                const SizedBox(height: 6),
                Text2(
                  text2: bio.isNotEmpty
                      ? bio
                      : '$name specializes in $specialty and provides legal consultation and representation.',
                ),
                const SizedBox(height: 14),
                const Text1(text1: 'Details & Availability', size: 18),
                const SizedBox(height: 8),
                if (experience.isNotEmpty)
                  _buildDetailPoint('Experience: $experience'),
                _buildDetailPoint('Specialty: $specialty'),
                _buildDetailPoint('Location: $location'),
                _buildDetailPoint(
                  _availability.isEmpty
                      ? 'Availability: Check calendar for open dates'
                      : 'Availability: ${_availability.length} published date(s) open for booking',
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text1(text1: 'Client Reviews', size: 18),
                    TextButton(
                      onPressed: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ReviewsScreen(
                              lawyerId: lawyer.id,
                              lawyerName: name,
                            ),
                          ),
                        );
                        if (mounted) _load();
                      },
                      child: const Text('See All / Write Review'),
                    ),
                  ],
                ),
                if (_reviews.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text2(
                      text2: 'No reviews yet for this lawyer.',
                    ),
                  )
                else
                  ..._reviews.take(3).map((r) {
                    final reviewer =
                        (r['userName']?.toString() ?? 'Client').trim();
                    final rRating =
                        (r['rating'] as num?)?.toDouble() ?? 5.0;
                    final comment = (r['comment']?.toString() ?? '').trim();
                    return Card(
                      color: Colors.white,
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        title: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text1(text1: reviewer, size: 14),
                            Row(
                              children: [
                                const Icon(
                                  Icons.star,
                                  color: Colors.amber,
                                  size: 16,
                                ),
                                const SizedBox(width: 4),
                                Text(rRating.toStringAsFixed(1)),
                              ],
                            ),
                          ],
                        ),
                        subtitle: comment.isEmpty
                            ? null
                            : Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text2(text2: comment),
                              ),
                      ),
                    );
                  }),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _startingChat ? null : _openChat,
                        icon: _startingChat
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.chat_bubble_outline),
                        label: const Text('Message lawyer'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: CustomButton(
                        text: 'Book Appointment',
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  AvailabilityCalendarScheduleScreen(
                                lawyerId: lawyer.id,
                                lawyerName: name,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ChatScreen()),
                    ),
                    icon: const Icon(Icons.forum_outlined, size: 18),
                    label: const Text('View all conversations'),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailPoint(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle,
            color: AppColors.buttonColor,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text2(text2: text)),
        ],
      ),
    );
  }
}

class _LawyerBannerImage extends StatelessWidget {
  const _LawyerBannerImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final fallback = Image.asset(
      'images/lawyer2.png',
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        color: AppColors.bgColor,
        child: const Icon(Icons.person, size: 64, color: AppColors.text3Color),
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
