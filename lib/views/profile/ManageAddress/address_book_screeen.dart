import 'package:flutter/material.dart';

import '../../../constants/colors.dart';
import '../../../state/session_scope.dart';
import '../../../widgets/customapp_bar.dart';
import '../user_infromation.dart';

/// Displays the signed-in user's saved profile address from `SessionScope`.
class AddressBookScreen extends StatelessWidget {
  const AddressBookScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final profile = session.profile;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(text: 'Address Book', text1: ''),
              const SizedBox(height: 15),
              if (profile == null)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (profile.address.trim().isEmpty)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.location_off_outlined,
                          size: 46,
                          color: AppColors.text3Color,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'No address saved yet',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Add your address in User Information.',
                          style: TextStyle(color: AppColors.text2Color),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const UserInformation(),
                              ),
                            );
                          },
                          child: const Text('Add Address'),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Card(
                  color: Colors.white,
                  elevation: 2,
                  child: ListTile(
                    leading: const Icon(
                      Icons.location_on,
                      color: AppColors.buttonColor,
                    ),
                    title: Text(profile.displayName),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (profile.phone.isNotEmpty) Text(profile.phone),
                        if (profile.email.isNotEmpty) Text(profile.email),
                        Text(profile.address),
                      ],
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit),
                      tooltip: 'Edit in User Information',
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const UserInformation(),
                          ),
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
