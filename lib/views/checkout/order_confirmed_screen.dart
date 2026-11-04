import 'package:legalserviceapp/views/checkout/trackmyorder.dart';
import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';


class OrderConfirmedScreen extends StatelessWidget {
  const OrderConfirmedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const CustomAppBar(
                text: 'Service Confirmation',
                text1: '',
              ),
              Center(
                child: Column(
                  children: [
                    const CircleAvatar(
                      radius: 55,
                      backgroundColor: AppColors.buttonColor,
                      child: Icon(Icons.check, color: Colors.white, size: 70),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text1(
                        text1: 'Appointment Confirmed!',
                        size: 28,
                      ),
                    ),
                    Text2(text2: 'Thank you for booking our legal service!'),
                    Text2(text2: 'Your attorney will arrive at the scheduled time.'),
                    Text2(text2: 'You can track your appointment status below.'),
                  ],
                ),
              ),
              CustomButton(
                text: 'Track My Service',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const TrackLegalServiceScreen(),
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
