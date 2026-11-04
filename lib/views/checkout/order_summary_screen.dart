
import 'package:legalserviceapp/views/checkout/payment_screen.dart';
import 'package:legalserviceapp/views/checkout/shipping_screen.dart';
import 'package:flutter/material.dart';


import '../../widgets/custom_outline_button.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';

class OrderSummaryScreen extends StatelessWidget {
  const OrderSummaryScreen({super.key});

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
                text: 'Order Summary',
                text1: '',
              ),
              const SizedBox(height: 20),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.white,
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
                      const Text2(text2: 'New York ,USA'),
                      const SizedBox(height: 15),
                      const Text1(text1: 'Shipping Details', size: 18),
                      const SizedBox(height: 10),
                      const ShippingRow(text1: 'Full Name:', text2: 'Hakim Ali'),
                      const ShippingRow(text1: 'Email:', text2: 'hakamali1237@gmail.com'),
                      const ShippingRow(text1: 'Phone:', text2: '735442232'),
                      const ShippingRow(text1: 'Street Address:', text2: 'Uk 32 Street'),
                      const ShippingRow(text1: 'Zip Code:', text2: '664544'),
                      const ShippingRow(text1: 'Country:', text2: 'UK'),
                      const ShippingRow(text1: 'City:', text2: 'London'),
                      const ShippingRow(text1: 'State:', text2: 'UK'),
                      const ShippingRow(text1: 'Alternate Phone:', text2: '736554544'),
                      const ShippingRow(text1: 'Address Type:', text2: '(Home/Work)'),
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
                          Text1(text1: '\$3456'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        child: Row(
          children: [
            Flexible(
              child: CustomOutlinedButton(
                text: 'Cancel',
                onTap: () {
                  // Handle order cancellation
                },
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: CustomButton(
                text: 'Place Order',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const PaymentScreen(

                      ),
                    ),
                  );
                  // Handle order placement
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ShippingRow extends StatelessWidget {
  final String text1, text2;
  const ShippingRow({
    super.key,
    required this.text1,
    required this.text2,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text2(text2: text1),
          Text1(text1: text2),
        ],
      ),
    );
  }
}

