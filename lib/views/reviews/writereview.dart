import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../models/product_model.dart';
import '../../services/api_client.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';

/// Submits a review through the authenticated Supabase review RPC.
class WriteReviewScreen extends StatefulWidget {
  final String? initialLawyerId;
  final String? initialLawyerName;

  const WriteReviewScreen({
    super.key,
    this.initialLawyerId,
    this.initialLawyerName,
  });

  @override
  State<WriteReviewScreen> createState() => _WriteReviewScreenState();
}

class _WriteReviewScreenState extends State<WriteReviewScreen> {
  final TextEditingController _reviewController = TextEditingController();
  double _selectedRating = 5.0;
  String? _selectedLawyerId;
  String? _selectedLawyerName;
  List<Product> _lawyers = const <Product>[];
  bool _loadingLawyers = false;
  bool _submitting = false;
  String? _error;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _selectedLawyerId = widget.initialLawyerId;
    _selectedLawyerName = widget.initialLawyerName;
    if (_selectedLawyerId == null || _selectedLawyerId!.isEmpty) {
      _loadLawyers();
    }
  }

  @override
  void dispose() {
    _reviewController.dispose();
    super.dispose();
  }

  Future<void> _loadLawyers() async {
    setState(() {
      _loadingLawyers = true;
      _error = null;
    });
    final repo = SessionScope.read(context).repository;
    try {
      final list = await repo.fetchLawyers();
      if (!mounted) return;
      final valid = list.where((l) => (l.id ?? '').isNotEmpty).toList();
      setState(() {
        _lawyers = valid;
        if (_selectedLawyerId == null && valid.isNotEmpty) {
          _selectedLawyerId = valid.first.id;
          _selectedLawyerName = valid.first.name;
        }
        _loadingLawyers = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loadingLawyers = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load lawyers. Please try again.';
        _loadingLawyers = false;
      });
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final lawyerId = (_selectedLawyerId ?? '').trim();
    final comment = _reviewController.text.trim();

    if (lawyerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a lawyer to review.')),
      );
      return;
    }
    if (comment.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please write a review comment.')),
      );
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final repo = SessionScope.read(context).repository;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      await repo.addReview(
        lawyerId: lawyerId,
        rating: _selectedRating,
        comment: comment,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Review submitted successfully.')),
      );
      navigator.pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _submitting = false;
      });
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not submit review. Please try again.';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(text: 'Write a Review', text1: ''),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  children: [
                    _buildLawyerSelector(),
                    const SizedBox(height: 20),
                    _buildRatingSection(),
                    const SizedBox(height: 20),
                    _buildReviewInput(),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Colors.red.shade800,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              CustomButton(
                text: _submitting ? 'Submitting...' : 'Submit Review',
                onTap: _submitting ? () {} : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLawyerSelector() {
    if (widget.initialLawyerId != null && widget.initialLawyerId!.isNotEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.gavel, color: AppColors.buttonColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text1(
                text1: (_selectedLawyerName ?? '').isEmpty
                    ? 'Selected Lawyer'
                    : _selectedLawyerName!,
                size: 16,
              ),
            ),
          ],
        ),
      );
    }

    if (_loadingLawyers) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_lawyers.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'No lawyers available to review yet.',
                style: TextStyle(color: AppColors.text2Color),
              ),
            ),
            TextButton(onPressed: _loadLawyers, child: const Text('Retry')),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButtonFormField<String>(
        initialValue: _selectedLawyerId,
        decoration: const InputDecoration(
          labelText: 'Select Lawyer',
          border: InputBorder.none,
        ),
        items: _lawyers
            .map(
              (lawyer) => DropdownMenuItem<String>(
                value: lawyer.id,
                child: Text(
                  lawyer.name.isEmpty ? 'Lawyer' : lawyer.name,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
            .toList(),
        onChanged: (value) {
          setState(() {
            _selectedLawyerId = value;
            final match = _lawyers.where((l) => l.id == value);
            _selectedLawyerName =
                match.isNotEmpty ? match.first.name : _selectedLawyerName;
          });
        },
      ),
    );
  }

  Widget _buildRatingSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text1(text1: 'Your Overall Rating', size: 18),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: List.generate(5, (index) {
                final starValue = index + 1.0;
                return IconButton(
                  onPressed: () {
                    setState(() => _selectedRating = starValue);
                  },
                  icon: Icon(
                    index < _selectedRating ? Icons.star : Icons.star_border,
                    color: Colors.amber,
                    size: 32,
                  ),
                );
              }),
            ),
            Text1(
              text1: _selectedRating.toStringAsFixed(1),
              size: 22,
              color: Colors.black87,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildReviewInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text1(text1: 'Add Detailed Review', size: 18),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
          child: TextField(
            controller: _reviewController,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: 'Share your experience with this legal consultation...',
              border: InputBorder.none,
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text2(
          text2:
              'Note: Reviews can be submitted for lawyers with a confirmed or completed booking.',
        ),
      ],
    );
  }
}
