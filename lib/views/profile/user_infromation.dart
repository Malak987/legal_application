import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../models/app_profile.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/customtextfield.dart';
import '../../widgets/detailstext1.dart';
import '../../services/api_client.dart';
import '../../state/session_controller.dart';
import '../../state/session_scope.dart';

/// Shows the signed-in user's own `users/{uid}` profile.
///
/// The values come from the session, not from hardcoded sample text, and the
/// `role` is displayed read-only: it is owned by the backend and no screen in
/// the app can change it.
class UserInformation extends StatefulWidget {
  const UserInformation({super.key});

  @override
  State<UserInformation> createState() => _UserInformationState();
}

class _UserInformationState extends State<UserInformation> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();

  String? _filledFor;
  bool _isSaving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  /// Fills the fields when the profile arrives (or the account changes).
  ///
  /// Done in `didChangeDependencies` rather than `build`: mutating a controller
  /// during build would notify listeners mid-frame. The uid guard means a
  /// later rebuild never overwrites text the user is editing.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final profile = SessionScope.of(context).profile;
    if (profile != null) _sync(profile);
  }

  /// Copies the loaded profile into the fields once per uid, so a rebuild does
  /// not wipe what the user is typing.
  void _sync(AppProfile profile) {
    if (_filledFor == profile.uid) return;
    _filledFor = profile.uid;
    _nameController.text = profile.name;
    _emailController.text = profile.email;
    _phoneController.text = profile.phone;
    _addressController.text = profile.address;
  }

  Future<void> _save(SessionController session) async {
    final profile = session.profile;
    if (profile == null) return;

    final name = _nameController.text.trim();
    if (name.length < 2) {
      _showMessage('Please enter your full name (at least 2 characters).');
      return;
    }

    setState(() => _isSaving = true);
    try {
      await session.updateProfile(
        name: name,
        email: profile.email,
        phone: _phoneController.text.trim(),
        address: _addressController.text.trim(),
      );
      if (!mounted) return;
      _showMessage('Profile updated.');
    } catch (e) {
      if (!mounted) return;
      _showMessage(
        e is ApiException ? e.message : 'Could not save your changes.',
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final profile = session.profile;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                      },
                      child: Container(
                        height: 30,
                        width: 30,
                        decoration: BoxDecoration(
                          border: Border.all(color: AppColors.text3Color),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.arrow_back, color: Colors.black54, size: 20),
                      ),
                    ),
                    const Text1(
                      text1: 'User Info',
                      size: 16,
                    ),
                    // This screen already IS the editor: the fields below
                    // are bound to the loaded profile and "Save Information"
                    // calls SessionController.updateProfile. The old header
                    // "Edit" button opened a duplicate screen of sample data,
                    // so it is replaced by a spacer that keeps the title centred.
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Center(
                      child: CircleAvatar(
                        radius: 30,
                        backgroundImage: AssetImage('images/c3.png'), // Example profile picture
                      ),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: Text(
                        profile?.displayName ?? 'Loading…', // Real account name
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: AppColors.text1Color,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        profile?.email ?? '', // Real account email
                        style: const TextStyle(
                          fontSize: 16,
                          color: AppColors.text2Color,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Center(
                      child: Text(
                        profile == null ? '' : 'Account type: ${profile.role}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.text2Color,
                        ),
                      ),
                    ),
                    if (session.error != null) ...[
                      const SizedBox(height: 8),
                      Center(
                        child: Text(
                          session.error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.redAccent,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    CustomTextField(
                        icon: Icons.person_outline,
                        label: 'Full Name',
                        controller: _nameController),
                    // The backend refuses an email change from an ordinary
                    // session (it is the sign-in identity), so the label says
                    // so instead of silently discarding what is typed here.
                    CustomTextField(
                        icon: Icons.email,
                        label: 'Email (change via an administrator)',
                        controller: _emailController),
                    CustomTextField(
                        icon: Icons.phone,
                        label: 'Phone Number',
                        controller: _phoneController),
                    CustomTextField(
                        icon: Icons.home,
                        label: 'Address',
                        controller: _addressController),
                    const SizedBox(height: 15),
                    CustomButton(
                        text: _isSaving ? 'Saving…' : 'Save Information',
                        onTap: profile == null || _isSaving
                            ? () {}
                            : () => _save(session)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
