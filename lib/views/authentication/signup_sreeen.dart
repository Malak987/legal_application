import 'package:flutter/material.dart';

import '../../config/supabase_config.dart';
import '../../constants/colors.dart';
import '../../state/session_scope.dart';
import '../home/homescreen.dart';
import 'login_screen.dart';
import 'registration_validation.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmation = true;
  bool _loading = false;
  String? _message;
  bool get _arabic => Localizations.localeOf(context).languageCode == 'ar';
  String _t(String ar, String en) => _arabic ? ar : en;
  bool _messageIsSuccess = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _handleSignup() async {
    if (_loading ||
        !SupabaseConfig.enableClientSignup ||
        !_form.currentState!.validate()) {
      return;
    }
    setState(() {
      _loading = true;
      _message = null;
      _messageIsSuccess = false;
    });
    final session = SessionScope.read(context);
    final ready = await session.register(
      name: _name.text.trim(),
      email: _email.text.trim(),
      password: _password.text,
    );
    if (!mounted) return;
    setState(() => _loading = false);
    if (ready) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute<void>(builder: (_) => HomePage()),
        (_) => false,
      );
      return;
    }

    final code = session.registrationErrorCode;
    final pending = code == 'email-confirmation-required';
    setState(() {
      _messageIsSuccess = pending;
      _message = switch (code) {
        // Supabase may intentionally obfuscate an already-registered email.
        'email-confirmation-required' => _t(
          'إذا كان التسجيل متاحًا لهذا البريد، فتحقق من بريدك وأكمل التأكيد ثم سجّل الدخول.',
          'If registration is available for this email, check your inbox, confirm your address, then sign in.',
        ),
        'email-already-in-use' => _t(
          'قد يكون لهذا البريد حساب بالفعل. حاول تسجيل الدخول.',
          'An account may already exist for this email. Try signing in.',
        ),
        'invalid-email' => _t(
          'أدخل بريدًا إلكترونيًا صحيحًا.',
          'Enter a valid email address.',
        ),
        'weak-password' => _t(
          'اختر كلمة مرور أقوى.',
          'Choose a stronger password.',
        ),
        'too-many-requests' => _t(
          'محاولات كثيرة. انتظر قليلًا ثم حاول مجددًا.',
          'Too many attempts. Wait a moment and try again.',
        ),
        'network-request-failed' => _t(
          'تعذر الاتصال. تحقق من الإنترنت وحاول مجددًا.',
          'Could not connect. Check your internet connection and try again.',
        ),
        'auth-redirect-not-configured' ||
        'auth-not-configured' ||
        'signup-not-enabled' => _t(
          'التسجيل غير متاح حاليًا. يرجى المحاولة لاحقًا.',
          'Registration is currently unavailable. Please try again later.',
        ),
        _ when session.registrationAccountCreated => _t(
          'قد يكون الحساب قد أُنشئ، لكن تعذر إكمال الإعداد. حاول تسجيل الدخول لاحقًا أو تواصل مع الدعم، ولا تُعد التسجيل.',
          'Your account may have been created, but setup could not be completed. Try signing in later or contact support; do not register again.',
        ),
        _ => _t(
          'تعذر إنشاء الحساب. يرجى المحاولة لاحقًا.',
          'Could not create the account. Please try again later.',
        ),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _arabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: AppColors.buttonColor,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 24,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - 48).clamp(
                      0,
                      double.infinity,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'Legal Services App',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        constraints: const BoxConstraints(maxWidth: 520),
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Form(
                          key: _form,
                          autovalidateMode: AutovalidateMode.onUserInteraction,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                _t('إنشاء حساب', 'Create account'),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 24,
                                  color: AppColors.buttonColor,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 20),
                              if (!SupabaseConfig.enableClientSignup)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Text(
                                    _t(
                                      'التسجيل غير متاح حاليًا. يرجى المحاولة لاحقًا.',
                                      'Registration is currently unavailable. Please try again later.',
                                    ),
                                    style: const TextStyle(
                                      color: Colors.deepOrange,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              TextFormField(
                                controller: _name,
                                validator:
                                    (value) => RegistrationValidation.name(
                                      value,
                                      arabic: _arabic,
                                    ),
                                textInputAction: TextInputAction.next,
                                autofillHints: const [AutofillHints.name],
                                decoration: InputDecoration(
                                  labelText: _t('الاسم الكامل', 'Full name'),
                                  prefixIcon: const Icon(Icons.person_outline),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _email,
                                validator:
                                    (value) => RegistrationValidation.email(
                                      value,
                                      arabic: _arabic,
                                    ),
                                keyboardType: TextInputType.emailAddress,
                                textInputAction: TextInputAction.next,
                                autofillHints: const [AutofillHints.email],
                                decoration: InputDecoration(
                                  labelText: _t(
                                    'البريد الإلكتروني',
                                    'Email address',
                                  ),
                                  prefixIcon: const Icon(Icons.email_outlined),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _password,
                                validator:
                                    (value) => RegistrationValidation.password(
                                      value,
                                      arabic: _arabic,
                                    ),
                                obscureText: _obscurePassword,
                                textInputAction: TextInputAction.next,
                                autofillHints: const [
                                  AutofillHints.newPassword,
                                ],
                                decoration: InputDecoration(
                                  labelText: _t('كلمة المرور', 'Password'),
                                  prefixIcon: const Icon(Icons.lock_outline),
                                  suffixIcon: IconButton(
                                    tooltip:
                                        _obscurePassword
                                            ? _t(
                                              'إظهار كلمة المرور',
                                              'Show password',
                                            )
                                            : _t(
                                              'إخفاء كلمة المرور',
                                              'Hide password',
                                            ),
                                    onPressed:
                                        () => setState(
                                          () =>
                                              _obscurePassword =
                                                  !_obscurePassword,
                                        ),
                                    icon: Icon(
                                      _obscurePassword
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _confirmation,
                                validator:
                                    (value) =>
                                        RegistrationValidation.confirmation(
                                          value,
                                          _password.text,
                                          arabic: _arabic,
                                        ),
                                obscureText: _obscureConfirmation,
                                onFieldSubmitted: (_) => _handleSignup(),
                                decoration: InputDecoration(
                                  labelText: _t(
                                    'تأكيد كلمة المرور',
                                    'Confirm password',
                                  ),
                                  prefixIcon: const Icon(Icons.lock_outline),
                                  suffixIcon: IconButton(
                                    tooltip:
                                        _obscureConfirmation
                                            ? _t(
                                              'إظهار التأكيد',
                                              'Show confirmation',
                                            )
                                            : _t(
                                              'إخفاء التأكيد',
                                              'Hide confirmation',
                                            ),
                                    onPressed:
                                        () => setState(
                                          () =>
                                              _obscureConfirmation =
                                                  !_obscureConfirmation,
                                        ),
                                    icon: Icon(
                                      _obscureConfirmation
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              if (_message != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Text(
                                    _message!,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color:
                                          _messageIsSuccess
                                              ? Colors.green.shade800
                                              : Colors.red.shade800,
                                    ),
                                  ),
                                ),
                              SizedBox(
                                height: 48,
                                child: ElevatedButton(
                                  onPressed:
                                      _loading ||
                                              !SupabaseConfig.enableClientSignup
                                          ? null
                                          : _handleSignup,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.buttonColor,
                                    foregroundColor: Colors.white,
                                  ),
                                  child:
                                      _loading
                                          ? const SizedBox(
                                            height: 22,
                                            width: 22,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                          : Text(
                                            _t(
                                              'إنشاء الحساب',
                                              'Create account',
                                            ),
                                          ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextButton(
                                onPressed:
                                    _loading
                                        ? null
                                        : () {
                                          Navigator.pushReplacement(
                                            context,
                                            MaterialPageRoute<void>(
                                              builder:
                                                  (_) => const LoginScreen(),
                                            ),
                                          );
                                        },
                                child: Text(
                                  _t(
                                    'لديك حساب؟ سجّل الدخول',
                                    'Already have an account? Sign in',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
