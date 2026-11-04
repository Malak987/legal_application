import 'package:flutter/material.dart';

import '../../../widgets/custom_outline_button.dart';
import '../../../widgets/customapp_bar.dart';
import '../../../widgets/custombtn.dart';
import '../../../widgets/customtextfield.dart';

class ManageAddressScreen extends StatelessWidget {
  const ManageAddressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(text: 'Manage Address', text1: ''),
              const SizedBox(height: 15,),
              Expanded(
                child: ListView(
                  children: const [
                    CustomTextField(
                      icon: Icons.person_outline,
                      label: 'Full Name',
                    ),
                    CustomTextField(
                      icon: Icons.phone,
                      label: 'Phone Number',
                    ),
                    CustomTextField(
                      icon: Icons.email,
                      label: 'Email Address',
                    ),
                    CustomTextField(
                      icon: Icons.location_on,
                      label: 'Street Address',
                    ),
                    CustomTextField(
                      icon: Icons.location_city,
                      label: 'City',
                    ),
                    CustomTextField(
                      icon: Icons.map,
                      label: 'State',
                    ),
                    CustomTextField(
                      icon: Icons.markunread_mailbox,
                      label: 'Zip Code',
                    ),
                    CustomTextField(
                      icon: Icons.location_on,
                      label: 'Country',
                    ),
                    CustomTextField(
                      icon: Icons.business,
                      label: 'Company',
                    ),
                    CustomTextField(
                      icon: Icons.account_balance_wallet,
                      label: 'Apt/Suite/Unit',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  Flexible(
                    child: CustomButton(
                      text: 'Save',
                      onTap: () {
                        // Implement save functionality
                        Navigator.pop(context); // Navigate back to previous screen
                      },
                    ),
                  ),
                  const SizedBox(
                    width: 10,
                  ),
                  Flexible(
                    child: CustomOutlinedButton(
                      text: 'Delete Address',
                      onTap: () {
                        // Implement delete functionality
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
