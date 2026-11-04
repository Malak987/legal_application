import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../models/product_model.dart';
import '../../services/api_client.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';
import 'writereview.dart';

/// Alias kept for existing callers (`drawer_widget.dart`) that construct `const Reviews()`.
typedef Reviews = ReviewsScreen;

/// Reviews list backed by the public Supabase review projection and owner RPCs.
class ReviewsScreen extends StatefulWidget {
  final String? lawyerId;
  final String? lawyerName;

  const ReviewsScreen({
    super.key,
    this.lawyerId,
    this.lawyerName,
  });

  @override
  State<ReviewsScreen> createState() => _ReviewsScreenState();
}

class _ReviewsScreenState extends State<ReviewsScreen> {
  List<Map<String, dynamic>> _reviews = const <Map<String, dynamic>>[];
  Map<String, String> _lawyerNames = const <String, String>{};
  bool _loading = true;
  String? _error;
  String? _deletingId;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final repo = SessionScope.read(context).repository;
    try {
      final reviews = await repo.fetchReviews(lawyerId: widget.lawyerId);
      var lawyers = const <Product>[];
      if (widget.lawyerId == null || widget.lawyerId!.isEmpty) {
        try {
          lawyers = await repo.fetchLawyers();
        } catch (_) {
          lawyers = const <Product>[];
        }
      }
      if (!mounted) return;

      final nameMap = <String, String>{};
      for (final lawyer in lawyers) {
        final id = lawyer.id?.toString() ?? '';
        final name = lawyer.name.trim();
        if (id.isNotEmpty && name.isNotEmpty) {
          nameMap[id] = name;
        }
      }

      setState(() {
        _reviews = reviews;
        _lawyerNames = nameMap;
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
        _error = 'Could not load reviews. Please try again.';
        _loading = false;
      });
    }
  }

  Future<void> _deleteReview(String reviewId) async {
    setState(() => _deletingId = reviewId);
    final repo = SessionScope.read(context).repository;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await repo.deleteReview(reviewId);
      if (!mounted) return;
      await _load();
      messenger.showSnackBar(
        const SnackBar(content: Text('Review deleted.')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _deletingId = null);
    }
  }

  String _formatDate(dynamic raw) {
    final value = raw?.toString() ?? '';
    if (value.isEmpty) return '';
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;
    final local = parsed.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = SessionScope.of(context).repository.currentUid;
    final headerTitle = (widget.lawyerName ?? '').isEmpty
        ? 'Reviews'
        : '${widget.lawyerName} Reviews';

    return Scaffold(
      backgroundColor: AppColors.bgColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CustomAppBar(text: headerTitle, text1: ''),
              const SizedBox(height: 16),
              Expanded(child: _buildBody(currentUid)),
              const SizedBox(height: 10),
              CustomButton(
                text: 'Write a Review',
                onTap: () async {
                  final created = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => WriteReviewScreen(
                        initialLawyerId: widget.lawyerId,
                        initialLawyerName: widget.lawyerName,
                      ),
                    ),
                  );
                  if (created == true && mounted) {
                    _load();
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(String? currentUid) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
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
              const Text(
                'Could not load reviews',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.text2Color,
                ),
              ),
              const SizedBox(height: 12),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_reviews.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.rate_review_outlined,
                size: 46,
                color: AppColors.text3Color,
              ),
              SizedBox(height: 12),
              Text(
                'No reviews yet',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 6),
              Text(
                'Client reviews for legal consultations will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppColors.text2Color),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildOverallRatingSection(),
            const SizedBox(height: 16),
            ..._reviews.map((r) => _buildReviewCard(r, currentUid)),
          ],
        ),
      ),
    );
  }

  Widget _buildOverallRatingSection() {
    final total = _reviews.length;
    var sum = 0.0;
    final counts = <int, int>{1: 0, 2: 0, 3: 0, 4: 0, 5: 0};

    for (final r in _reviews) {
      final rating = (r['rating'] as num?)?.toDouble() ?? 0.0;
      sum += rating;
      final bucket = rating.round().clamp(1, 5);
      counts[bucket] = (counts[bucket] ?? 0) + 1;
    }
    final avg = total > 0 ? sum / total : 0.0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                avg.toStringAsFixed(1),
                style: const TextStyle(
                  fontSize: 42,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: List.generate(5, (index) {
                      return Icon(
                        index < avg.round() ? Icons.star : Icons.star_border,
                        color: Colors.amber,
                        size: 22,
                      );
                    }),
                  ),
                  const SizedBox(height: 4),
                  Text2(
                    text2: 'Based on $total review${total == 1 ? '' : 's'}',
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          for (var stars = 5; stars >= 1; stars--)
            _buildRatingProgress(
              '$stars Stars',
              total > 0 ? (counts[stars] ?? 0) / total : 0.0,
            ),
        ],
      ),
    );
  }

  Widget _buildRatingProgress(String label, double value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(width: 65, child: Text2(text2: label)),
          Expanded(
            child: LinearProgressIndicator(
              value: value,
              backgroundColor: Colors.grey.shade300,
              color: Colors.amber,
              minHeight: 7,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReviewCard(Map<String, dynamic> review, String? currentUid) {
    final id = review['id']?.toString() ?? '';
    final userName = (review['userName']?.toString() ?? '').trim();
    final lawyerId = (review['lawyerId']?.toString() ?? '').trim();
    final lawyerName = _lawyerNames[lawyerId];
    final rating = (review['rating'] as num?)?.toDouble() ?? 5.0;
    final comment = review['comment']?.toString() ?? '';
    final date = _formatDate(review['createdAt']);
    final isMine =
        currentUid != null && review['userId']?.toString() == currentUid;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.shade200,
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: AppColors.buttonColor.withAlpha(30),
                child: Text(
                  userName.isEmpty ? 'C' : userName[0].toUpperCase(),
                  style: const TextStyle(
                    color: AppColors.buttonColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text1(
                      text1: userName.isEmpty ? 'Client' : userName,
                      size: 15,
                    ),
                    if (lawyerName != null && widget.lawyerId == null)
                      Text2(text2: 'Lawyer: $lawyerName'),
                    if (date.isNotEmpty) Text2(text2: date),
                  ],
                ),
              ),
              Row(
                children: List.generate(5, (index) {
                  return Icon(
                    index < rating.round() ? Icons.star : Icons.star_border,
                    color: Colors.amber,
                    size: 16,
                  );
                }),
              ),
              if (isMine && id.isNotEmpty)
                _deletingId == id
                    ? const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: Colors.redAccent,
                        ),
                        tooltip: 'Delete my review',
                        onPressed: () => _deleteReview(id),
                      ),
            ],
          ),
          const SizedBox(height: 10),
          Text2(text2: comment),
        ],
      ),
    );
  }
}
