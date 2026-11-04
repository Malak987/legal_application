import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';

class TopUpWalletSuccessfully extends StatelessWidget {
  const TopUpWalletSuccessfully({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(text: 'TopUpWalletSuccessfully', text1: ''),
              const SizedBox(height: 200),
              const Center(
                child: Column(
                  children: [
                    Center(
                      child: CircleAvatar(
                        radius: 40,
                        backgroundColor: AppColors.buttonColor,
                        child: Icon(
                          Icons.check,
                          color: Colors.white,
                          size: 60,
                        ),
                      ),
                    ),
                    SizedBox(height: 10),
                    Text1(text1: 'Top Up Successfully', size: 24),
                    SizedBox(height: 5),
                    Text2(text2: 'You have successfully Top-Up'),
                    Text2(text2: 'E_Wallet for \$500.00 '),
                  ],
                ),
              ),
              const Spacer(),
              CustomButton(
                text: 'Ok',
                onTap: () {

                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
