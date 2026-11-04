import 'package:flutter/material.dart';

import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/customtextfield.dart';
import 'order_summary_screen.dart';


class ShippingAddressScreen extends StatelessWidget {
  const ShippingAddressScreen({super.key});

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
              text: 'Shipping Address',
              text1: '',
            ),
            const SizedBox(height: 20,),
           Expanded(
             child: ListView(
                children: const [
                  CustomTextField(label: 'Full Name', icon: Icons.person),
                  CustomTextField(label: 'Email', icon: Icons.email),
                  CustomTextField(label: 'Phone', icon: Icons.phone),
                  CustomTextField(label: 'Street Address', icon: Icons.location_on),
                  CustomTextField(label: 'Zip Code', icon: Icons.code),
                  CustomTextField(label: 'Country', icon: Icons.public),
                  CustomTextField(label: 'City', icon: Icons.location_city),
                  CustomTextField(label: 'State', icon: Icons.map),
                  CustomTextField(label: 'Alternate Phone', icon: Icons.phone_android),
                  CustomTextField(label: 'Address Type (Home/Work)', icon: Icons.home_work),
                ],
             
             
             ),
           ),
            const SizedBox(height: 20,),






          ],
        ),
      )
      ),
      bottomNavigationBar:Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13,vertical: 12),
        child: CustomButton(text: 'Submit', onTap:(){
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const OrderSummaryScreen(

              ),
            ),
          );
        }),
      )
      ,
    );
  }
}

