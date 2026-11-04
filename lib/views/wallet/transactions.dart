import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../services/api_client.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';

/// Displays wallet transactions from the owner-scoped Supabase query.
class TransactionHistoryScreen extends StatefulWidget {
  final List<Map<String, dynamic>>? transactions;

  const TransactionHistoryScreen({super.key, this.transactions});

  @override
  State<TransactionHistoryScreen> createState() =>
      _TransactionHistoryScreenState();
}

class _TransactionHistoryScreenState extends State<TransactionHistoryScreen> {
  List<Map<String, dynamic>> _transactions = const <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    if (widget.transactions != null) {
      _transactions = widget.transactions!;
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
      final wallet = await repo.fetchMyWallet();
      if (!mounted) return;
      final raw = wallet['transactions'];
      final list = raw is List
          ? raw
              .whereType<Map>()
              .map((t) => Map<String, dynamic>.from(t))
              .toList()
          : const <Map<String, dynamic>>[];
      setState(() {
        _transactions = list;
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
        _error = 'Could not load transactions. Please try again.';
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
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(text: 'All Transactions', text1: ''),
              const SizedBox(height: 20),
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
      );
    }
    if (_transactions.isEmpty) {
      return const Center(
        child: Text(
          'No wallet transactions yet.',
          style: TextStyle(color: AppColors.text2Color),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: _transactions.length,
        itemBuilder: (context, index) {
          final tx = _transactions[index];
          final type = (tx['type']?.toString() ?? '').toLowerCase();
          final isCredit = type == 'credit';
          final amountNum = (tx['amount'] as num?)?.toDouble() ?? 0.0;
          final formattedAmount = tx['amount'] is String
              ? tx['amount'].toString()
              : '${isCredit ? '+' : '-'}\$${amountNum.toStringAsFixed(2)}';
          final title = (tx['description']?.toString() ??
                  tx['title']?.toString() ??
                  '')
              .trim();
          final date = _formatDate(tx['createdAt'] ?? tx['date']);

          return Card(
            color: Colors.white,
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 2,
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: isCredit
                    ? Colors.green.withAlpha(45)
                    : Colors.red.withAlpha(45),
                child: Icon(
                  isCredit ? Icons.arrow_downward : Icons.arrow_upward,
                  color: isCredit ? Colors.green : Colors.red,
                ),
              ),
              title: Text1(
                text1: title.isEmpty
                    ? (isCredit ? 'Wallet Credit' : 'Wallet Debit')
                    : title,
                size: 16,
              ),
              subtitle: date.isEmpty ? null : Text2(text2: date),
              trailing: Text1(
                text1: formattedAmount,
                size: 16,
                color: isCredit ? Colors.green : Colors.red,
              ),
            ),
          );
        },
      ),
    );
  }
}
