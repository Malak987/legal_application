import 'package:flutter/material.dart';
import '../../constants/colors.dart';
import '../../widgets/customapp_bar.dart';
import 'views/faqs.dart';
import 'views/notifications.dart';
import 'views/privacyandpolicy.dart';
import 'views/termsofservices.dart';

class Settings extends StatefulWidget {
  const Settings({super.key});

  @override
  State<Settings> createState() => _SettingsState();
}

class _SettingsState extends State<Settings> {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
            child: Column(
              children: [
                const CustomAppBar(text: 'Settings', text1:''),
                const SizedBox(height: 20),
                TabContainer(
                  text: 'Notifications',
                  icon: Icons.notifications,
                  onTap: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const GroceryNotifications()));


                    // Add your onTap logic here
                  },
                ),
                TabContainer(
                  text: 'Privacy Policy',
                  icon: Icons.privacy_tip,
                  onTap: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyandPolicy()));
                  },
                ),
                TabContainer(
                  text: 'Terms Of Service',
                  icon: Icons.article,
                  onTap: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const TermsOfServices()));
                  },
                ),
                TabContainer(
                  text: 'FAQ',
                  icon: Icons.help_outline,
                  onTap: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const FaqsScreen()));
                  },
                ),

              ],
            ),
          ),
        ),
      ),
    );
  }
}


class TabContainer extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback onTap;

  const TabContainer({super.key,
    required this.text,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        color: Colors.white,
        elevation: 3,

        child: Padding(
          padding: const EdgeInsets.all(13.0),
          child: Row(
            children: [
              Icon(icon, color: AppColors.text3Color),
              const SizedBox(width: 14,),
              Text(text, style: const TextStyle(color: AppColors.text3Color)),
              const Spacer(),
              const Icon(Icons.arrow_forward_ios, size: 16,color: AppColors.text3Color,),


            ],
          ),
        ),
      ),
    );
  }
}
