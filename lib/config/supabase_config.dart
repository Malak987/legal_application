import 'supabase_client_config.dart';

/// Compile-time Supabase configuration for the Legal Services mobile app.
///
/// These values exist ONLY when passed to the exact `flutter run`/`flutter
/// build` command as Dart defines. Shell environment variables are not read:
/// ```bash
/// flutter run --dart-define-from-file=supabase.local.json
/// # or
/// flutter run \
///   --dart-define=SUPABASE_URL=https://qqfzbecwhewswkyxgebu.supabase.co \
///   --dart-define=SUPABASE_ANON_KEY=<public anon/publishable key>
/// ```
/// Read them through the validated [SupabaseClientConfig.environment] rather
/// than using [supabaseUrl]/[supabaseAnonKey] directly.
///
/// Security invariant: NEVER pass or embed a Supabase `service_role` or
/// `secret` key in Flutter client code. Only the public `anon` / `publishable`
/// key belongs on the client.
class SupabaseConfig {
  const SupabaseConfig._();

  /// Connected Supabase project reference ID.
  static const String projectRef = String.fromEnvironment(
    'SUPABASE_PROJECT_REF',
    defaultValue: 'qqfzbecwhewswkyxgebu',
  );

  /// Connected Supabase project URL.
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://qqfzbecwhewswkyxgebu.supabase.co',
  );

  /// Public Supabase anon/publishable key.
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  /// Exact, verified dashboard HTTPS callback used by mobile password
  /// recovery. Lawyer invitations are activated on the web dashboard and never
  /// rely on a native callback. No custom callback is guessed or hard-coded.
  static const String authRedirectUrl = String.fromEnvironment(
    'SUPABASE_AUTH_REDIRECT_URL',
    defaultValue: '',
  );

  /// Public registration stays disabled until the live Auth identity-linking
  /// trigger has been hardened and the post-confirmation profile flow has been
  /// verified. Login remains available when Supabase is configured.
  static const bool enableClientSignup = bool.fromEnvironment(
    'ENABLE_CLIENT_SIGNUP',
    defaultValue: false,
  );

  /// Explicit opt-in for the public lawyer catalogue read path. Keep disabled
  /// until the target database's security migration and hosted checks have been
  /// approved; configuring Supabase Auth alone must not change data routing.
  static const bool useSupabaseLawyerCatalog = bool.fromEnvironment(
    'USE_SUPABASE_LAWYER_CATALOG',
    defaultValue: false,
  );

  /// Explicit opt-in for owner-scoped favorite reads and writes. Keep disabled
  /// until the reviewed favorites RLS/RPC contract is approved on the target.
  static const bool useSupabaseFavorites = bool.fromEnvironment(
    'USE_SUPABASE_FAVORITES',
    defaultValue: false,
  );

  /// True when the compiled Supabase URL and public key passed validation.
  static bool get isConfigured => SupabaseClientConfig.environment.isValid;
}
