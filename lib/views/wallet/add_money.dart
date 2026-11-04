import 'package:legalserviceapp/views/wallet/top_up_ewallet.dart';
import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';



class AddMoneyScreen extends StatelessWidget {
  const AddMoneyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          children: [
            const CustomAppBar(text: 'Add Money', text1: ''),
            const SizedBox(
              height: 20,
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
              decoration: BoxDecoration(
                  color: Colors.red.shade100,
                  borderRadius: BorderRadius.circular(8)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text2(text2: 'Wallet Balance'),
                          Text1(
                            text1: '\$12000.00',
                            size: 17,
                          )
                        ],
                      ),
                      Spacer(),
                      Icon(
                        Icons.wallet,
                        color: AppColors.buttonColor,
                        size: 30,
                      )
                    ],
                  ),
                  const SizedBox(
                    height: 8,
                  ),
                  const SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        Wallettab(
                          text: '\$9000',
                        ),
                        SizedBox(width: 7,),
                        Wallettab(
                          text: '\$10000',
                        ),
                        SizedBox(width: 7,),

                        Wallettab(
                          text: '\$11000',
                        ),
                        SizedBox(width: 7,),

                        Wallettab(
                          text: '\$12000',
                        ), SizedBox(width: 7,),

                        Wallettab(
                          text: '\$13000',
                        ),
                      ],
                    ),
                  ),
                  const SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        Wallettab(
                          text: '\$2000',
                        ),
                        SizedBox(width: 7,),
                        Wallettab(
                          text: '\$3000',
                        ),
                        SizedBox(width: 7,),

                        Wallettab(
                          text: '\$4000',
                        ),
                        SizedBox(width: 7,),

                        Wallettab(
                          text: '\$5000',
                        ), SizedBox(width: 7,),

                        Wallettab(
                          text: '\$6000',
                        ),
                      ],
                    ),
                  ),
                  TextFormField(
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 1, horizontal: 10),
                      hintText: 'Enter Amount',
                      prefixIcon: const Icon(
                        Icons.money_off,
                        color: AppColors.buttonColor,
                        size: 30,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Colors.white),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: AppColors
                                .buttonColor), // Red border when focused
                      ),
                      hintStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                      ),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10,),
                  CustomButton(text: 'Add Money', onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(builder: (context) => const TopUpEWallet())); // Navigate to SaveCard screen

                  })
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class Wallettab extends StatelessWidget {
   final String text;
  const Wallettab({
    super.key, required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      width: 79,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 5),
      height: 40,
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8)),
      child: Center(
        child: Text1(
          text1: text,
        ),
      ),
    );
  }
}
