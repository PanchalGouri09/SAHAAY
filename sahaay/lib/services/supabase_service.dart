import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfigurationException implements Exception {
  final String message;
  const SupabaseConfigurationException(this.message);

  @override
  String toString() => message;
}

class SupabaseService {
  SupabaseService._();

  static const url = String.fromEnvironment('SUPABASE_URL');
  static const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get isConfigured =>
      url.isNotEmpty &&
      anonKey.isNotEmpty &&
      !url.contains('YOUR-PROJECT') &&
      !anonKey.contains('YOUR-SUPABASE-ANON-KEY');

  static bool get isInitialized {
    try {
      Supabase.instance;
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> initializeIfConfigured() async {
    if (!isConfigured) return false;
    if (isInitialized) return true;
    await Supabase.initialize(url: url, publishableKey: anonKey);
    return true;
  }

  static SupabaseClient get client {
    if (!isInitialized) {
      throw const SupabaseConfigurationException(
        'Supabase is not initialized. Run with SUPABASE_URL and SUPABASE_ANON_KEY.',
      );
    }
    return Supabase.instance.client;
  }
}
