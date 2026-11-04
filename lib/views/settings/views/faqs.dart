import 'package:flutter/material.dart';

import '../../../constants/colors.dart';
import '../../../widgets/customapp_bar.dart';
import '../../../widgets/custombtn.dart';
import '../../../widgets/detailstext1.dart';


class FaqsScreen extends StatefulWidget {
  const FaqsScreen({super.key});

  @override
  State<FaqsScreen> createState() => _FaqsScreenState();
}

class _FaqsScreenState extends State<FaqsScreen> {
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
                child: CustomAppBar(text1: 'FAQS', text: '',),
              ),              SizedBox(height: 20,),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Frequently Asked Questions:',style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600
                    ),),
                    SizedBox(
                      height: 12,
                    ),
                    Faqstab(text: 'Pinapple related questions:'),
                    Faqstab(text: 'System related questions:'),
                    Faqstab(text: 'Support related questions:'),
                    Faqstab(text: 'How can I reset my password?'),
                    Faqstab(text: 'What are the available payment methods?'),
                    Faqstab(text: 'How do I update my account information?'),
                    Faqstab(text: 'How do I contact customer support?'),
                    Faqstab(text: 'Is my personal information secure?'),
                    Faqstab(text: 'What is the return policy?'),







                  ],
                ),
              )
            ],
          ),
        ),
        bottomNavigationBar: Padding(padding: const EdgeInsets.symmetric(
            horizontal: 12,vertical: 15

        ),
          child:CustomButton(text: 'Submit your Question',onTap: (){},)

        ),
      ),


    );

  }
}

class Faqstab extends StatelessWidget {
  final String text;
  const Faqstab({
    super.key, required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(
        vertical: 4
      ),
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
      child: Row(
        children: [
          Text1(text1: text,),
          const Spacer(),
          const Icon(Icons.arrow_drop_down,color: Colors.white,)



        ],


      ),


    );
  }
}
