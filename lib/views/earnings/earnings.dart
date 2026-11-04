import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../services/api_client.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';
import 'earningdetails.dart';

/// Lawyer and administrator earnings summary backed by the Supabase earnings query.
class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key});

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  Map<String, dynamic>? _earningsData;
  bool _loading = true;
  String? _error;
  bool _isForbidden = false;
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
      _isForbidden = false;
    });

    final repo = SessionScope.read(context).repository;
    try {
      final data = await repo.fetchMyEarnings();
      if (!mounted) return;
      setState(() {
        _earningsData = data;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _isForbidden = e.isForbidden;
        _error = e.isForbidden
            ? 'Earnings are only available for lawyer and administrator accounts.'
            : e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load earnings. Please try again.';
        _loading = false;
      });
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
    return Scaffold(
      backgroundColor: AppColors.bgColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(text: 'Earnings', text1: ''),
              const SizedBox(height: 15),
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
              Icon(
                _isForbidden ? Icons.lock_outline : Icons.error_outline,
                size: 46,
                color: AppColors.text3Color,
              ),
              const SizedBox(height: 12),
              Text(
                _isForbidden ? 'Lawyer Account Required' : 'Could not load earnings',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
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
              if (!_isForbidden) ...[
                const SizedBox(height: 12),
                TextButton(onPressed: _load, child: const Text('Retry')),
              ],
            ],
          ),
        ),
      );
    }

    final data = _earningsData ?? const <String, dynamic>{};
    final total = (data['totalEarnings'] as num?)?.toDouble() ?? 0.0;
    final pending = (data['pendingPayout'] as num?)?.toDouble() ?? 0.0;
    final rawHistory = data['history'];
    final history = rawHistory is List
        ? rawHistory
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : const <Map<String, dynamic>>[];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          _buildTotalEarningsCard(total, pending),
          const SizedBox(height: 15),
          _buildQuickMetrics(total, pending, history.length),
          const SizedBox(height: 20),
          _buildEarningsHistory(history),
        ],
      ),
    );
  }

  Widget _buildTotalEarningsCard(double total, double pending) {
    return Container(
      padding: const EdgeInsets.all(20),
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.buttonColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.buttonColor.withAlpha((0.3 * 255).toInt()),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text2(text2: 'Total Paid Earnings', color: Colors.white70),
          const SizedBox(height: 6),
          Text1(
            text1: '\$${total.toStringAsFixed(2)}',
            size: 32,
            color: Colors.white,
          ),
          const SizedBox(height: 4),
          Text2(
            text2: 'Pending Payout: \$${pending.toStringAsFixed(2)}',
            color: Colors.white70,
          ),
          const SizedBox(height: 15),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: AppColors.buttonColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      EarningDetailsScreen(initialData: _earningsData),
                ),
              );
            },
            icon: const Icon(Icons.analytics_outlined, size: 22),
            label: const Text1(text1: 'View Breakdown', size: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickMetrics(double total, double pending, int count) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildMetricCard('Paid', '\$${total.toStringAsFixed(2)}', Icons.paid),
        _buildMetricCard(
          'Pending',
          '\$${pending.toStringAsFixed(2)}',
          Icons.schedule,
        ),
        _buildMetricCard('Records', '$count', Icons.receipt_long),
      ],
    );
  }

  Widget _buildMetricCard(String title, String amount, IconData icon) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.grey.shade200,
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AppColors.buttonColor, size: 24),
            const SizedBox(height: 8),
            Text2(text2: title, color: Colors.black54),
            const SizedBox(height: 4),
            Text1(text1: amount, size: 15),
          ],
        ),
      ),
    );
  }

  Widget _buildEarningsHistory(List<Map<String, dynamic>> history) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text1(text1: 'Earnings History', size: 18),
        const SizedBox(height: 10),
        if (history.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: Text2(text2: 'No earnings records yet.'),
            ),
          )
        else
          ...history.map(_buildHistoryItem),
      ],
    );
  }

  Widget _buildHistoryItem(Map<String, dynamic> item) {
    final amount = (item['amount'] as num?)?.toDouble() ?? 0.0;
    final status = (item['status']?.toString() ?? 'pending').toLowerCase();
    final isPaid = status == 'paid';
    final description = (item['description']?.toString() ?? '').trim();
    final date = _formatDate(item['createdAt']);

    return Card(
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isPaid
              ? Colors.green.withAlpha(45)
              : Colors.orange.withAlpha(45),
          child: Icon(
            isPaid ? Icons.check_circle_outline : Icons.schedule,
            color: isPaid ? Colors.green : Colors.orange,
          ),
        ),
        title: Text1(
          text1: description.isEmpty ? 'Consultation Payout' : description,
          size: 16,
        ),
        subtitle: Text2(
          text2: date.isEmpty
              ? 'Status: ${status.toUpperCase()}'
              : '$date • ${status.toUpperCase()}',
        ),
        trailing: Text1(
          text1: '\$${amount.toStringAsFixed(2)}',
          size: 16,
          color: isPaid ? Colors.green : Colors.orange,
        ),
      ),
    );
  }
}
