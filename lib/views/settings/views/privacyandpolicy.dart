import 'package:flutter/material.dart';

import '../../../widgets/customapp_bar.dart';
import '../../../widgets/custombtn.dart';
import '../../../widgets/detailstext1.dart';
import '../../../widgets/detailstext2.dart';


class PrivacyandPolicy extends StatefulWidget {
  const PrivacyandPolicy({super.key});

  @override
  State<PrivacyandPolicy> createState() => PrivacyandPolicyState();
}

class PrivacyandPolicyState extends State<PrivacyandPolicy> {
  bool isChecked = false;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 13,vertical: 14),
                child: CustomAppBar(text1: 'Privacy',text: ''),
              ),
              const SizedBox(height: 20,),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text1(text1: 'Privacy Policy'),
                    const SizedBox(
                      height: 8,
                    ),
                    const Text2(
                        text2:
                            'My Application is one of our main priorities is the privacy of our visitors.This privacy policy document contains types of information that is collected and recorded by My App and how we use it.'),
                    const SizedBox(
                      height: 8,
                    ),
                    const Text2(
                        text2:
                            'if you have additional questions or require more information about our Privacy policy do not hesitate to contact us'),
                    const SizedBox(
                      height: 8,
                    ),
                    const Text2(
                        text2:
                            'This privacy policy applies only to our online activities and is valid for vistors to or websitewith regards to the information that they shared and collect my app.'),
                    const SizedBox(
                      height: 8,
                    ),
                    const Text2(
                        text2:
                            'By using this our app,you hereby consent to our Privacy Policy and agree to its terms.This privavcy policy has been generated whih is available.'),
                    const SizedBox(
                      height: 8,
                    ),
                    const Text2(
                        text2:
                            'if you have additional questions or require more information about our Privacy policy do not hesitate to contact us'),
                    const SizedBox(
                      height: 8,
                    ),
                    const Text2(
                        text2:
                            'This privacy policy applies only to our online activities and is valid for vistors to or websitewith regards to the information that they shared and collect my app.'),
                    const SizedBox(
                      height: 8,
                    ),
                    const Text2(
                        text2:
                            'By using this our app,you hereby consent to our Privacy Policy and agree to its terms.This privavcy policy has been generated whih is available.'),
                    const SizedBox(
                      height: 8,
                    ),
                    const Text2(
                        text2:
                            'if you have additional questions or require more information about our Privacy policy do not hesitate to contact us'),
                    const SizedBox(
                      height: 8,
                    ),
                    const Text2(
                        text2:
                            'This privacy policy applies only to our online activities and is valid for vistors to or websitewith regards to the information that they shared and collect my app.'),
                    const SizedBox(
                      height: 8,
                    ),
                    

                    const SizedBox(
                      height: 15,
                    ),
                    CustomButton(text: 'Confirm', onTap: (){})

                  ],
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}
