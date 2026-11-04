/// Local form validation only. Authorization and role assignment belong to
/// the database, never to these checks or to signup metadata.
class RegistrationValidation {
  static String? name(String? value, {bool arabic = true}) {
    if ((value ?? '').trim().length < 2) {
      return arabic
          ? 'أدخل الاسم الكامل (حرفان على الأقل).'
          : 'Enter your full name (at least two characters).';
    }
    return null;
  }

  static String? email(String? value, {bool arabic = true}) {
    final text = (value ?? '').trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(text)) {
      return arabic
          ? 'أدخل بريدًا إلكترونيًا صحيحًا.'
          : 'Enter a valid email address.';
    }
    return null;
  }

  static String? password(String? value, {bool arabic = true}) {
    if ((value ?? '').length < 6) {
      return arabic
          ? 'يجب أن تتكون كلمة المرور من ٦ أحرف على الأقل.'
          : 'Password must contain at least 6 characters.';
    }
    return null;
  }

  static String? confirmation(
    String? value,
    String password, {
    bool arabic = true,
  }) {
    if ((value ?? '').isEmpty || value != password) {
      return arabic
          ? 'كلمتا المرور غير متطابقتين.'
          : 'The passwords do not match.';
    }
    return null;
  }
}
