/// Supabase connection details.
///
/// The publishable key is safe to ship in a browser bundle: every table is
/// protected by row level security and all writes go through RPCs. Both values
/// can still be overridden at build time with
/// `--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...`.
class SupabaseConfig {
  const SupabaseConfig._();

  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://fzzxussysyvczdtpzkry.supabase.co',
  );

  static const String publishableKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_v7iCHLlF9pbAOB8B_fosuA_FDhrgYaz',
  );

  /// Name of the private bucket holding clock-in selfies.
  static const String selfieBucket = 'selfies';

  /// Edge Function that owns admin-only auth operations.
  static const String staffFunction = 'manage-staff';
}
