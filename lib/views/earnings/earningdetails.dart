import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../services/api_client.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';

/// Detailed earnings breakdown backed by the caller-authorized Supabase query.
class EarningDetailsScreen extends StatefulWidget {
  final Map<String, dynamic>? initialData;

  const EarningDetailsScreen({super.key, this.initialData});

  @override
  State<EarningDetailsScreen> createState() => _EarningDetailsScreenState();
}

class _EarningDetailsScreenState extends State<EarningDetailsScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    if (widget.initialData != null) {
      _data = widget.initialData;
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final repo = SessionScope.read(context).repository;
    try {
      final res = await repo.fetchMyEarnings();
      if (!mounted) return;
      setState(() {
        _data = res;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.isForbidden
            ? 'Earnings breakdown is only available for lawyer and administrator accounts.'
            : e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load earnings details. Please try again.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(text: 'Earnings Details', text1: ''),
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
                Icons.lock_outline,
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

    final data = _data ?? const <String, dynamic>{};
    final total = (data['totalEarnings'] as num?)?.toDouble() ?? 0.0;
    final pending = (data['pendingPayout'] as num?)?.toDouble() ?? 0.0;
    final rawMonthly = data['monthly'];
    final monthly = rawMonthly is Map
        ? Map<String, dynamic>.from(rawMonthly)
        : const <String, dynamic>{};
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
          Center(
            child: Column(
              children: [
                Text(
                  'Total Paid Earnings',
                  style: TextStyle(fontSize: 16, color: Colors.grey[700]),
                ),
                const SizedBox(height: 5),
                Text(
                  '\$${total.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: AppColors.buttonColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _buildInfoCard(
                  Icons.paid_outlined,
                  'Paid Total',
                  '\$${total.toStringAsFixed(2)}',
                  Colors.green,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildInfoCard(
                  Icons.schedule,
                  'Pending Payout',
                  '\$${pending.toStringAsFixed(2)}',
                  Colors.orange,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildInfoCard(
                  Icons.receipt_long,
                  'Total Entries',
                  '${history.length}',
                  Colors.blue,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildInfoCard(
                  Icons.calendar_month,
                  'Active Months',
                  '${monthly.length}',
                  Colors.purple,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text1(text1: 'Monthly Breakdown', size: 18),
          const SizedBox(height: 10),
          if (monthly.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text2(text2: 'No monthly earnings recorded yet.'),
            )
          else
            ...monthly.entries.map((entry) {
              final amt = (entry.value as num?)?.toDouble() ?? 0.0;
              return Card(
                color: Colors.white,
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: const Icon(
                    Icons.calendar_today,
                    color: AppColors.buttonColor,
                  ),
                  title: Text1(text1: entry.key, size: 16),
                  trailing: Text1(
                    text1: '\$${amt.toStringAsFixed(2)}',
                    size: 16,
                    color: Colors.green,
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildInfoCard(
    IconData icon,
    String title,
    String value,
    Color iconColor,
  ) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 2,
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            CircleAvatar(
              backgroundColor: iconColor.withAlpha((0.2 * 255).toInt()),
              radius: 24,
              child: Icon(icon, size: 26, color: iconColor),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(fontSize: 14, color: Colors.grey[700]),
            ),
          ],
        ),
      ),
    );
  }
}
