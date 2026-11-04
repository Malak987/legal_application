
import 'package:legalserviceapp/views/profile/past_orders.dart';
import 'package:legalserviceapp/views/profile/user_infromation.dart';
import 'package:flutter/material.dart';



import '../../constants/colors.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../authentication/login_screen.dart';
import 'ManageAddress/address_book_screeen.dart';
import 'change_password.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
     
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 13,vertical: 14),
          children: [
            const CustomAppBar(text: 'Profile', text1: ''),
            const SizedBox(height: 20,),
            const _AccountHeader(),
            const SizedBox(height: 12,),
            ProfileRow(
              leadingIcon: Icons.person,
              title: 'User Information',
              onTap: () {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (context) => const UserInformation()));
              },
            ),
            ProfileRow(
              leadingIcon: Icons.location_on,
              title: 'Address Book',
              onTap: () {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (context) =>  AddressBookScreen()));
              },
            ),

            ProfileRow(
              leadingIcon: Icons.lock,
              title: 'Change Password',
              onTap: () {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (context) => const ChangePassword()));
              },
            ),

            ProfileRow(
              leadingIcon: Icons.reorder,
              title: 'My Orders',
              onTap: () {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (context) =>  const PastOrders()));
              },
            ),
            const Divider(),
            // NOTE: there used to be an "Edit Profile" row here that opened
            // `edit_profile.dart` - a screen showing the sample name
            // "John Doe" whose Save button did nothing. "User Information"
            // above is the real editor (SessionController.updateProfile) and
            // is now the only way to edit a profile.
            ProfileRow(
              leadingIcon: Icons.logout,
              title: 'Sign Out',
              onTap: () => _signOut(context),
            ),
          ],
        ),
      ),
    );
  }
}


class ProfileRow extends StatelessWidget {
  final IconData leadingIcon;
  final String title;
  final VoidCallback onTap;

  const ProfileRow({
    required this.leadingIcon,
    required this.title,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Card(
        color: Colors.white,
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            children: [
              Icon(leadingIcon,color: AppColors.text3Color,),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 16,color: AppColors.text3Color,),
            ],
          ),
        ),
      ),
    );
  }
}


/// Signs the user out and clears the navigation stack.
///
/// Replacing the stack (instead of popping) guarantees no authenticated screen
/// is reachable with the Back gesture afterwards.
Future<void> _signOut(BuildContext context) async {
  final navigator = Navigator.of(context);
  await SessionScope.read(context).signOut();
  navigator.pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (route) => false,
  );
}

/// The signed-in identity, read from the session rather than hardcoded.
class _AccountHeader extends StatelessWidget {
  const _AccountHeader();

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final profile = session.profile;

    if (profile == null) {
      return Card(
        color: Colors.white,
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            children: [
              const SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  session.error ?? 'Loading your profile…',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      color: Colors.white,
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(14.0),
        child: Row(
          children: [
            const CircleAvatar(
              radius: 24,
              backgroundImage: AssetImage('images/c3.png'),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.displayName,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    profile.email,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.text2Color,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.bgColor,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                profile.role,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
