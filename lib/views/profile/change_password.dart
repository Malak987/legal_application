import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../state/session_controller.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/customtextfield.dart';
import '../../widgets/detailstext1.dart';

/// Changes the signed-in account's password through Supabase Auth.
///
/// This screen used to be three uncontrolled text fields whose button had an
/// empty `onTap`: it looked like a working feature and did nothing. It now
/// re-authenticates with the current password and calls `updatePassword`, so
/// the operation is real and a wrong current password is reported instead of
/// silently ignored.
class ChangePassword extends StatefulWidget {
  const ChangePassword({super.key});

  /// Supabase Auth rejects anything shorter, and the sign-up form uses the same
  /// floor, so the two cannot disagree.
  static const int minPasswordLength = 6;

  @override
  State<ChangePassword> createState() => _ChangePasswordState();
}

class _ChangePasswordState extends State<ChangePassword> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  /// Client-side checks only. The authoritative authentication rules live in Supabase, and a
  /// rejection from there is surfaced through [AuthException.message].
  String? _validate() {
    final current = _current.text;
    final next = _next.text;
    final confirm = _confirm.text;

    if (current.isEmpty) return 'Enter your current password.';
    if (next.length < ChangePassword.minPasswordLength) {
      return 'Your new password must be at least '
          '${ChangePassword.minPasswordLength} characters.';
    }
    if (next != confirm) return 'The new passwords do not match.';
    if (next == current) return 'The new password must be different.';
    return null;
  }

  Future<void> _submit(SessionController session) async {
    if (_saving) return; // a second tap must not send a second request

    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await session.changePassword(
        currentPassword: _current.text,
        newPassword: _next.text,
      );
      if (!mounted) return;
      // The account stays signed in: Supabase Auth re-authenticated the same user.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Your password has been changed.')),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is AuthException
            ? e.message
            : 'Could not change your password. Check your connection and retry.';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CustomAppBar(text: 'Change Password', text1: ''),
                const SizedBox(height: 40),
                const Text1(text1: 'Change Your Password'),
                const SizedBox(height: 8),
                CustomTextField(
                  icon: Icons.lock,
                  icon2: Icons.visibility_off,
                  label: 'Current Password',
                  controller: _current,
                ),
                const SizedBox(height: 8),
                CustomTextField(
                  icon: Icons.lock_outline,
                  icon2: Icons.visibility_off,
                  label: 'New Password',
                  controller: _next,
                ),
                const SizedBox(height: 8),
                CustomTextField(
                  icon: Icons.lock_reset,
                  icon2: Icons.visibility_off,
                  label: 'Confirm New Password',
                  controller: _confirm,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(fontSize: 13, color: Colors.redAccent),
                  ),
                ],
                const SizedBox(height: 16),
                CustomButton(
                  text: _saving ? 'Changing…' : 'Change Password',
                  onTap: _saving ? () {} : () => _submit(session),
                ),
                const SizedBox(height: 12),
                const Text(
                  'You will stay signed in on this device. Other devices keep '
                  'their existing sessions until they sign in again.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
