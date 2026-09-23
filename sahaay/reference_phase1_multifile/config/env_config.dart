/// Central place for all environment/configuration values.
///
/// IMPORTANT (per project rules): no secrets are hardcoded here.
/// Everything is read from `--dart-define` flags passed at build/run time,
/// or from `--dart-define-from-file=env.json` (recommended — see env.example.json).
///
/// If a value is missing, the app falls back to DEMO MODE so the UI can
/// still be presented before Firebase/Supabase/FastAPI are configured.
class EnvConfig {
  EnvConfig._();

  // ---------------- Demo / Mock mode ----------------
  // When true, AuthService/SupabaseService/ApiService use in-memory mock
  // implementations instead of hitting real backends.
  static const bool demoMode = bool.fromEnvironment(
    'DEMO_MODE',
    defaultValue: true, // default ON until you wire up real keys
  );

  // ---------------- Supabase ----------------
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get isSupabaseConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  // ---------------- FastAPI (AI service, built by teammate) ----------------
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );

  // ---------------- Google Maps ----------------
  // NOTE: The Google Maps API key for Android/iOS is NOT set here — it must
  // go into android/app/src/main/AndroidManifest.xml and ios/Runner/AppDelegate.swift
  // (see the setup notes in README_PHASE1.md). This constant is only used
  // for any web/map-tile REST calls if you add them later.
  static const String mapsApiKey = String.fromEnvironment('MAPS_API_KEY');

  /// Convenience flag: are we fully wired to real backends?
  static bool get isFullyConfigured => !demoMode && isSupabaseConfigured;
}
