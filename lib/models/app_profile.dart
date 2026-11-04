/// An application profile stored in the Supabase `public.users` table and
/// linked to its corresponding Supabase Auth identity.
///
/// Auth owns credentials and its UUID; this profile owns contact details and
/// the database-authoritative role. For migrated accounts, `auth_user_id`
/// explicitly maps that UUID to this profile's application ID.
///
/// Parsing is deliberately defensive because legacy records may predate fields
/// such as `address`. A malformed optional value must not crash a screen.
class AppProfile {
  const AppProfile({
    required this.uid,
    this.name = '',
    this.email = '',
    this.phone = '',
    // An omitted role is invalid, not a client privilege default.
    this.role = '',
    this.avatar = '',
    this.address = '',
    this.onboardingStatus = '',
  });

  /// Application profile ID (`public.users.id`); it can differ from Auth UUID
  /// only when an explicit, verified migration mapping exists.
  final String uid;
  final String name;
  final String email;
  final String phone;

  /// Server-owned role loaded from `public.users`. An empty or unknown value is
  /// invalid and must never be treated as a client account.
  final String role;

  /// Whether this row declares one of the roles currently supported by the
  /// supported schema. Recognition alone does not authorize a mobile screen.
  bool get hasValidRole =>
      const {'client', 'user', 'lawyer', 'admin', 'owner'}.contains(role);
  final String avatar;
  final String address;

  /// Lifecycle state assigned by the server. A lawyer is admitted to the
  /// mobile app only after the server-side invitation trigger has activated
  /// the profile, which happens when the invited email is confirmed on the web.
  final String onboardingStatus;

  /// True only for the exact `admin` role. An unknown or mis-cased role is
  /// treated as "not an administrator", matching the backend, which compares
  /// `role === 'admin'` strictly.
  bool get isAdmin => role == 'admin';
  bool get isLawyer => role == 'lawyer';

  /// Both ordinary roles are accepted; never infer a role from a missing value.
  bool get isClient => role == 'client' || role == 'user';

  /// Name to show in the UI, falling back to the email local-part.
  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    final at = email.indexOf('@');
    if (at > 0) return email.substring(0, at);
    return email;
  }

  /// Builds a profile from a PostgREST row or legacy API document.
  ///
  /// The row ID is preferred; legacy JSON may carry only `uid`. A missing role
  /// remains empty so callers can fail closed.
  factory AppProfile.fromJson(Map<String, dynamic> json) {
    String text(String key) {
      final value = json[key];
      if (value == null) return '';
      return value.toString().trim();
    }

    final id = text('id');
    final uid = id.isNotEmpty ? id : text('uid');
    final role = text('role');

    return AppProfile(
      uid: uid,
      name: text('name'),
      email: text('email'),
      phone: text('phone'),
      role: role,
      avatar: text('avatar'),
      address: text('address'),
      onboardingStatus: text('onboarding_status'),
    );
  }

  /// Editable profile fields only. Identity, role, and onboarding lifecycle
  /// stay server-owned and are never serialized back to Supabase by the app.
  Map<String, dynamic> toJson() => {
    'name': name,
    'email': email,
    'phone': phone,
    'avatar': avatar,
    'address': address,
  };

  @override
  String toString() => 'AppProfile($uid, role: $role)';
}
