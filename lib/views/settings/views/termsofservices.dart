import 'package:flutter/material.dart';
import '../../../widgets/custom_outline_button.dart';
import '../../../widgets/customapp_bar.dart';
import '../../../widgets/custombtn.dart';
import '../../../widgets/detailstext1.dart';
import '../../../widgets/detailstext2.dart';



class TermsOfServices extends StatefulWidget {
  const TermsOfServices({super.key});

  @override
  State<TermsOfServices> createState() => _TermsOfServicesState();
}

class _TermsOfServicesState extends State<TermsOfServices> {
  bool isChecked = false;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        body: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 13,vertical: 14),
                child: CustomAppBar(text1: '',text: 'Terms Of Services'),
              ),
              SizedBox(height: 20,),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text1(text1: 'Terms of Service'),
                    SizedBox(
                      height: 8,
                    ),
                    Text2(text2: 'These Terms of Service ("Terms") govern your use of HRMS mobile application (the "App") provided by. By accessing or using the App, you agree to be bound by these Terms. If you disagree with any part of the Terms, you may not access the App.'),
                    SizedBox(
                      height: 8,
                    ),
                    Text1(text1: 'Use of the App'),

                    SizedBox(
                      height: 8,
                    ),
                    Text2(text2: 'You must be at least 13 years old to use the App. If you are under 13, you may not use the App.You agree to use the App only for lawful purposes and in compliance with these Terms.You may not modify, adapt, or hack the App or modify another app to falsely imply that it is associated with the App.'),
                    SizedBox(
                      height: 8,
                    ),
                    Text1(text1: 'Intellectual Property'),

                    SizedBox(
                      height: 8,
                    ),
                    Text2(text2: 'The App and its original content, features, and functionality are owned by HRMS and are protected by international copyright, trademark, patent, trade secret, and other intellectual property or proprietary rights laws.You may not reproduce, distribute, modify, create derivative works of, publicly display, publicly perform, republish, download, store, or transmit any of the material on our App without our prior written consent.'),
                    SizedBox(
                      height: 8,
                    ),
                    Text1(text1: 'Privacy'),

                    SizedBox(
                      height: 8,
                    ),
                    Text2(text2: 'Your use of the App is also governed by our Privacy Policy. By using the App, you consent to the collection and use of information as described in our Privacy Policy'),
                    SizedBox(
                      height: 8,
                    ),
                    Text1(text1: 'Disclaimer'),

                    SizedBox(
                      height: 8,
                    ),
                    Text2(text2: 'The App is provided "as is" and "as available" without warranties of any kind, either express or implied.Virute does not warrant that the App will be uninterrupted or error-free, thatdefects will be corrected, or that the App is free of viruses or other harmful components'),
                    SizedBox(
                      height: 8,
                    ),
                    Text1(text1: 'Governing Law'),

                    SizedBox(
                      height: 8,
                    ),
                    Text2(text2: 'These Terms shall be governed by and construed in accordance with the laws of Virtue, without regard to its conflict of law provisions.'),
                    SizedBox(
                      height: 8,
                    ),
                    Text1(text1: 'Changes to Terms'),

                    SizedBox(
                      height: 8,
                    ),
                    Text2(text2: 'We reserve the right, at our sole discretion, to modify or replace these Terms at any time. If a revision is material, we will provide at least 30 days notice prior to any new terms taking effect. What constitutes a material change will be determined at our sole discretion.'),
                    SizedBox(
                      height: 8,
                    ),
                    Text1(text1: 'Contact Us'),

                    SizedBox(
                      height: 8,
                    ),
                    Text2(text2: 'If you have any questions about these Terms, please contact us at hakamali1237@gmail.com'),


                   

                  ],
                ),
              )
            ],
          ),
        ),
        bottomNavigationBar: Padding(padding: const EdgeInsets.symmetric(
          horizontal: 12,vertical: 15

        ),
          child: Row(
            children: [
              Flexible(child: CustomOutlinedButton(text: 'Decline',onTap: (){},)),
              const SizedBox(width: 10,),

              Flexible(child: CustomButton(text: 'Accept',onTap: (){},)),


            ],


          ),

        ),
      ),


    );

  }
}
