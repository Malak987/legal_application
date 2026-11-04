import 'package:flutter/material.dart';

import '../wallet/transactions.dart';

/// Displays the signed-in user's wallet transactions.
class TransactionScreen extends StatelessWidget {
  const TransactionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const TransactionHistoryScreen();
  }
}
