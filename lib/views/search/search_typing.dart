import 'package:flutter/material.dart';

import '../../widgets/customapp_bar.dart';
import '../../widgets/customtextfield.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';

class SearchTyping extends StatelessWidget {
  const SearchTyping({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CustomAppBar(text: 'Search Auto Parts', text1: ''),
              SizedBox(height: 15),
              CustomTextField(
                label: 'Search for auto parts (e.g. Brake Pads, Oil Filter)',
                icon: Icons.search,
                icon2: Icons.cancel,
              ),
              Text1(text1: 'Recent Searches', size: 18),
              SizedBox(height: 15),
              SearchRow(
                text1: 'Brake Pads',
                text2: 'Set of 4',
              ),
              SearchRow(
                text1: 'Oil Filter',
                text2: 'Compatible with Honda Civic',
              ),
              SearchRow(
                text1: 'Headlight Bulb',
                text2: 'H4 Halogen',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SearchRow extends StatelessWidget {
  final String text1, text2;
  const SearchRow({
    super.key,
    required this.text1,
    required this.text2,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text2(
            text2: text1,
          ),
          const SizedBox(width: 5),
          Text1(text1: text2),
          const Spacer(),
          Image.asset('images/arrow-up-right.png'), // Replace with a relevant auto part icon.
        ],
      ),
    );
  }
}
