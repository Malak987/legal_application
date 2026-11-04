import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../services/api_client.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';
import 'toppup.dart';
import 'transactions.dart';

/// User wallet balance and transaction history backed by owner-scoped Supabase queries.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  double _balance = 0.0;
  List<Map<String, dynamic>> _transactions = const <Map<String, dynamic>>[];
  bool _loading = true;
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

    final repo = SessionScope.read(context).repository;
    try {
      final wallet = await repo.fetchMyWallet();
      if (!mounted) return;
      final balance = (wallet['balance'] as num?)?.toDouble() ?? 0.0;
      final raw = wallet['transactions'];
      final list = raw is List
          ? raw
              .whereType<Map>()
              .map((t) => Map<String, dynamic>.from(t))
              .toList()
          : const <Map<String, dynamic>>[];

      setState(() {
        _balance = balance;
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
        _error = 'Could not load wallet. Please try again.';
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
              const CustomAppBar(text: 'Wallet', text1: ''),
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
              const Icon(
                Icons.error_outline,
                size: 46,
                color: AppColors.text3Color,
              ),
              const SizedBox(height: 12),
              const Text(
                'Could not load wallet',
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

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          _buildBalanceCard(),
          const SizedBox(height: 15),
          _buildQuickActions(),
          const SizedBox(height: 20),
          _buildTransactionHistory(),
        ],
      ),
    );
  }

  Widget _buildBalanceCard() {
    return Container(
      padding: const EdgeInsets.all(14),
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
          const Text2(text2: 'Current Balance', color: Colors.white70),
          const SizedBox(height: 6),
          Text1(
            text1: '\$${_balance.toStringAsFixed(2)}',
            size: 32,
            color: Colors.white,
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
            onPressed: () async {
              final changed = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => const TopUpScreen(),
                ),
              );
              if (changed == true && mounted) {
                _load();
              }
            },
            icon: const Icon(Icons.account_balance_wallet_outlined, size: 22),
            label: const Text1(text1: 'New Transaction', size: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _buildActionTile(Icons.add_circle_outline, 'Top Up', () async {
          final changed = await Navigator.push<bool>(
            context,
            MaterialPageRoute(
              builder: (_) => const TopUpScreen(),
            ),
          );
          if (changed == true && mounted) {
            _load();
          }
        }),
        _buildActionTile(Icons.history, 'Transactions', () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  TransactionHistoryScreen(transactions: _transactions),
            ),
          );
        }),
        _buildActionTile(Icons.refresh, 'Refresh', _load),
      ],
    );
  }

  Widget _buildActionTile(IconData icon, String title, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: Colors.white,
            child: Icon(icon, color: AppColors.buttonColor, size: 28),
          ),
          const SizedBox(height: 6),
          Text2(text2: title),
        ],
      ),
    );
  }

  Widget _buildTransactionHistory() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text1(text1: 'Recent Transactions', size: 18),
        const SizedBox(height: 10),
        if (_transactions.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: Text2(text2: 'No transactions recorded yet.'),
            ),
          )
        else
          ..._transactions.map(_buildTransactionItem),
      ],
    );
  }

  Widget _buildTransactionItem(Map<String, dynamic> tx) {
    final type = (tx['type']?.toString() ?? '').toLowerCase();
    final isCredit = type == 'credit';
    final amountNum = (tx['amount'] as num?)?.toDouble() ?? 0.0;
    final formattedAmount =
        '${isCredit ? '+' : '-'}\$${amountNum.toStringAsFixed(2)}';
    final title = (tx['description']?.toString() ?? '').trim();
    final date = _formatDate(tx['createdAt']);

    return Card(
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
  }
}
