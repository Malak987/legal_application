import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../services/api_client.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/customtextfield.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';

/// Submits a wallet transaction through the authenticated Supabase wallet RPC.
///
/// Does not fake a client-side balance update: the server enforces that wallet
/// credits require administrator authorization (`403 Only admins can credit
/// wallets`), whereas debits are allowed for the wallet owner when sufficient
/// balance exists. Any server rejection is surfaced directly to the user.
class TopUpScreen extends StatefulWidget {
  final Function(double)? onTopUp;

  const TopUpScreen({super.key, this.onTopUp});

  @override
  State<TopUpScreen> createState() => _TopUpScreenState();
}

class _TopUpScreenState extends State<TopUpScreen> {
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  String _transactionType = 'credit';
  bool _submitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _amountController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submitTransaction() async {
    if (_submitting) return;
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid amount greater than 0.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    final repo = SessionScope.read(context).repository;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final desc = _descriptionController.text.trim().isEmpty
        ? (_transactionType == 'credit' ? 'Wallet Top-Up' : 'Wallet Payment')
        : _descriptionController.text.trim();

    try {
      await repo.addMyWalletTransaction(
        type: _transactionType,
        amount: amount,
        description: desc,
      );
      if (!mounted) return;
      widget.onTopUp?.call(amount);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _transactionType == 'credit'
                ? 'Successfully credited \$${amount.toStringAsFixed(2)}.'
                : 'Successfully debited \$${amount.toStringAsFixed(2)}.',
          ),
          backgroundColor: Colors.green,
        ),
      );
      navigator.pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
        _submitting = false;
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: Colors.red,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Transaction could not be completed. Please try again.';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final role = SessionScope.of(context).profile?.role ?? 'client';

    return Scaffold(
      backgroundColor: AppColors.bgColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(text: 'Wallet Transaction', text1: ''),
              const SizedBox(height: 20),
              const Text1(text1: 'Transaction Type', size: 16),
              const SizedBox(height: 8),
              Row(
                children: [
                  ChoiceChip(
                    label: const Text('Top Up (Credit)'),
                    selected: _transactionType == 'credit',
                    onSelected: (selected) {
                      if (selected) {
                        setState(() {
                          _transactionType = 'credit';
                          _errorMessage = null;
                        });
                      }
                    },
                  ),
                  const SizedBox(width: 10),
                  ChoiceChip(
                    label: const Text('Pay / Withdraw (Debit)'),
                    selected: _transactionType == 'debit',
                    onSelected: (selected) {
                      if (selected) {
                        setState(() {
                          _transactionType = 'debit';
                          _errorMessage = null;
                        });
                      }
                    },
                  ),
                ],
              ),
              if (_transactionType == 'credit' && role != 'admin') ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.amber.shade300),
                  ),
                  child: const Text2(
                    text2:
                        'Note: Direct wallet credits require administrator verification on the server.',
                  ),
                ),
              ],
              const SizedBox(height: 16),
              const Text1(text1: 'Enter Amount', size: 18),
              const SizedBox(height: 10),
              CustomTextField(
                controller: _amountController,
                label: 'Enter amount (e.g. 100)',
                icon: Icons.attach_money,
              ),
              const SizedBox(height: 12),
              CustomTextField(
                controller: _descriptionController,
                label: 'Description (optional)',
                icon: Icons.description_outlined,
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: TextStyle(color: Colors.red.shade800, fontSize: 13),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              CustomButton(
                text: _submitting ? 'Processing...' : 'Submit Transaction',
                onTap: _submitting ? () {} : _submitTransaction,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
