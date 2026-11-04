import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/detailstext1.dart';
import 'order_confirmed_screen.dart';

class OrderConfirmationScreen extends StatelessWidget {
  const OrderConfirmationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CustomAppBar(text: 'Service Confirmation', text1: ''),
                const SizedBox(height: 20),
                _buildServiceDetails(),
                const SizedBox(height: 20),
                CustomButton(
                  text: 'Track My Service',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const OrderConfirmedScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildServiceDetails() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Color.fromARGB((0.2 * 255).toInt(), 158, 158, 158),
            spreadRadius: 2,
            blurRadius: 5,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text1(
            text1: 'Service ID: #CGR123456',
            size: 18,
          ),
          const SizedBox(height: 12),
          const Text1(
            text1: 'Attorney Name:',
            size: 16,
          ),
          const SizedBox(height: 8),
          const Text(
            'John Doe (Certified Lawyer)',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 16),
          const Text1(
            text1: 'Appointment Date & Time:',
            size: 16,
          ),
          const SizedBox(height: 8),
          const Text(
            'Tuesday, March 25, 2025 - 10:00 AM',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 16),
          const Text1(
            text1: 'Service Type:',
            size: 16,
          ),
          const SizedBox(height: 8),
          const Text(
            'Legal Consultation',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 16),
          const Text1(
            text1: 'Payment Method:',
            size: 16,
          ),
          const SizedBox(height: 8),
          const Text1(
            text1: 'Paid via Credit Card (Visa)',
            size: 16,
            color: AppColors.text3Color,
          ),
          const SizedBox(height: 16),
          const Text1(
            text1: 'Service Cost Breakdown:',
            size: 16,
          ),
          const SizedBox(height: 8),
          _buildSummaryItem('Service Fee', '\$200'),
          _buildSummaryItem('Additional Charges', '\$25'),
          const Divider(),
          _buildSummaryItem('Total', '\$225', isTotal: true),
        ],
      ),
    );
  }

  Widget _buildSummaryItem(String title, String value, {bool isTotal = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text1(text1: title),
          Text1(
            text1: value,
            size: isTotal ? 18 : 16,
            color: isTotal ? Colors.black : Colors.grey,
          ),
        ],
      ),
    );
  }
}
