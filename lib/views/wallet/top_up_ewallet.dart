import 'package:legalserviceapp/views/wallet/top_upwallet_successfully.dart';
import 'package:flutter/material.dart';
import '../../constants/colors.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';

class TopUpEWallet extends StatefulWidget {
  const TopUpEWallet({super.key});

  @override
  TopUpEWalletState createState() => TopUpEWalletState();
}

class TopUpEWalletState extends State<TopUpEWallet> {
  int _selectedPaymentIndex = -1; // Initialize with no selection

  void _selectPayment(int index) {
    setState(() {
      _selectedPaymentIndex = index;
    });
  }

  Widget _buildPaymentOption({
    required int index,
    required String imagePath,
    required String title,
    double imageWidth = 30,
  }) {
    return GestureDetector(
      onTap: () {
        _selectPayment(index);
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.text3Color),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Image.asset(
                imagePath,
                width: imageWidth,
              ),
            ),
            const SizedBox(
              width: 10,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text2(text2: title),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: CircleAvatar(
                radius: 11,
                backgroundColor: _selectedPaymentIndex == index
                    ? AppColors.buttonColor // Selected color
                    : Colors.transparent, // Transparent if not selected
                child: CircleAvatar(
                  radius: 9,
                  backgroundColor: Colors.white,
                  child: CircleAvatar(
                    radius: 6,
                    backgroundColor: _selectedPaymentIndex == index
                        ? AppColors.buttonColor // Selected color
                        : Colors.transparent, // Transparent if not selected
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(text: 'TopUpEWallet', text1: ''),
              const SizedBox(
                height: 30,
              ),
              const Text1(
                text1: 'Credit & Debit Cards',
                size: 21,
              ),
              const SizedBox(
                height: 10,
              ),
              _buildPaymentOption(
                index: 0,
                imagePath: 'images/card.png',
                title: 'Add New Card',
              ),
              const SizedBox(
                height: 6,
              ),
              const Text1(
                text1: 'More payment Options',
                size: 20,
              ),
              const SizedBox(
                height: 4,
              ),
              _buildPaymentOption(
                index: 1,
                imagePath: 'images/card.png',
                title: 'Master Card',
              ),
              _buildPaymentOption(
                index: 2,
                imagePath: 'images/icons8-apple-logo-50.png',
                title: 'Apple Pay',
                imageWidth: 24,
              ),
              _buildPaymentOption(
                index: 3,
                imagePath: 'images/icons8-google-48.png',
                title: 'Google Pay',
                imageWidth: 24,
              ),
              _buildPaymentOption(
                index: 4,
                imagePath: 'images/icons8-paypal-48.png',
                title: 'PayPal',
                imageWidth: 30,
              ),
              const SizedBox(
                height: 10,
              ),
              const Spacer(),
              CustomButton(
                text: 'Next',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const TopUpWalletSuccessfully(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
