import 'package:flutter/material.dart';

import '../constants/colors.dart';
import '../views/settings/views/notifications.dart';
import '../widgets/detailstext1.dart';

/// Original Home identity from e5911a6: white menu, centered title and the
/// filled notification bell in its 42-pixel white circle. No replacement logo.
/// The hit areas are 48 pixels without changing the original icon artwork.
class HomeWidgte extends StatelessWidget {
  const HomeWidgte({super.key, this.language = 'en'});

  final String language;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      IconButton(
        tooltip: language == 'ar' ? 'القائمة' : 'Open menu',
        onPressed: () => Scaffold.of(context).openDrawer(),
        constraints: const BoxConstraints.tightFor(width: 48, height: 48),
        padding: const EdgeInsets.all(12),
        icon: const Icon(Icons.menu_outlined, color: Colors.white, size: 24),
      ),
      Expanded(
        child: Center(
          child: Text1(
            text1: language == 'ar' ? 'الرئيسية' : 'Home',
            size: 16,
            color: Colors.white,
          ),
        ),
      ),
      IconButton(
        tooltip: language == 'ar' ? 'الإشعارات' : 'Notifications',
        onPressed:
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const GroceryNotifications()),
            ),
        constraints: const BoxConstraints.tightFor(width: 48, height: 48),
        padding: const EdgeInsets.all(3),
        iconSize: 42,
        icon: Container(
          key: const ValueKey('home-original-notification-circle'),
          height: 42,
          width: 42,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: const Icon(
            Icons.notifications,
            color: AppColors.buttonColor,
            size: 24,
          ),
        ),
      ),
    ],
  );
}
