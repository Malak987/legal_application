import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../services/api_client.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';

/// Subscription plans and membership backed by Supabase plan queries and
/// caller-authorized subscription RPCs.
class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  List<Map<String, dynamic>> _plans = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _mySubscriptions = const <Map<String, dynamic>>[];
  String? _selectedPlanId;
  bool _loading = true;
  bool _submitting = false;
  String? _error;
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

    final session = SessionScope.read(context);
    final repo = session.repository;

    try {
      final plans = await repo.fetchPlans();
      var subs = const <Map<String, dynamic>>[];
      if (session.isSignedIn) {
        try {
          subs = await repo.fetchMySubscriptions();
        } catch (_) {
          subs = const <Map<String, dynamic>>[];
        }
      }
      if (!mounted) return;

      final activePlans =
          plans.where((p) => p['isActive'] != false).toList();
      final displayPlans = activePlans.isNotEmpty ? activePlans : plans;

      String? initialSelected = _selectedPlanId;
      if (initialSelected == null && displayPlans.isNotEmpty) {
        initialSelected = displayPlans.first['id']?.toString();
      }

      setState(() {
        _plans = displayPlans;
        _mySubscriptions = subs;
        _selectedPlanId = initialSelected;
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
        _error = 'Could not load subscription plans. Please try again.';
        _loading = false;
      });
    }
  }

  Map<String, dynamic>? get _currentSubscription {
    for (final sub in _mySubscriptions) {
      final status = (sub['status']?.toString() ?? '').toLowerCase();
      if (status == 'active' || status == 'pending') return sub;
    }
    return _mySubscriptions.isNotEmpty ? _mySubscriptions.first : null;
  }

  static String _planTitle(Map<String, dynamic> plan) {
    final title = (plan['title'] ?? plan['name'] ?? 'Plan').toString().trim();
    return title.isEmpty ? 'Plan' : title;
  }

  static String _planPriceLabel(Map<String, dynamic> plan) {
    final rawPrice = plan['price'];
    if (rawPrice is String && rawPrice.trim().isNotEmpty) {
      return rawPrice.trim();
    }
    final numPrice = (rawPrice as num?)?.toDouble() ??
        (plan['priceValue'] as num?)?.toDouble() ??
        0.0;
    final cycle = (plan['billingCycle'] ?? 'month').toString().trim();
    return '\$${numPrice.toStringAsFixed(2)} / $cycle';
  }

  Future<void> _requestSubscription(Map<String, dynamic> plan) async {
    if (_submitting) return;
    final planId = (plan['id']?.toString() ?? '').trim();
    if (planId.isEmpty) return;

    setState(() => _submitting = true);
    final repo = SessionScope.read(context).repository;
    final messenger = ScaffoldMessenger.of(context);

    try {
      await repo.createSubscription(planId: planId);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Subscription request submitted for ${_planTitle(plan)} (Pending administrator confirmation).',
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _cancelSubscription(String subscriptionId) async {
    if (_submitting || subscriptionId.isEmpty) return;
    setState(() => _submitting = true);
    final repo = SessionScope.read(context).repository;
    final messenger = ScaffoldMessenger.of(context);

    try {
      await repo.cancelSubscription(subscriptionId);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Subscription cancelled.')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _submitting = false);
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
              const CustomAppBar(text: 'Subscriptions', text1: ''),
              const SizedBox(height: 16),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
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
                'Could not load plans',
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

    if (_plans.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.card_membership_outlined,
                size: 46,
                color: AppColors.text3Color,
              ),
              SizedBox(height: 12),
              Text(
                'No plans available yet',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 6),
              Text(
                'Subscription plans added by an administrator will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppColors.text2Color),
              ),
            ],
          ),
        ),
      );
    }

    final currentSub = _currentSubscription;
    final selectedPlan = _plans.firstWhere(
      (p) => p['id']?.toString() == _selectedPlanId,
      orElse: () => _plans.first,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (currentSub != null) ...[
          _buildCurrentSubscriptionBanner(currentSub),
          const SizedBox(height: 14),
        ],
        const Text1(text1: 'Available Legal Plans', size: 20),
        const SizedBox(height: 6),
        const Text2(
          text2:
              'Request a subscription plan below. New subscriptions start as Pending until confirmed by an administrator.',
        ),
        const SizedBox(height: 14),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView.builder(
              itemCount: _plans.length,
              itemBuilder: (context, index) => _buildPlanCard(_plans[index]),
            ),
          ),
        ),
        const SizedBox(height: 10),
        CustomButton(
          text: _submitting
              ? 'Submitting...'
              : 'Subscribe to ${_planTitle(selectedPlan)}',
          onTap: _submitting ? () {} : () => _requestSubscription(selectedPlan),
        ),
      ],
    );
  }

  Widget _buildCurrentSubscriptionBanner(Map<String, dynamic> sub) {
    final id = sub['id']?.toString() ?? '';
    final planName =
        (sub['planTitle'] ?? sub['planName'] ?? 'Subscription').toString();
    final status = (sub['status'] ?? 'Pending').toString();
    final canCancel =
        status == 'Pending' || status == 'Active';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.buttonColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.verified, color: Colors.white, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text1(
                  text1: 'My Subscription: $planName',
                  color: Colors.white,
                  size: 16,
                ),
                Text2(
                  text2: 'Status: $status',
                  color: Colors.white70,
                ),
              ],
            ),
          ),
          if (canCancel && id.isNotEmpty)
            TextButton(
              onPressed: _submitting ? null : () => _cancelSubscription(id),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlanCard(Map<String, dynamic> plan) {
    final id = plan['id']?.toString() ?? '';
    final title = _planTitle(plan);
    final priceLabel = _planPriceLabel(plan);
    final rawFeatures = plan['features'];
    final features = rawFeatures is List
        ? rawFeatures.map((f) => f.toString()).toList()
        : const <String>[];
    final isSelected = _selectedPlanId == id;

    return GestureDetector(
      onTap: () => setState(() => _selectedPlanId = id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.buttonColor.withAlpha(25)
              : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? AppColors.buttonColor : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.grey.shade200,
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Text1(text1: title, size: 20)),
                Icon(
                  isSelected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: isSelected ? AppColors.buttonColor : Colors.grey,
                  size: 24,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text1(
              text1: priceLabel,
              size: 17,
              color: AppColors.buttonColor,
            ),
            if (features.isNotEmpty) ...[
              const SizedBox(height: 10),
              ...features.map(
                (feature) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.check,
                        color: AppColors.buttonColor,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text2(text2: feature)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
