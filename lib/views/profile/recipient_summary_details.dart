import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';
import '../checkout/payment_screen.dart';
import '../checkout/shipping_screen.dart';


class RecipientSummaryDetailsScreen extends StatelessWidget {
  const RecipientSummaryDetailsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(
                text: 'Recipient Summary',
                text1: '',
              ),
              const SizedBox(height: 20),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
                  decoration: BoxDecoration(
                    color: AppColors.tabColor,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: Color.fromARGB((0.2 * 255).toInt(), 128, 128, 128),
                        spreadRadius: 2,
                        blurRadius: 5,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: ListView(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text1(text1: 'Deliver to:', size: 16),
                          GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => const ShippingAddressScreen(),
                                ),
                              );
                            },
                            child: const Icon(Icons.edit, color: Colors.white, size: 20),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text1(text1: 'James Powell'),
                      const SizedBox(height: 5),
                      const Text2(text2: 'UK 32 Street, London, UK'),
                      const SizedBox(height: 10),
                      const ShippingRow(text1: 'Recipient Name:', text2: 'James Powell'),
                      const ShippingRow(text1: 'Phone Number:', text2: '86345454533'),
                      const ShippingRow(text1: 'Email Address:', text2: 'James@gmail.com'),
                      const ShippingRow(text1: 'Street Address:', text2: 'UK 32 Street'),
                      const ShippingRow(text1: 'City:', text2: 'London'),
                      const ShippingRow(text1: 'State:', text2: 'London'),
                      const ShippingRow(text1: 'Zip Code:', text2: '123456'),
                      const ShippingRow(text1: 'Country:', text2: 'UK'),
                      const ShippingRow(text1: 'Delivery Date:', text2: '10th July 2024'),
                      const ShippingRow(text1: 'Delivery Time Window:', text2: '2 PM - 4 PM'),
                      const ShippingRow(text1: 'Delivery Instructions:', text2: 'Leave at the front door.'),
                      const ShippingRow(text1: 'Gift Card:', text2: 'Happy Birthday'),
                      const ShippingRow(text1: 'Gift Message:', text2: 'Wishing you all the best!'),
                      const ShippingRow(text1: 'Company:', text2: 'Tech Solutions'),
                      const ShippingRow(text1: 'Apt/Suite/Unit:', text2: 'Apt 101'),
                      const SizedBox(height: 14),
                      const Text1(text1: 'Price Details', size: 18),
                      const SizedBox(height: 6),
                      const ShippingRow(text1: 'MRP (4 Items):', text2: '\$2232'),
                      const ShippingRow(text1: 'Discount:', text2: '\$232'),
                      const ShippingRow(text1: 'Taxes & Charges:', text2: '\$44'),
                      const ShippingRow(text1: 'Delivery Charges:', text2: 'Free'),
                      const SizedBox(height: 6),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text1(text1: 'Total Price:', size: 18),
                          Text1(text1: '\$3456', size: 18),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              CustomButton(
                text: 'Proceed to Payment',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const PaymentScreen(),
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

class ShippingRow extends StatelessWidget {
  final String text1;
  final String text2;

  const ShippingRow({super.key, required this.text1, required this.text2});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text1(text1: text1, size: 14),
          Text2(text2: text2,),
        ],
      ),
    );
  }
}
