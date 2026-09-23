// =============================================================================
// SAHAAY — "Connecting Surplus With Need"
// -----------------------------------------------------------------------------
// PHASE 1 (FINAL UI/UX UPDATE) — single-file implementation, per project
// instructions.
//
// This file intentionally contains the entire prototype UI: theme, typography,
// reusable widgets, and every screen (splash through all four role
// dashboards). It replaces the earlier multi-file Phase 1 structure, which
// has been preserved for reference in /reference_phase1_multifile.
//
// WHAT'S REAL vs WHAT'S PENDING A REAL BACKEND (read before wiring backends):
//   - Navigation, theming, forms, validation, state transitions: REAL.
//   - Login/registration: local in-memory session (AppState), not Firebase
//     yet — swap point is clearly marked in AppState below.
//   - Donations, claims, deliveries, notifications: REAL within a session —
//     created from what the signed-in user actually enters/does. There is
//     no pre-seeded demo content anywhere.
//   - Leaderboard, AI predictions, match scores, freshness/quality scores,
//     platform-wide admin analytics: show an honest empty/pending state
//     until the real database/AI service is connected — no invented numbers.
//   - Maps: a styled placeholder, never presented as a live map.
// =============================================================================

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'firebase_options.dart';
import 'services/api_service.dart';
import 'services/firebase_auth_service.dart';
import 'services/supabase_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await SupabaseService.initializeIfConfigured();
  runApp(const SahaayApp());
}

// =============================================================================
// ENUMS & SIMPLE DATA MODELS (mock domain objects for this UI phase)
// =============================================================================

enum UserRole { provider, ngo, volunteer, admin }

enum ProviderType { restaurant, hotel, collegeCanteen, caterer, bakery, other }

String providerTypeLabel(ProviderType t) {
  switch (t) {
    case ProviderType.restaurant:
      return 'Restaurant';
    case ProviderType.hotel:
      return 'Hotel';
    case ProviderType.collegeCanteen:
      return 'College Canteen';
    case ProviderType.caterer:
      return 'Caterer';
    case ProviderType.bakery:
      return 'Bakery';
    case ProviderType.other:
      return 'Other';
  }
}

enum DonationStatus { available, claimed, inTransit, delivered, expired }

String donationStatusLabel(DonationStatus s) {
  switch (s) {
    case DonationStatus.available:
      return 'Available';
    case DonationStatus.claimed:
      return 'Claimed';
    case DonationStatus.inTransit:
      return 'In Transit';
    case DonationStatus.delivered:
      return 'Delivered';
    case DonationStatus.expired:
      return 'Expired';
  }
}

Color donationStatusColor(DonationStatus s, BuildContext context) {
  final c = AppColors.of(context);
  switch (s) {
    case DonationStatus.available:
      return c.blueLight;
    case DonationStatus.claimed:
      return c.bluePrimary;
    case DonationStatus.inTransit:
      return const Color(0xFFF2A93B);
    case DonationStatus.delivered:
      return c.green;
    case DonationStatus.expired:
      return const Color(0xFFE0483F);
  }
}

/// Maps a backend donation status string onto the UI's five-state enum.
/// The backend has more states (pickup_assigned, picked_up, completed,
/// cancelled) than this prototype UI models, so related states are folded
/// onto their nearest UI equivalent.
DonationStatus _donationStatusFromBackend(String? s) {
  switch (s) {
    case 'available':
      return DonationStatus.available;
    case 'claimed':
      return DonationStatus.claimed;
    case 'pickup_assigned':
    case 'picked_up':
    case 'in_transit':
      return DonationStatus.inTransit;
    case 'delivered':
    case 'completed':
      return DonationStatus.delivered;
    default:
      return DonationStatus.expired; // expired / cancelled / unmapped
  }
}

/// "3:20 PM" style label from a timestamp, without intl locale setup.
String _timeLabel(DateTime value) {
  final rawHour = value.toLocal().hour;
  final hour = rawHour % 12 == 0 ? 12 : rawHour % 12;
  final minute = value.toLocal().minute.toString().padLeft(2, '0');
  final period = rawHour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $period';
}

/// "3:20 PM" label from a raw backend ISO timestamp, or '' when absent.
String _fromIsoTime(dynamic value) {
  final parsed = DateTime.tryParse(value?.toString() ?? '');
  if (parsed == null) return '';
  return _timeLabel(parsed);
}

/// Turns a backend error into a user-safe message. Never surfaces a raw
/// stack trace or backend internals.
String _apiErrorMessage(ApiException e, {required String fallback}) {
  switch (e.statusCode) {
    case 400:
      return 'Your donation could not be accepted because it did not pass the food safety check.';
    case 502:
    case 503:
      return 'Food safety verification is temporarily unavailable. Please try again.';
    case 401:
      return 'Your session has expired. Please sign in again.';
    case 403:
      return 'You are not allowed to perform this action.';
    case 500:
      return 'Something went wrong on the server. Please try again.';
    case 422:
      final detail = e.message;
      if (detail.startsWith('[')) {
        return 'Please check the entered details and try again.';
      }
      return detail.isEmpty ? fallback : detail;
    default:
      return e.message.isEmpty ? fallback : e.message;
  }
}

/// Friendly, feature-neutral message for AI-integration errors (matching,
/// escalation, reliability, acknowledgments). Kept separate from [_apiErrorMessage]
/// because that helper is scoped to the food-safety create-donation flow.
String _aiFeatureErrorMessage(ApiException e, {required String fallback}) {
  switch (e.statusCode) {
    case 502:
      return 'The AI service returned an invalid response. Please try again.';
    case 503:
      return 'The AI service is temporarily unavailable. Please try again.';
    case 401:
      return 'Your session has expired. Please sign in again.';
    case 403:
      return 'You are not allowed to perform this action.';
    case 404:
      return 'The requested item was not found.';
    case 400:
      return e.message.isEmpty ? fallback : e.message;
    case 422:
      return e.message.isEmpty ? fallback : e.message;
    default:
      return e.message.isEmpty ? fallback : e.message;
  }
}

enum DeliveryStatus { available, accepted, pickedUp, inTransit, delivered }

String deliveryStatusLabel(DeliveryStatus s) {
  switch (s) {
    case DeliveryStatus.available:
      return 'Available';
    case DeliveryStatus.accepted:
      return 'Accepted';
    case DeliveryStatus.pickedUp:
      return 'Picked Up';
    case DeliveryStatus.inTransit:
      return 'In Transit';
    case DeliveryStatus.delivered:
      return 'Delivered';
  }
}

/// Maps a backend delivery status onto the UI enum. The backend adds
/// 'assigned' (delivery created and assigned to this volunteer) plus
/// 'failed'/'cancelled' which this prototype UI does not model; those fold
/// onto their nearest UI equivalent.
DeliveryStatus _deliveryStatusFromBackend(String? s) {
  switch (s) {
    case 'picked_up':
      return DeliveryStatus.pickedUp;
    case 'in_transit':
      return DeliveryStatus.inTransit;
    case 'delivered':
      return DeliveryStatus.delivered;
    default:
      return DeliveryStatus.accepted; // assigned / accepted / failed / cancelled
  }
}

String _deliveryStatusToBackend(DeliveryStatus s) {
  switch (s) {
    case DeliveryStatus.available:
      return 'available';
    case DeliveryStatus.accepted:
      return 'accepted';
    case DeliveryStatus.pickedUp:
      return 'picked_up';
    case DeliveryStatus.inTransit:
      return 'in_transit';
    case DeliveryStatus.delivered:
      return 'delivered';
  }
}

class Donation {
  final String id;
  final String foodName;
  final String category;
  final double quantityKg;
  final int servings;
  final String providerName;
  final double distanceKm;
  final String expiryLabel;
  final String freshness; // AI-provided label e.g. "Good", "Excellent"
  DonationStatus status;

  // Post-claim detail fields (Section 8). All optional/nullable — populated
  // once the real database is connected. Volunteer fields stay null unless
  // a volunteer actually takes the delivery (volunteering is optional).
  final String? providerAddress;
  final String? providerContactNumber;
  final double? providerRating;
  final int? providerReviewCount;
  String? volunteerName;
  String? volunteerPhone;
  String? volunteerStatus;

  Donation({
    required this.id,
    required this.foodName,
    required this.category,
    required this.quantityKg,
    required this.servings,
    required this.providerName,
    required this.distanceKm,
    required this.expiryLabel,
    required this.freshness,
    required this.status,
    this.providerAddress,
    this.providerContactNumber,
    this.providerRating,
    this.providerReviewCount,
    this.volunteerName,
    this.volunteerPhone,
    this.volunteerStatus,
  });

  /// Builds a Donation from a backend row (GET/POST /api/v1/donations).
  /// The backend does not currently join provider/food names, so fields it
  /// cannot provide fall back to an honest empty state instead of a fake one.
  factory Donation.fromBackend(Map<String, dynamic> json) {
    final deadline =
        DateTime.tryParse(json['pickup_deadline']?.toString() ?? '');
    return Donation(
      id: json['id']?.toString() ?? '',
      foodName: json['food_name']?.toString() ?? 'Untitled food item',
      category: json['food_category']?.toString() ?? 'Other',
      quantityKg: (json['quantity'] as num?)?.toDouble() ?? 0,
      servings: (json['servings'] as num?)?.toInt() ?? 0,
      providerName: '',
      distanceKm: 0,
      expiryLabel: deadline == null ? '' : 'Pickup by ${_timeLabel(deadline)}',
      freshness: '',
      status: _donationStatusFromBackend(json['status']?.toString()),
      providerAddress: json['pickup_address']?.toString(),
    );
  }

  /// Safe display fallback used in notifications and cards whenever the
  /// backend row has no joined provider name.
  String get providerLabel => providerName.isEmpty ? 'a nearby provider' : providerName;

  String get freshnessLabel => freshness.isEmpty ? '—' : freshness;
}

class DeliveryOpportunity {
  final String id;
  final String providerName;
  final String ngoName;
  final String foodName;
  final double quantityKg;
  final double distanceKm;
  final String deadline;
  DeliveryStatus status;

  DeliveryOpportunity({
    required this.id,
    required this.providerName,
    required this.ngoName,
    required this.foodName,
    required this.quantityKg,
    required this.distanceKm,
    required this.deadline,
    required this.status,
  });

  /// Builds a DeliveryOpportunity from a backend deliveries row. The
  /// backend currently returns only ids/addresses/times/status for the
  /// volunteer's deliveries — food name, provider name and NGO name are NOT
  /// joined onto the row — so this uses the pickup/delivery addresses and an
  /// honest generic food label. (Known backend limitation; see report.)
  factory DeliveryOpportunity.fromBackend(Map<String, dynamic> json) {
    final pickup = DateTime.tryParse(json['pickup_time']?.toString() ?? '');
    return DeliveryOpportunity(
      id: json['id']?.toString() ?? '',
      providerName: json['pickup_address']?.toString() ?? '',
      ngoName: json['delivery_address']?.toString() ?? '',
      foodName: 'Food pickup',
      quantityKg: 0,
      distanceKm: 0,
      deadline: pickup == null ? '' : _timeLabel(pickup),
      status: _deliveryStatusFromBackend(json['status']?.toString()),
    );
  }
}

enum NotificationCategory { donation, matching, volunteer, reward, system }

class AppNotificationItem {
  final String? id; // backend notification id (null for local session ones)
  final String title;
  final String body;
  final String time;
  final NotificationCategory category;
  bool read;
  AppNotificationItem({
    this.id,
    required this.title,
    required this.body,
    required this.time,
    this.category = NotificationCategory.system,
    this.read = false,
  });
}

class LeaderboardEntry {
  final int rank;
  final String name;
  final String city;
  final int impactPoints;
  final double kgRedistributed;
  LeaderboardEntry(
      this.rank, this.name, this.city, this.impactPoints, this.kgRedistributed);
}

class RewardBadge {
  final String name;
  final IconData icon;
  final bool earned;
  RewardBadge(this.name, this.icon, this.earned);
}

// =============================================================================
// DATA SOURCE — returns REAL data once Supabase/FastAPI are wired in.
// Every method here intentionally returns empty until then; screens are
// already built to show proper empty/loading states for exactly this case.
// Method names/signatures are unchanged on purpose so no screen needs to
// be touched when real data starts flowing in.
// =============================================================================

class MockData {
  static List<Donation> providerDonations() => [];

  static List<Donation> nearbyDonationsForNgo() => [];

  static List<DeliveryOpportunity> deliveryOpportunities() => [];

  static List<LeaderboardEntry> leaderboard() => [];

  // Badge catalog — this is a fixed product/config list (which badges exist),
  // not user data, so it's kept. `earned` honestly defaults to false for
  // everyone until real progress is tracked by the backend.
  static List<RewardBadge> providerBadges() => [
        RewardBadge('Food Hero', Icons.emoji_events_outlined, false),
        RewardBadge('Green Partner', Icons.eco_outlined, false),
        RewardBadge('Community Champion', Icons.diversity_3_outlined, false),
        RewardBadge(
            'Consistent Contributor', Icons.calendar_month_outlined, false),
      ];

  static List<RewardBadge> volunteerBadges() => [
        RewardBadge('First Delivery', Icons.local_shipping_outlined, false),
        RewardBadge('Helping Hand', Icons.volunteer_activism_outlined, false),
        RewardBadge('Green Runner', Icons.directions_run_outlined, false),
      ];
}

// =============================================================================
// APP STATE — theme mode + demo session. Centralized on purpose so the
// entire app updates from one place (per project requirement).
// =============================================================================

class AppState extends ChangeNotifier {
  final FirebaseAuthService authService;
  late final StreamSubscription<AuthProfile?> _authSubscription;
  late final Future<void> ready;

  ThemeMode themeMode = ThemeMode.light;

  bool isLoggedIn = false;
  UserRole? currentRole;
  String currentName = '';
  String currentOrgLabel = ''; // business/NGO name where relevant

  // Real, session-based notifications — generated only from actual actions
  // the signed-in user takes (creating a donation, claiming one, accepting
  // or completing a delivery). Never pre-seeded with invented content.
  final List<AppNotificationItem> notifications = [];

  AppState(this.authService) {
    ready = _initializeAuth();
  }

  /// Backend API access — adds the Firebase ID token as a Bearer header on
  /// every request. Dashboards read this through [context.read<AppState>()].
  ApiService get api => authService.api;

  Future<void> _initializeAuth() async {
    _applyProfile(await authService.currentProfile);
    _authSubscription = authService.authStateChanges.listen(_applyProfile);
    notifyListeners();
  }

  void _applyProfile(AuthProfile? profile) {
    if (profile == null) {
      isLoggedIn = false;
      currentRole = null;
      currentName = '';
      currentOrgLabel = '';
      return;
    }
    final role = UserRole.values
        .where((value) => value.name == profile.role)
        .firstOrNull;
    if (role == null) return;
    currentRole = role;
    currentName = profile.fullName;
    currentOrgLabel = profile.orgLabel;
    isLoggedIn = true;
  }

  Future<void> login(String email, String password) async {
    _applyProfile(await authService.signIn(email: email, password: password));
    notifyListeners();
  }

  Future<void> register({
    required UserRole role,
    required String email,
    required String password,
    required String fullName,
    required String orgLabel,
    String? phone,
    Map<String, dynamic>? roleProfile,
  }) async {
    _applyProfile(await authService.register(
      email: email,
      password: password,
      role: role.name,
      fullName: fullName,
      orgLabel: orgLabel,
      phone: phone,
      roleProfile: roleProfile,
    ));
    notifyListeners();
  }

  Future<void> sendPasswordResetEmail(String email) =>
      authService.sendPasswordResetEmail(email);

  Future<void> signOut() async {
    await authService.signOut();
    _applyProfile(null);
    notifications.clear();
    notifyListeners();
  }

  void pushNotification(
      String title, String body, NotificationCategory category) {
    notifications.insert(
        0,
        AppNotificationItem(
            title: title,
            body: body,
            time: _timeNowLabel(),
            category: category));
    notifyListeners();
  }

  void markNotificationRead(int index) {
    if (index < 0 || index >= notifications.length) return;
    notifications[index].read = true;
    notifyListeners();
  }

  String _timeNowLabel() {
    final now = TimeOfDay.now();
    final hour = now.hourOfPeriod == 0 ? 12 : now.hourOfPeriod;
    final minute = now.minute.toString().padLeft(2, '0');
    final period = now.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour:$minute $period';
  }

  void toggleTheme() {
    themeMode = themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }

  /// Safe display name for greetings — falls back to a neutral placeholder
  /// instead of ever showing an invented name.
  String get displayName {
    if (currentOrgLabel.isNotEmpty) return currentOrgLabel;
    if (currentName.isNotEmpty) return currentName;
    return 'there';
  }

  @override
  void dispose() {
    _authSubscription.cancel();
    super.dispose();
  }
}

// =============================================================================
// THEME — three blue levels + light/dark surfaces + typography
// =============================================================================

/// The three-level blue hierarchy (existing two + one new deep navy),
/// plus the sustainability green accent, resolved per-brightness so the
/// same [AppColors.of(context)] call works in both themes.
class AppColors {
  final Color blueLight; // existing — secondary/highlights
  final Color bluePrimary; // existing — main brand/actions
  final Color blueDark; // NEW — strong/important (headers, key stats, CTAs)
  final Color green; // sustainability accent only
  final Color greenSoft;
  final Color warning;
  final Color danger;

  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;

  const AppColors({
    required this.blueLight,
    required this.bluePrimary,
    required this.blueDark,
    required this.green,
    required this.greenSoft,
    required this.warning,
    required this.danger,
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
  });

  static const light = AppColors(
    blueLight: Color(0xFF1698F0),
    bluePrimary: Color(0xFF0B4DA1),
    blueDark: Color(0xFF072B52),
    green: Color(0xFF63A11A),
    greenSoft: Color(0xFFE6F2D9),
    warning: Color(0xFFF2A93B),
    danger: Color(0xFFE0483F),
    background: Color(0xFFF6FAFF),
    surface: Colors.white,
    surfaceAlt: Color(0xFFEFF5FC),
    border: Color(0xFFE1E9F5),
    textPrimary: Color(0xFF17233B),
    textSecondary: Color(0xFF5B6B85),
  );

  static const dark = AppColors(
    blueLight: Color(0xFF4DB3FF),
    bluePrimary: Color(0xFF3E7FD9),
    blueDark: Color(0xFF9CC6F5), // used for emphasis TEXT on dark surfaces
    green: Color(0xFF8BC24A),
    greenSoft: Color(0xFF223420),
    warning: Color(0xFFF2B155),
    danger: Color(0xFFEF6B62),
    background: Color(0xFF14171C), // dark grey, NOT pure black
    surface: Color(0xFF1E222A),
    surfaceAlt: Color(0xFF262B34),
    border: Color(0xFF323844),
    textPrimary: Color(0xFFF2F5FA),
    textSecondary: Color(0xFFA9B4C4),
  );

  static AppColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// A solid navy fill for strong headers/CTAs. In dark mode we use the
  /// primary blue (since [blueDark] there is repurposed as a text-emphasis
  /// color) so header contrast stays correct in both themes.
  Color headerFill(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? bluePrimary : blueDark;
}

class AppSpacing {
  static const xs = 4.0, sm = 8.0, md = 16.0, lg = 24.0, xl = 32.0;
}

class AppRadius {
  static const card = 16.0, button = 14.0, chip = 20.0;
}

TextTheme _buildTextTheme(AppColors c) {
  // Flipkart-Minutes-inspired feel: bold, compact, strong hierarchy —
  // without copying their branding or screens.
  return TextTheme(
    displayLarge: TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w800,
        color: c.textPrimary,
        height: 1.15),
    headlineMedium: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w800,
        color: c.textPrimary,
        height: 1.2),
    headlineSmall: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: c.textPrimary,
        height: 1.25),
    titleLarge: TextStyle(
        fontSize: 17, fontWeight: FontWeight.w700, color: c.textPrimary),
    titleMedium: TextStyle(
        fontSize: 15, fontWeight: FontWeight.w600, color: c.textPrimary),
    bodyLarge: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: c.textPrimary,
        height: 1.4),
    bodyMedium: TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w400,
        color: c.textSecondary,
        height: 1.4),
    labelLarge: const TextStyle(
        fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 0.2),
    labelMedium: TextStyle(
        fontSize: 12, fontWeight: FontWeight.w600, color: c.textSecondary),
    labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: c.textSecondary,
        letterSpacing: 0.3),
  );
}

ThemeData _buildTheme(AppColors c, Brightness brightness) {
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: c.bluePrimary,
      brightness: brightness,
      primary: c.bluePrimary,
      secondary: c.blueLight,
      surface: c.surface,
    ),
    scaffoldBackgroundColor: c.background,
    textTheme: _buildTextTheme(c),
    dividerColor: c.border,
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: c.background,
      foregroundColor: c.textPrimary,
      elevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
          fontSize: 18, fontWeight: FontWeight.w700, color: c.textPrimary),
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: c.border),
      ),
      margin: EdgeInsets.zero,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: c.bluePrimary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.button)),
        textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.bluePrimary,
        minimumSize: const Size.fromHeight(52),
        side: BorderSide(color: c.bluePrimary),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.button)),
        textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
          foregroundColor: c.bluePrimary,
          textStyle: const TextStyle(fontWeight: FontWeight.w700)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
          borderSide: BorderSide(color: c.border)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
          borderSide: BorderSide(color: c.border)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
          borderSide: BorderSide(color: c.bluePrimary, width: 1.6)),
      errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
          borderSide: BorderSide(color: c.danger)),
      labelStyle: TextStyle(color: c.textSecondary),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: c.surfaceAlt,
      selectedColor: c.bluePrimary.withOpacity(0.15),
      labelStyle: TextStyle(
          color: c.textPrimary, fontSize: 12.5, fontWeight: FontWeight.w600),
      side: BorderSide(color: c.border),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.chip)),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: c.surface,
      selectedItemColor: c.bluePrimary,
      unselectedItemColor: c.textSecondary,
      showUnselectedLabels: true,
      type: BottomNavigationBarType.fixed,
      selectedLabelStyle:
          const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
      unselectedLabelStyle:
          const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dividerTheme: DividerThemeData(color: c.border, thickness: 1),
  );
}

final ThemeData sahaayLightTheme =
    _buildTheme(AppColors.light, Brightness.light);
final ThemeData sahaayDarkTheme = _buildTheme(AppColors.dark, Brightness.dark);

// =============================================================================
// APP ROOT
// =============================================================================

class SahaayApp extends StatelessWidget {
  const SahaayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(FirebaseAuthService()),
      child: Consumer<AppState>(
        builder: (context, state, _) {
          return MaterialApp(
            title: 'SAHAAY',
            debugShowCheckedModeBanner: false,
            theme: sahaayLightTheme,
            darkTheme: sahaayDarkTheme,
            themeMode: state.themeMode,
            home: const SplashScreen(),
          );
        },
      ),
    );
  }
}

// =============================================================================
// REUSABLE WIDGETS
// =============================================================================

/// The official SAHAAY logo mark. Uses the provided logo asset; falls back
/// to a simple drawn mark only if the asset is missing from the build.
class SahaayLogo extends StatelessWidget {
  final double size;
  final bool showWordmark;
  const SahaayLogo({super.key, this.size = 96, this.showWordmark = true});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // FINAL OFFICIAL LOGO ASSET — used exactly as supplied, never redrawn.
    // `sahaay_logo.png`  = full artwork (icon + wordmark + tagline baked in),
    //                      used wherever showWordmark is true.
    // `sahaay_icon.png`  = the same artwork cropped to just the icon mark,
    //                      used for compact areas (showWordmark: false).
    final assetPath = showWordmark
        ? 'assets/images/sahaay_logo.png'
        : 'assets/images/sahaay_icon.png';

    final logoImage = Image.asset(
      assetPath,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stack) => Container(
        height: size,
        width: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
              colors: [c.blueDark, c.blueLight],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
        ),
        child: Icon(Icons.volunteer_activism,
            color: Colors.white, size: size * 0.5),
      ),
    );

    // The source artwork sits on a flat white canvas (no transparency).
    // On the light theme that blends into our near-white backgrounds, but
    // on the dark theme we present it on a small light card so it stays
    // fully legible — per instructions, the artwork itself is never edited.
    if (!isDark) return logoImage;

    return Container(
      padding: EdgeInsets.all(size * 0.10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(size * 0.16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 12,
              offset: const Offset(0, 4))
        ],
      ),
      child: logoImage,
    );
  }
}

class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;
  final IconData? icon;
  const PrimaryButton(
      {super.key,
      required this.label,
      required this.onPressed,
      this.isLoading = false,
      this.icon});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: isLoading ? null : onPressed,
      child: isLoading
          ? const SizedBox(
              height: 22,
              width: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2.4, color: Colors.white))
          : Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[
                Icon(icon, size: 20),
                const SizedBox(width: 8)
              ],
              Text(label),
            ]),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  const SecondaryButton(
      {super.key, required this.label, required this.onPressed, this.icon});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
        Text(label),
      ]),
    );
  }
}

/// Level of visual emphasis for a stat card, mapping to the 3-blue hierarchy.
enum Emphasis { subtle, primary, strong }

class StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Emphasis emphasis;
  const StatCard(
      {super.key,
      required this.label,
      required this.value,
      required this.icon,
      this.emphasis = Emphasis.subtle});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Color bg, fg;
    switch (emphasis) {
      case Emphasis.strong:
        bg = c.headerFill(context);
        fg = Colors.white;
        break;
      case Emphasis.primary:
        bg = c.bluePrimary.withOpacity(0.10);
        fg = c.bluePrimary;
        break;
      case Emphasis.subtle:
        bg = c.surface;
        fg = c.textPrimary;
        break;
    }
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border:
            emphasis == Emphasis.strong ? null : Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon,
              color:
                  emphasis == Emphasis.strong ? Colors.white70 : c.bluePrimary,
              size: 20),
          const SizedBox(height: 10),
          Text(value,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: emphasis == Emphasis.strong ? Colors.white : fg)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: emphasis == Emphasis.strong
                      ? Colors.white70
                      : c.textSecondary)),
        ],
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const StatusChip({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
          color: color.withOpacity(0.14),
          borderRadius: BorderRadius.circular(AppRadius.chip)),
      child: Text(label,
          style: TextStyle(
              color: color, fontWeight: FontWeight.w700, fontSize: 11.5)),
    );
  }
}

class DonationCard extends StatelessWidget {
  final Donation donation;
  final Widget? trailingAction;
  final VoidCallback? onTap;
  const DonationCard(
      {super.key, required this.donation, this.trailingAction, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(donation.foodName,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  StatusChip(
                      label: donationStatusLabel(donation.status),
                      color: donationStatusColor(donation.status, context)),
                ],
              ),
              const SizedBox(height: 4),
              if (donation.providerName.isNotEmpty)
                Text(donation.providerName,
                    style: TextStyle(color: c.textSecondary, fontSize: 12.5)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _miniInfo(context, Icons.scale_outlined,
                      '${donation.quantityKg.toStringAsFixed(0)} kg • ${donation.servings} servings'),
                  if (donation.distanceKm > 0)
                    _miniInfo(context, Icons.near_me_outlined,
                        '${donation.distanceKm.toStringAsFixed(1)} km away'),
                  if (donation.expiryLabel.isNotEmpty)
                    _miniInfo(context, Icons.schedule_outlined,
                        donation.expiryLabel),
                  _miniInfo(context, Icons.eco_outlined,
                      'Freshness: ${donation.freshnessLabel}'),
                ],
              ),
              if (trailingAction != null) ...[
                const SizedBox(height: 12),
                trailingAction!
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniInfo(BuildContext context, IconData icon, String text) {
    final c = AppColors.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: c.textSecondary),
      const SizedBox(width: 4),
      Text(text, style: TextStyle(fontSize: 12, color: c.textSecondary)),
    ]);
  }
}

/// Strong-emphasis header used at the top of every role dashboard —
/// this is where the NEW deep navy blue does most of its work.
class DashboardHeader extends StatelessWidget {
  final String greeting;
  final String subtitle;
  final String roleLabel;
  final VoidCallback onNotificationTap;
  final VoidCallback onProfileTap;
  const DashboardHeader({
    super.key,
    required this.greeting,
    required this.subtitle,
    required this.roleLabel,
    required this.onNotificationTap,
    required this.onProfileTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xl),
      decoration: BoxDecoration(color: c.headerFill(context)),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(AppRadius.chip)),
                    child: Text(roleLabel,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4)),
                  ),
                  const SizedBox(height: 8),
                  Text(greeting,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 21,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12.5)),
                ],
              ),
            ),
            IconButton(
              onPressed: onNotificationTap,
              icon: const Icon(Icons.notifications_none_rounded,
                  color: Colors.white),
            ),
            InkWell(
              onTap: onProfileTap,
              borderRadius: BorderRadius.circular(20),
              child: const CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.white24,
                  child: Icon(Icons.person, color: Colors.white, size: 20)),
            ),
          ],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  const SectionHeader(
      {super.key, required this.title, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
        if (actionLabel != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    );
  }
}

class AppInputField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool obscureText;
  final TextInputType keyboardType;
  final String? Function(String?)? validator;
  final void Function(String)? onChanged;
  final Widget? suffixIcon;
  final IconData? prefixIcon;
  final int maxLines;
  final String? helperText;
  const AppInputField({
    super.key,
    required this.label,
    required this.controller,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
    this.validator,
    this.onChanged,
    this.suffixIcon,
    this.prefixIcon,
    this.maxLines = 1,
    this.helperText,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      validator: validator,
      onChanged: onChanged,
      maxLines: obscureText ? 1 : maxLines,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        prefixIcon: prefixIcon != null ? Icon(prefixIcon, size: 20) : null,
        suffixIcon: suffixIcon,
      ),
    );
  }
}

class RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const RoleCard(
      {super.key,
      required this.icon,
      required this.title,
      required this.subtitle,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Container(
                height: 48,
                width: 48,
                decoration: BoxDecoration(
                    color: c.bluePrimary.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(14)),
                child: Icon(icon, color: c.bluePrimary),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style:
                            TextStyle(color: c.textSecondary, fontSize: 12.5)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: c.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

class NotificationTile extends StatelessWidget {
  final AppNotificationItem item;
  final VoidCallback? onTap;
  const NotificationTile({super.key, required this.item, this.onTap});

  IconData get _categoryIcon {
    switch (item.category) {
      case NotificationCategory.donation:
        return Icons.inventory_2_outlined;
      case NotificationCategory.matching:
        return Icons.hub_outlined;
      case NotificationCategory.volunteer:
        return Icons.volunteer_activism_outlined;
      case NotificationCategory.reward:
        return Icons.workspace_premium_outlined;
      case NotificationCategory.system:
        return Icons.notifications_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor:
              (item.read ? c.textSecondary : c.bluePrimary).withOpacity(0.12),
          child: Icon(_categoryIcon,
              color: item.read ? c.textSecondary : c.bluePrimary, size: 20),
        ),
        title: Text(item.title,
            style: TextStyle(
                fontWeight: item.read ? FontWeight.w600 : FontWeight.w800)),
        subtitle: Text(item.body),
        trailing: Text(item.time,
            style: TextStyle(fontSize: 11, color: c.textSecondary)),
      ),
    );
  }
}

class RewardCard extends StatelessWidget {
  final int impactPoints;
  final String levelLabel;
  final List<RewardBadge> badges;
  final List<Widget> statLines;
  const RewardCard(
      {super.key,
      required this.impactPoints,
      required this.levelLabel,
      required this.badges,
      required this.statLines});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.workspace_premium_outlined, color: c.bluePrimary),
                const SizedBox(width: 8),
                Text('$impactPoints Impact Points',
                    style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 4),
            StatusChip(label: levelLabel, color: c.green),
            const SizedBox(height: 12),
            ...statLines,
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: badges
                  .map((b) => Column(
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: b.earned
                                ? c.green.withOpacity(0.15)
                                : c.surfaceAlt,
                            child: Icon(b.icon,
                                color: b.earned ? c.green : c.textSecondary,
                                size: 20),
                          ),
                          const SizedBox(height: 4),
                          SizedBox(
                            width: 68,
                            child: Text(b.name,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 10, color: c.textSecondary)),
                          ),
                        ],
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class ImpactCard extends StatelessWidget {
  final String emoji;
  final String value;
  final String label;
  const ImpactCard(
      {super.key,
      required this.emoji,
      required this.value,
      required this.label});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
          color: c.greenSoft,
          borderRadius: BorderRadius.circular(AppRadius.card)),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: c.green)),
                Text(label,
                    style: TextStyle(fontSize: 11.5, color: c.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// AI result card — food surplus prediction. Shows a real result once the
/// FastAPI prediction service is connected; until then it honestly shows
/// a pending state rather than any invented numbers.
class SurplusPredictionCard extends StatelessWidget {
  const SurplusPredictionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.auto_graph_outlined, color: c.bluePrimary, size: 18),
              const SizedBox(width: 6),
              const Expanded(
                  child: Text('AI FOOD SURPLUS PREDICTION',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                          letterSpacing: 0.3))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Icon(Icons.hourglass_empty, size: 16, color: c.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'No prediction yet — this will appear automatically once the AI service is connected.',
                  style: TextStyle(fontSize: 12.5, color: c.textSecondary),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// AI result card — NGO/donation weighted match score (FR-13). Renders a
/// real score once the matching engine provides one; until then it shows
/// an honest pending state instead of any invented percentage.
class MatchScoreCard extends StatelessWidget {
  final Donation donation;
  const MatchScoreCard({super.key, required this.donation});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Recommended: ${donation.foodName}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(donation.providerName,
                style: TextStyle(fontSize: 12, color: c.textSecondary)),
            const SizedBox(height: 12),
            Row(children: [
              Icon(Icons.hub_outlined, size: 16, color: c.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Match score will appear here once the matching engine is connected.',
                  style: TextStyle(fontSize: 12.5, color: c.textSecondary),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              _pill(context, 'Distance',
                  '${donation.distanceKm.toStringAsFixed(1)} km'),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _pill(BuildContext context, String label, String value,
      {bool strong = false}) {
    final c = AppColors.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: strong ? c.bluePrimary.withOpacity(0.10) : c.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(children: [
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: strong ? c.bluePrimary : c.textPrimary)),
          Text(label, style: TextStyle(fontSize: 9.5, color: c.textSecondary)),
        ]),
      ),
    );
  }
}

/// A clearly-labeled map placeholder — never presented as a live map.
class MapPlaceholder extends StatelessWidget {
  final double height;
  const MapPlaceholder({super.key, this.height = 160});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
        color: c.surfaceAlt,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.map_outlined,
              size: 40, color: c.textSecondary.withOpacity(0.5)),
          Positioned(
            bottom: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                  border: Border.all(color: c.border)),
              child: Text('Map preview — Google Maps integration pending',
                  style: TextStyle(fontSize: 10.5, color: c.textSecondary)),
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  const EmptyState({super.key, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(children: [
        Icon(icon, size: 40, color: c.textSecondary.withOpacity(0.5)),
        const SizedBox(height: 10),
        Text(message,
            style: TextStyle(color: c.textSecondary),
            textAlign: TextAlign.center),
      ]),
    );
  }
}

class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isDark = state.themeMode == ThemeMode.dark;
    return IconButton(
      tooltip: isDark ? 'Switch to light theme' : 'Switch to dark theme',
      icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
      onPressed: () => context.read<AppState>().toggleTheme(),
    );
  }
}

// =============================================================================
// SPLASH SCREEN
// =============================================================================

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700));
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
    _navigateNext();
  }

  Future<void> _navigateNext() async {
    await Future.wait([
      Future.delayed(const Duration(milliseconds: 2000)),
      context.read<AppState>().ready,
    ]);
    if (!mounted) return;
    final destination = context.read<AppState>().isLoggedIn
        ? const RoleRouter()
        : const WelcomeScreen();
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => destination));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.background,
      body: Center(
        child: FadeTransition(
          opacity: _fade,
          child: const SahaayLogo(size: 140),
        ),
      ),
    );
  }
}

// =============================================================================
// WELCOME / CONCEPT SCREEN
// =============================================================================

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            children: [
              const SizedBox(height: AppSpacing.md),
              const SahaayLogo(size: 100),
              const SizedBox(height: AppSpacing.lg),
              const Text('Turning Surplus Food Into Hope.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'SAHAAY connects food providers with NGOs to reduce food waste and help communities in need. Volunteers can optionally help deliver food.',
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textSecondary, height: 1.4),
              ),
              const SizedBox(height: AppSpacing.lg),
              _flowDiagram(context),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'GET STARTED',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const RoleSelectionScreen())),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LoginScreen())),
                child: const Text('Already have an account? Login'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const LeaderboardScreen())),
                child: const Text('View Public Impact Leaderboard'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _flowDiagram(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          children: [
            _flowRow(context, '🍽️', 'FOOD PROVIDER',
                'Restaurants, hotels, canteens & caterers with surplus food.'),
            _flowArrow(context),
            _flowRow(context, '🏢', 'NGO',
                'Discovers and claims available surplus food nearby.'),
            _flowArrow(context),
            _flowRow(context, '🤝', 'PEOPLE / COMMUNITY',
                'Receives redistributed meals through the NGO.'),
            const Divider(height: 28),
            _flowRow(context, '👤', 'VOLUNTEER (OPTIONAL)',
                'Can help deliver food between provider and NGO when needed.'),
          ],
        ),
      ),
    );
  }

  Widget _flowRow(
      BuildContext context, String emoji, String title, String desc) {
    final c = AppColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 22)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 12.5,
                      color: c.bluePrimary,
                      letterSpacing: 0.3)),
              Text(desc,
                  style: TextStyle(fontSize: 12, color: c.textSecondary)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _flowArrow(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Icon(Icons.arrow_downward_rounded,
          size: 16, color: c.textSecondary.withOpacity(0.6)),
    );
  }
}

// =============================================================================
// LOGIN SCREEN
// =============================================================================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await context
          .read<AppState>()
          .login(_emailController.text, _passwordController.text);
    } on AuthException catch (error) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = error.message;
        });
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Something went wrong. Please try again.';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _isLoading = false);
    Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const RoleRouter()),
        (route) => false);
  }

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter your email first to reset your password.');
      return;
    }
    try {
      await context.read<AppState>().sendPasswordResetEmail(email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            backgroundColor: AppColors.of(context).bluePrimary,
            content: const Text('Password reset link sent.')),
      );
    } on AuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(actions: const [ThemeToggleButton()]),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: SahaayLogo(size: 76)),
                const SizedBox(height: AppSpacing.lg),
                Text('Welcome back',
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 4),
                Text('Log in to continue making an impact.',
                    style: TextStyle(color: c.textSecondary)),
                const SizedBox(height: AppSpacing.lg),
                AppInputField(
                  label: 'Email',
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  prefixIcon: Icons.email_outlined,
                  validator: (v) => (v == null || !v.contains('@'))
                      ? 'Enter a valid email'
                      : null,
                ),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                  label: 'Password',
                  controller: _passwordController,
                  obscureText: _obscure,
                  prefixIcon: Icons.lock_outline,
                  suffixIcon: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Password is required' : null,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _resetPassword,
                    child: const Text('Forgot password?'),
                  ),
                ),
                if (_error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: c.danger.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10)),
                    child: Text(_error!,
                        style: TextStyle(color: c.danger, fontSize: 12.5)),
                  ),
                  const SizedBox(height: 10),
                ],
                PrimaryButton(
                    label: 'LOGIN', isLoading: _isLoading, onPressed: _login),
                const SizedBox(height: AppSpacing.sm),
                SecondaryButton(
                  label: 'Continue with Google (demo)',
                  icon: Icons.g_mobiledata,
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'Google sign-in will be enabled once Firebase is configured.'))),
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text("Don't have an account?",
                      style: TextStyle(color: c.textSecondary)),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const RoleSelectionScreen())),
                    child: const Text('Register'),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// ROLE SELECTION
// =============================================================================

class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text('Join SAHAAY'),
          actions: const [ThemeToggleButton()]),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('What would you like to do?',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppSpacing.lg),
            RoleCard(
              icon: Icons.restaurant_outlined,
              title: 'Food Provider',
              subtitle:
                  'Restaurant, hotel, college canteen or caterer donating surplus food.',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const RegisterProviderScreen())),
            ),
            const SizedBox(height: AppSpacing.md),
            RoleCard(
              icon: Icons.apartment_outlined,
              title: 'NGO',
              subtitle: 'Discover and claim surplus food for your community.',
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RegisterNgoScreen())),
            ),
            const SizedBox(height: AppSpacing.md),
            RoleCard(
              icon: Icons.volunteer_activism_outlined,
              title: 'Volunteer',
              subtitle:
                  'Optionally help deliver food from providers to NGOs nearby.',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const RegisterVolunteerScreen())),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// REGISTRATION — PROVIDER
// =============================================================================

class RegisterProviderScreen extends StatefulWidget {
  const RegisterProviderScreen({super.key});
  @override
  State<RegisterProviderScreen> createState() => _RegisterProviderScreenState();
}

class _RegisterProviderScreenState extends State<RegisterProviderScreen> {
  final _formKey = GlobalKey<FormState>();
  final _orgName = TextEditingController();
  final _contactPerson = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  ProviderType _type = ProviderType.restaurant;
  bool _isLoading = false;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_password.text != _confirmPassword.text) {
      _showSnack('Passwords do not match.', isError: true);
      return;
    }
    setState(() => _isLoading = true);
    try {
      await context.read<AppState>().register(
            role: UserRole.provider,
            email: _email.text,
            password: _password.text,
            fullName: _contactPerson.text.trim(),
            orgLabel: _orgName.text.trim(),
            phone: _phone.text.trim(),
            roleProfile: {
              'organization_name': _orgName.text.trim(),
              'organization_type': switch (_type) {
                ProviderType.restaurant => 'restaurant',
                ProviderType.hotel => 'hotel',
                ProviderType.collegeCanteen => 'canteen',
                ProviderType.caterer => 'event_organizer',
                ProviderType.bakery => 'other',
                ProviderType.other => 'other',
              },
              'address': _address.text.trim(),
              'city': _city.text.trim(),
              'phone': _phone.text.trim(),
            },
          );
    } on AuthException catch (error) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnack(error.message, isError: true);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _isLoading = false);
    Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const RoleRouter()),
        (route) => false);
  }

  void _showSnack(String msg, {bool isError = false}) {
    final c = AppColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: isError ? c.danger : c.green, content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Register as Food Provider')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppInputField(
                    label: 'Organization / Business Name',
                    controller: _orgName,
                    prefixIcon: Icons.storefront_outlined,
                    validator: _req),
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<ProviderType>(
                  value: _type,
                  decoration: const InputDecoration(labelText: 'Provider Type'),
                  items: ProviderType.values
                      .map((t) => DropdownMenuItem(
                          value: t, child: Text(providerTypeLabel(t))))
                      .toList(),
                  onChanged: (v) => setState(() => _type = v ?? _type),
                ),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Contact Person',
                    controller: _contactPerson,
                    prefixIcon: Icons.person_outline,
                    validator: _req),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Email',
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    prefixIcon: Icons.email_outlined,
                    validator: _emailValidator),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Phone',
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    prefixIcon: Icons.phone_outlined,
                    validator: _phoneValidator),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Address',
                    controller: _address,
                    maxLines: 2,
                    prefixIcon: Icons.location_on_outlined,
                    validator: _req),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'City',
                    controller: _city,
                    prefixIcon: Icons.location_city_outlined,
                    validator: _req,
                    helperText:
                        'Location pin drop available once Maps is connected.'),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Password',
                    controller: _password,
                    obscureText: true,
                    prefixIcon: Icons.lock_outline,
                    validator: _passwordValidator),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Confirm Password',
                    controller: _confirmPassword,
                    obscureText: true,
                    prefixIcon: Icons.lock_outline,
                    validator: _req),
                const SizedBox(height: AppSpacing.lg),
                PrimaryButton(
                    label: 'CREATE PROVIDER ACCOUNT',
                    isLoading: _isLoading,
                    onPressed: _submit),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// REGISTRATION — NGO
// =============================================================================

const _kFoodCategories = [
  'Cooked Meals',
  'Rice',
  'Bread',
  'Fruits',
  'Vegetables',
  'Packaged Food',
  'Bakery',
  'Other'
];

class RegisterNgoScreen extends StatefulWidget {
  const RegisterNgoScreen({super.key});
  @override
  State<RegisterNgoScreen> createState() => _RegisterNgoScreenState();
}

class _RegisterNgoScreenState extends State<RegisterNgoScreen> {
  final _formKey = GlobalKey<FormState>();
  final _ngoName = TextEditingController();
  final _regId = TextEditingController();
  final _contactPerson = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController();
  final _capacity = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final Set<String> _categories = {};
  bool _isLoading = false;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_password.text != _confirmPassword.text) {
      _showSnack('Passwords do not match.', isError: true);
      return;
    }
    if (_categories.isEmpty) {
      _showSnack('Select at least one preferred food category.', isError: true);
      return;
    }
    setState(() => _isLoading = true);
    try {
      await context.read<AppState>().register(
            role: UserRole.ngo,
            email: _email.text,
            password: _password.text,
            fullName: _contactPerson.text.trim(),
            orgLabel: _ngoName.text.trim(),
            phone: _phone.text.trim(),
            roleProfile: {
              'organization_name': _ngoName.text.trim(),
              'registration_number': _regId.text.trim(),
              'address': _address.text.trim(),
              'city': _city.text.trim(),
              'phone': _phone.text.trim(),
              'food_capacity': int.tryParse(_capacity.text.trim()),
              'preferred_food_types': _categories.toList(),
            },
          );
    } on AuthException catch (error) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnack(error.message, isError: true);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _isLoading = false);
    Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const RoleRouter()),
        (route) => false);
  }

  void _showSnack(String msg, {bool isError = false}) {
    final c = AppColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: isError ? c.danger : c.green, content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Register as NGO')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppInputField(
                    label: 'NGO Name',
                    controller: _ngoName,
                    prefixIcon: Icons.apartment_outlined,
                    validator: _req),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Registration / Organization ID',
                    controller: _regId,
                    prefixIcon: Icons.badge_outlined,
                    validator: _req),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Contact Person',
                    controller: _contactPerson,
                    prefixIcon: Icons.person_outline,
                    validator: _req),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Email',
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    prefixIcon: Icons.email_outlined,
                    validator: _emailValidator),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Phone',
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    prefixIcon: Icons.phone_outlined,
                    validator: _phoneValidator),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Address',
                    controller: _address,
                    maxLines: 2,
                    prefixIcon: Icons.location_on_outlined,
                    validator: _req),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'City',
                    controller: _city,
                    prefixIcon: Icons.location_city_outlined,
                    validator: _req),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Capacity Served (people/day)',
                    controller: _capacity,
                    keyboardType: TextInputType.number,
                    prefixIcon: Icons.groups_outlined,
                    validator: _req),
                const SizedBox(height: AppSpacing.md),
                Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Preferred Food Categories',
                        style: Theme.of(context).textTheme.bodyLarge)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _kFoodCategories.map((cat) {
                    final selected = _categories.contains(cat);
                    return FilterChip(
                        label: Text(cat),
                        selected: selected,
                        onSelected: (v) => setState(() => v
                            ? _categories.add(cat)
                            : _categories.remove(cat)));
                  }).toList(),
                ),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Password',
                    controller: _password,
                    obscureText: true,
                    prefixIcon: Icons.lock_outline,
                    validator: _passwordValidator),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Confirm Password',
                    controller: _confirmPassword,
                    obscureText: true,
                    prefixIcon: Icons.lock_outline,
                    validator: _req),
                const SizedBox(height: AppSpacing.lg),
                PrimaryButton(
                    label: 'CREATE NGO ACCOUNT',
                    isLoading: _isLoading,
                    onPressed: _submit),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// REGISTRATION — VOLUNTEER
// =============================================================================

const _kWeekDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

class RegisterVolunteerScreen extends StatefulWidget {
  const RegisterVolunteerScreen({super.key});
  @override
  State<RegisterVolunteerScreen> createState() =>
      _RegisterVolunteerScreenState();
}

class _RegisterVolunteerScreenState extends State<RegisterVolunteerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullName = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _city = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  double _distanceKm = 5;
  final Set<String> _days = {};
  bool _isLoading = false;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_password.text != _confirmPassword.text) {
      _showSnack('Passwords do not match.', isError: true);
      return;
    }
    setState(() => _isLoading = true);
    try {
      await context.read<AppState>().register(
            role: UserRole.volunteer,
            email: _email.text,
            password: _password.text,
            fullName: _fullName.text.trim(),
            orgLabel: _fullName.text.trim(),
            phone: _phone.text.trim(),
            roleProfile: {
              'availability_status': _days.isEmpty ? 'offline' : 'available',
            },
          );
    } on AuthException catch (error) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnack(error.message, isError: true);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _isLoading = false);
    Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const RoleRouter()),
        (route) => false);
  }

  void _showSnack(String msg, {bool isError = false}) {
    final c = AppColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: isError ? c.danger : c.green, content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Register as Volunteer')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppInputField(
                    label: 'Full Name',
                    controller: _fullName,
                    prefixIcon: Icons.person_outline,
                    validator: _req),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Email',
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    prefixIcon: Icons.email_outlined,
                    validator: _emailValidator),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Phone',
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    prefixIcon: Icons.phone_outlined,
                    validator: _phoneValidator),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'City / Area',
                    controller: _city,
                    prefixIcon: Icons.location_city_outlined,
                    validator: _req),
                const SizedBox(height: AppSpacing.md),
                Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                        'Preferred Delivery Distance: ${_distanceKm.round()} km',
                        style: Theme.of(context).textTheme.bodyLarge)),
                Slider(
                    value: _distanceKm,
                    min: 1,
                    max: 20,
                    divisions: 19,
                    label: '${_distanceKm.round()} km',
                    onChanged: (v) => setState(() => _distanceKm = v)),
                const SizedBox(height: AppSpacing.sm),
                Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Availability',
                        style: Theme.of(context).textTheme.bodyLarge)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _kWeekDays.map((d) {
                    final selected = _days.contains(d);
                    return FilterChip(
                        label: Text(d),
                        selected: selected,
                        onSelected: (v) =>
                            setState(() => v ? _days.add(d) : _days.remove(d)));
                  }).toList(),
                ),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Password',
                    controller: _password,
                    obscureText: true,
                    prefixIcon: Icons.lock_outline,
                    validator: _passwordValidator),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Confirm Password',
                    controller: _confirmPassword,
                    obscureText: true,
                    prefixIcon: Icons.lock_outline,
                    validator: _req),
                const SizedBox(height: AppSpacing.lg),
                PrimaryButton(
                    label: 'CREATE VOLUNTEER ACCOUNT',
                    isLoading: _isLoading,
                    onPressed: _submit),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Shared validators for registration forms.
String? _req(String? v) => (v == null || v.trim().isEmpty) ? 'Required' : null;
String? _emailValidator(String? v) =>
    (v == null || !v.contains('@') || !v.contains('.'))
        ? 'Enter a valid email'
        : null;
String? _phoneValidator(String? v) =>
    (v == null || v.trim().length < 10) ? 'Enter a valid phone number' : null;
String? _passwordValidator(String? v) =>
    (v == null || v.length < 6) ? 'Minimum 6 characters' : null;

// =============================================================================
// ROLE ROUTER — sends the signed-in user to the correct dashboard
// =============================================================================

class RoleRouter extends StatelessWidget {
  const RoleRouter({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.isLoggedIn || state.currentRole == null)
      return const WelcomeScreen();
    switch (state.currentRole!) {
      case UserRole.provider:
        return const ProviderDashboardScreen();
      case UserRole.ngo:
        return const NgoDashboardScreen();
      case UserRole.volunteer:
        return const VolunteerDashboardScreen();
      case UserRole.admin:
        return const AdminDashboardScreen();
    }
  }
}

// Shared logout helper used from every dashboard's Profile tab.
Future<void> _logout(BuildContext context) async {
  try {
    await context.read<AppState>().signOut();
  } on AuthException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
    return;
  }
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (route) => false);
}

void _openNotifications(BuildContext context, UserRole role) {
  Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => NotificationsScreen(role: role)));
}

// =============================================================================
// PROVIDER DASHBOARD
// =============================================================================

class ProviderDashboardScreen extends StatefulWidget {
  const ProviderDashboardScreen({super.key});
  @override
  State<ProviderDashboardScreen> createState() =>
      _ProviderDashboardScreenState();
}

class _ProviderDashboardScreenState extends State<ProviderDashboardScreen> {
  int _tab = 0;
  final List<Donation> _donations = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDonations();
  }

  Future<void> _loadDonations() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await context.read<AppState>().api.getDonations();
      final list = [
        for (final item in raw)
          Donation.fromBackend(item is Map<String, dynamic> ? item : {}),
      ];
      if (!mounted) return;
      setState(() {
        _donations
          ..clear()
          ..addAll(list);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _apiErrorMessage(e, fallback: 'Could not load your donations.');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    Widget pageAt(int index, Widget child, {bool needsData = false}) {
      if (needsData) {
        if (_loading && _donations.isEmpty) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (_error != null && _donations.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: const Text('My Donations')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off_outlined,
                        size: 40, color: Theme.of(context).colorScheme.outline),
                    const SizedBox(height: AppSpacing.md),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: AppSpacing.md),
                    TextButton.icon(
                      onPressed: _loadDonations,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
      }
      return child;
    }

    final pages = [
      pageAt(
        0,
        _ProviderHomeTab(
            donations: _donations, onCreateDonation: _createDonation),
      ),
      pageAt(1, _ProviderDonationsTab(donations: _donations)),
      pageAt(
        2,
        _ProviderImpactTab(donations: _donations),
      ),
      NotificationsScreen(role: UserRole.provider, embedded: true),
      ProfileTab(role: UserRole.provider, name: state.currentOrgLabel),
    ];

    return Scaffold(
      body: pages[_tab],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab,
        onTap: (i) => setState(() => _tab = i),
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home),
              label: 'Home'),
          BottomNavigationBarItem(
              icon: Icon(Icons.receipt_long_outlined),
              activeIcon: Icon(Icons.receipt_long),
              label: 'Donations'),
          BottomNavigationBarItem(
              icon: Icon(Icons.emoji_events_outlined),
              activeIcon: Icon(Icons.emoji_events),
              label: 'Impact'),
          BottomNavigationBarItem(
              icon: Icon(Icons.notifications_outlined),
              activeIcon: Icon(Icons.notifications),
              label: 'Alerts'),
          BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: 'Profile'),
        ],
      ),
    );
  }

  Future<void> _createDonation() async {
    final result = await showModalBottomSheet<_NewDonationInput>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CreateDonationSheet(),
    );
    if (result == null || !mounted) return;

    final preparedAt = DateTime.now();
    final expiresAt = preparedAt.add(Duration(hours: result.expiryHours));
    final state = context.read<AppState>();
    try {
      String foodImageUrl;
      try {
        foodImageUrl = await state.api.uploadDonationImage(result.foodPhoto!);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              backgroundColor: AppColors.of(context).danger,
              content: Text(e is ApiException
                  ? _apiErrorMessage(
                      e, fallback: 'Could not upload the food photo. Please try again.')
                  : 'Could not upload the food photo. Please try again.')),
        );
        return;
      }
      final created = await state.api.createDonation({
        'food_name': result.foodName,
        'food_category': result.category,
        'quantity': result.quantityKg,
        'unit': 'kg',
        'servings': result.servings,
        'prepared_at': preparedAt.toUtc().toIso8601String(),
        'expiry_time': expiresAt.toUtc().toIso8601String(),
        'pickup_deadline': expiresAt.toUtc().toIso8601String(),
        'pickup_address': result.pickupAddress,
        'storage_condition': result.storageCondition,
        if (result.foodPreparedKg != null)
          'food_prepared_kg': result.foodPreparedKg,
        if (result.foodSoldKg != null) 'food_sold_kg': result.foodSoldKg,
        'food_image_url': foodImageUrl,
      });
      if (!mounted) return;
      final donation = Donation.fromBackend(created);

      final prediction = created['prediction'];
      if (prediction is Map<String, dynamic> &&
          prediction['status']?.toString() == 'saved') {
        final surplus = prediction['predicted_surplus_kg'];
        state.pushNotification(
          'Surplus Prediction Ready',
          'Predicted surplus for "${donation.foodName}" is '
          '${surplus == null ? '—' : '${(surplus as num).toStringAsFixed(1)} kg'}.',
          NotificationCategory.matching,
        );
      }

      setState(() {
        _donations.insert(0, donation);
        _tab = 1;
      });

      state.pushNotification(
        'Donation Listed',
        '"${donation.foodName}"'
        ' (${donation.quantityKg.toStringAsFixed(0)} kg) passed the food '
        'safety check and is live for nearby NGOs.',
        NotificationCategory.donation,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            backgroundColor: AppColors.of(context).green,
            content: const Text(
                'Food safety check passed. Donation listed as Available.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            backgroundColor: AppColors.of(context).danger,
            content: Text(e is ApiException
                ? _apiErrorMessage(
                    e, fallback: 'Could not create your donation. Please try again.')
                : 'Could not create your donation. Please try again.')),
      );
    }
  }
}

/// Plain data carried back from the Create Donation sheet.
class _NewDonationInput {
  final String foodName;
  final String category;
  final double quantityKg;
  final int servings;
  final int expiryHours;
  final String pickupAddress;
  final String storageCondition; // backend value, not the display label
  final double? foodPreparedKg;
  final double? foodSoldKg;
  final File? foodPhoto;
  const _NewDonationInput({
    required this.foodName,
    required this.category,
    required this.quantityKg,
    required this.servings,
    required this.expiryHours,
    required this.pickupAddress,
    required this.storageCondition,
    this.foodPreparedKg,
    this.foodSoldKg,
    this.foodPhoto,
  });
}

/// Friendly display labels for the backend storage_condition values. The
/// backend AI vocabulary is never exposed to the user.
const _kStorageOptions = [
  _StorageOption('Refrigerated', 'refrigerated'),
  _StorageOption('Frozen', 'frozen'),
  _StorageOption('Room Temperature', 'room_temperature'),
  _StorageOption('Insulated Container', 'insulated_container'),
];

class _StorageOption {
  final String label;
  final String value;
  const _StorageOption(this.label, this.value);
}

/// Lets the provider choose where the required food photo comes from:
/// the device camera or the photo gallery.
Future<ImageSource?> showFoodPhotoSourceSheet(BuildContext context) {
  final c = AppColors.of(context);
  return showModalBottomSheet<ImageSource>(
    context: context,
    backgroundColor: c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: AppSpacing.md),
          Text('Add a food photo',
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: c.textPrimary)),
          const SizedBox(height: 4),
          Text('A photo is required to list a donation.',
              style: TextStyle(fontSize: 12, color: c.textSecondary)),
          const SizedBox(height: AppSpacing.sm),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take Photo'),
            onTap: () => Navigator.of(context).pop(ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from Gallery'),
            onTap: () => Navigator.of(context).pop(ImageSource.gallery),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    ),
  );
}

/// Picks a food photo directly from the given source. Kept separate from the
/// UI so tests can drive the camera through a fake [ImagePickerPlatform].
@visibleForTesting
Future<File?> pickFoodPhoto(ImageSource source) async {
  final picked = await ImagePicker().pickImage(source: source, imageQuality: 80);
  return picked == null ? null : File(picked.path);
}

/// The real Create Donation form — validated fields, no canned data.
/// Presented as a bottom sheet so it feels lightweight from the dashboard.
class _CreateDonationSheet extends StatefulWidget {
  const _CreateDonationSheet();
  @override
  State<_CreateDonationSheet> createState() => _CreateDonationSheetState();
}

class _CreateDonationSheetState extends State<_CreateDonationSheet> {
  final _formKey = GlobalKey<FormState>();
  final _foodNameController = TextEditingController();
  final _quantityController = TextEditingController();
  final _servingsController = TextEditingController();
  final _pickupAddressController = TextEditingController();
  final _preparedKgController = TextEditingController();
  final _soldKgController = TextEditingController();
  String _category = _kFoodCategories.first;
  double _expiryHours = 4;
  String _storageCondition = _kStorageOptions.first.value;
  bool _submitting = false;
  File? _photo;
  String? _photoError;

  @override
  void dispose() {
    _foodNameController.dispose();
    _quantityController.dispose();
    _servingsController.dispose();
    _pickupAddressController.dispose();
    _preparedKgController.dispose();
    _soldKgController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final source = await showFoodPhotoSourceSheet(context);
    if (source == null || !mounted) return;
    try {
      final picked = await pickFoodPhoto(source);
      if (picked == null) return;
      setState(() {
        _photo = picked;
        _photoError = null;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            backgroundColor: AppColors.of(context).danger,
            content: Text(source == ImageSource.camera
                ? 'Could not open the camera.'
                : 'Could not open photo library.')),
      );
    }
  }

  String? _validateBothOrNeither(String? v) {
    final preparedText = _preparedKgController.text.trim();
    final soldText = _soldKgController.text.trim();
    final hasPrepared = preparedText.isNotEmpty;
    final hasSold = soldText.isNotEmpty;
    final valueText = v?.trim() ?? '';
    if (valueText.isNotEmpty) {
      if (double.tryParse(valueText) == null) return 'Enter a number';
      if (double.parse(valueText) < 0) return 'Enter a valid amount';
    }
    if (hasPrepared != hasSold) {
      return 'Optional surplus prediction needs BOTH prepared and sold kg (or leave both empty).';
    }
    if (hasPrepared) {
      final prepared = double.parse(preparedText);
      final sold = double.parse(soldText);
      if (prepared <= 0) return 'Prepared (kg) must be greater than 0';
      if (sold > prepared) {
        return 'Sold (kg) cannot exceed Prepared (kg)';
      }
    }
    return null;
  }

  Future<void> _submit() async {
    final formValid = _formKey.currentState!.validate();
    if (_photo == null) {
      setState(() => _photoError = 'Food image is required.');
      return;
    }
    if (!formValid) return;
    setState(() {
      _photoError = null;
      _submitting = true;
    });
    final prepared = _preparedKgController.text.trim().isEmpty
        ? null
        : double.tryParse(_preparedKgController.text.trim());
    final sold = _soldKgController.text.trim().isEmpty
        ? null
        : double.tryParse(_soldKgController.text.trim());
    if (!mounted) return;
    Navigator.of(context).pop(_NewDonationInput(
      foodName: _foodNameController.text.trim(),
      category: _category,
      quantityKg: double.tryParse(_quantityController.text.trim()) ?? 0,
      servings: int.tryParse(_servingsController.text.trim()) ?? 0,
      expiryHours: _expiryHours.round(),
      pickupAddress: _pickupAddressController.text.trim(),
      storageCondition: _storageCondition,
      foodPreparedKg: prepared,
      foodSoldKg: sold,
      foodPhoto: _photo,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: AppSpacing.md),
                    decoration: BoxDecoration(
                        color: c.border,
                        borderRadius: BorderRadius.circular(4)),
                  ),
                ),
                Text('Create Donation',
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: AppSpacing.xs),
                Text('Fill in the surplus food details below.',
                    style: TextStyle(color: c.textSecondary)),
                const SizedBox(height: AppSpacing.lg),
                AppInputField(
                  label: 'Food Name',
                  controller: _foodNameController,
                  prefixIcon: Icons.fastfood_outlined,
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String>(
                  value: _category,
                  decoration: const InputDecoration(labelText: 'Food Category'),
                  items: _kFoodCategories
                      .map((cat) =>
                          DropdownMenuItem(value: cat, child: Text(cat)))
                      .toList(),
                  onChanged: (v) => setState(() => _category = v ?? _category),
                ),
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String>(
                  value: _storageCondition,
                  decoration: const InputDecoration(
                      labelText: 'Storage Condition', hintText: 'How is it stored?'),
                  items: _kStorageOptions
                      .map((o) =>
                          DropdownMenuItem(value: o.value, child: Text(o.label)))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _storageCondition = v ?? _storageCondition),
                ),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                  label: 'Pickup Address',
                  controller: _pickupAddressController,
                  prefixIcon: Icons.location_on_outlined,
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                Row(children: [
                  Expanded(
                    child: AppInputField(
                      label: 'Quantity (kg)',
                      controller: _quantityController,
                      prefixIcon: Icons.scale_outlined,
                      keyboardType: TextInputType.number,
                      validator: (v) =>
                          (v == null || double.tryParse(v.trim()) == null)
                              ? 'Enter a number'
                              : null,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: AppInputField(
                      label: 'Servings',
                      controller: _servingsController,
                      prefixIcon: Icons.restaurant_outlined,
                      keyboardType: TextInputType.number,
                      validator: (v) =>
                          (v == null || int.tryParse(v.trim()) == null)
                              ? 'Enter a number'
                              : null,
                    ),
                  ),
                ]),
                const SizedBox(height: AppSpacing.sm),
                Text('Safe to consume for: ${_expiryHours.round()} hours',
                    style: TextStyle(color: c.textSecondary)),
                Slider(
                  value: _expiryHours,
                  min: 1,
                  max: 12,
                  divisions: 11,
                  label: '${_expiryHours.round()}h',
                  onChanged: (v) => setState(() => _expiryHours = v),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Optional — surplus prediction',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: c.textSecondary,
                      fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  'Fill BOTH the kg you prepared and the kg you sold today to '
                  'get an AI surplus prediction. Leave both empty to skip.',
                  style: TextStyle(fontSize: 12, color: c.textSecondary),
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(children: [
                  Expanded(
                    child: AppInputField(
                      label: 'Prepared (kg)',
                      controller: _preparedKgController,
                      prefixIcon: Icons.kitchen_outlined,
                      keyboardType: TextInputType.number,
                      validator: _validateBothOrNeither,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: AppInputField(
                      label: 'Sold (kg)',
                      controller: _soldKgController,
                      prefixIcon: Icons.point_of_sale_outlined,
                      keyboardType: TextInputType.number,
                      validator: _validateBothOrNeither,
                    ),
                  ),
                ]),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'Food photo — required',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: c.textSecondary,
                      fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  'Take a photo or choose one so NGOs can see what is available.',
                  style: TextStyle(fontSize: 12, color: c.textSecondary),
                ),
                const SizedBox(height: AppSpacing.sm),
                InkWell(
                  onTap: _pickPhoto,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: c.border,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _photo == null
                        ? Row(children: [
                            Icon(Icons.add_a_photo_outlined,
                                color: c.textSecondary),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text('Tap to choose or take a photo',
                                  style: TextStyle(color: c.textSecondary)),
                            ),
                          ])
                        : Row(children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                _photo!,
                                width: 56,
                                height: 56,
                                fit: BoxFit.cover,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(_photo!.path.split('/').last,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: c.textSecondary)),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(() {
                                _photo = null;
                                _photoError = 'Food image is required.';
                              }),
                              tooltip: 'Remove photo',
                            ),
                          ]),
                  ),
                ),
                if (_photoError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _photoError!,
                    style: TextStyle(fontSize: 12, color: c.danger),
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
                PrimaryButton(
                    label: 'CREATE DONATION',
                    isLoading: _submitting,
                    onPressed: _submit),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProviderHomeTab extends StatelessWidget {
  final List<Donation> donations;
  final VoidCallback onCreateDonation;
  const _ProviderHomeTab(
      {required this.donations, required this.onCreateDonation});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final active = donations
        .where((d) =>
            d.status != DonationStatus.delivered &&
            d.status != DonationStatus.expired)
        .length;
    final totalKg = donations.fold<double>(0, (sum, d) => sum + d.quantityKg);
    final meals = donations.fold<int>(0, (sum, d) => sum + d.servings);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: DashboardHeader(
            greeting: 'Good Evening, ${state.currentOrgLabel} 👋',
            subtitle: 'Here is what\'s happening with your donations today.',
            roleLabel: 'FOOD PROVIDER',
            onNotificationTap: () =>
                _openNotifications(context, UserRole.provider),
            onProfileTap: () {},
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Row(children: [
                Expanded(
                    child: StatCard(
                        label: 'Food Donated',
                        value: '${totalKg.toStringAsFixed(0)} kg',
                        icon: Icons.scale_outlined,
                        emphasis: Emphasis.strong)),
                const SizedBox(width: 10),
                Expanded(
                    child: StatCard(
                        label: 'Active Donations',
                        value: '$active',
                        icon: Icons.receipt_long_outlined,
                        emphasis: Emphasis.primary)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: StatCard(
                        label: 'Meals Supported',
                        value: '$meals',
                        icon: Icons.restaurant_outlined)),
                const SizedBox(width: 10),
                Expanded(
                    child: StatCard(
                        label: 'Impact Points',
                        value: '0',
                        icon: Icons.workspace_premium_outlined)),
              ]),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                  label: '+ CREATE NEW DONATION',
                  icon: Icons.add,
                  onPressed: onCreateDonation),
              const SizedBox(height: AppSpacing.lg),
              const SurplusPredictionCard(),
              const SizedBox(height: AppSpacing.lg),
              const SectionHeader(title: 'Recent Donations'),
              const SizedBox(height: 10),
              ...donations.take(3).map((d) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: DonationCard(donation: d))),
            ]),
          ),
        ),
      ],
    );
  }
}

class _ProviderDonationsTab extends StatelessWidget {
  final List<Donation> donations;
  const _ProviderDonationsTab({required this.donations});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text('My Donations'),
          actions: const [ThemeToggleButton()]),
      body: donations.isEmpty
          ? const EmptyState(
              icon: Icons.inbox_outlined,
              message:
                  'No donations yet. Create your first donation from Home.')
          : ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.lg),
              itemCount: donations.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final donation = donations[i];
                final available = donation.status != DonationStatus.delivered &&
                    donation.status != DonationStatus.expired;
                return DonationCard(
                  donation: donation,
                  trailingAction: available
                      ? Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: _DonationAiActions(donation: donation),
                        )
                      : null,
                );
              },
            ),
    );
  }
}

/// AI actions available on a provider-owned donation: NGO matching and the
/// escalation check (an on-demand trigger; a background scheduler is a
/// deployment-level task). All calls go through the Main backend, so the AI
/// service is never reached directly from Flutter.
class _DonationAiActions extends StatefulWidget {
  final Donation donation;
  const _DonationAiActions({required this.donation});

  @override
  State<_DonationAiActions> createState() => _DonationAiActionsState();
}

class _DonationAiActionsState extends State<_DonationAiActions> {
  bool _matching = false;
  bool _escalating = false;
  bool _generating = false;

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _matchNgos() async {
    setState(() => _matching = true);
    try {
      final result =
          await context.read<AppState>().api.matchDonation(widget.donation.id);
      if (!mounted) return;
      final status = result['status']?.toString();
      final reason = result['reason']?.toString();
      if (status == 'ok') {
        final ranked = result['ranked_ngos'] as List? ?? [];
        await _showRankedNgos(ranked);
      } else {
        _snack(reason ??
            'Matching is not possible yet for this donation.');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      _snack(_aiFeatureErrorMessage(e,
          fallback: 'NGO matching is temporarily unavailable.'));
    } finally {
      if (mounted) setState(() => _matching = false);
    }
  }

  Future<void> _showRankedNgos(List<dynamic> ranked) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final c = AppColors.of(ctx);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.62,
          maxChildSize: 0.9,
          builder: (_, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              const Text('AI-Recommended NGOs',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 4),
              Text('Ranked by the SAHAAY AI matching engine.',
                  style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
              const SizedBox(height: 14),
              if (ranked.isEmpty)
                Text('No NGO rankings were returned.',
                    style: TextStyle(color: c.textSecondary))
              else
                for (final item in ranked)
                  if (item is Map<String, dynamic>) ...[
                    _RankedNgoTile(item: item),
                    const SizedBox(height: 8),
                  ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _checkEscalation() async {
    setState(() => _escalating = true);
    try {
      final result = await context
          .read<AppState>()
          .api
          .checkEscalation(widget.donation.id);
      if (!mounted) return;
      final action = result['action']?.toString() ?? 'checked';
      final message = result['message']?.toString();
      switch (action) {
        case 'keep_waiting':
          _snack(message ?? 'Still waiting on the current NGO response.');
        case 'escalate':
          _snack(message ?? 'Offer escalated to the next-ranked NGO.');
        case 'accepted':
          _snack(message ?? 'This donation has been accepted.');
        case 'no_ngos_left':
          _snack(message ?? 'No more NGOs to escalate to.');
        case 'no_claims':
          _snack(message ?? 'No NGO claims yet — nothing to escalate.');
        default:
          _snack(message ?? 'Escalation check completed.');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      _snack(_aiFeatureErrorMessage(e,
          fallback: 'Escalation check is temporarily unavailable.'));
    } finally {
      if (mounted) setState(() => _escalating = false);
    }
  }

  Future<void> _generateAcknowledgment() async {
    setState(() => _generating = true);
    try {
      final bytes = await context
          .read<AppState>()
          .api
          .generateAcknowledgment(widget.donation.id);
      if (!mounted) return;
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
          '${dir.path}/sahaay_ack_${widget.donation.id}.pdf');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      _snack('Acknowledgment PDF saved to:\n${file.path}');
    } on ApiException catch (e) {
      if (!mounted) return;
      _snack(_aiFeatureErrorMessage(e,
          fallback: 'Acknowledgment generation is temporarily unavailable.'));
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final completed = widget.donation.status == DonationStatus.delivered;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        SizedBox(
          height: 34,
          child: OutlinedButton.icon(
            onPressed: _matching ? null : _matchNgos,
            icon: _matching
                ? const SizedBox(
                    height: 12,
                    width: 12,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.hub_outlined, size: 16),
            label: const Text('Matched NGOs',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ),
        if (!completed)
          SizedBox(
            height: 34,
            child: OutlinedButton.icon(
              onPressed: _escalating ? null : _checkEscalation,
              icon: _escalating
                  ? const SizedBox(
                      height: 12,
                      width: 12,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.timelapse_outlined, size: 16),
              label: const Text('Check Escalation',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ),
        if (completed)
          SizedBox(
            height: 34,
            child: OutlinedButton.icon(
              onPressed: _generating ? null : _generateAcknowledgment,
              icon: _generating
                  ? const SizedBox(
                      height: 12,
                      width: 12,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.picture_as_pdf_outlined, size: 16),
              label: const Text('Acknowledgment PDF',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ),
      ],
    );
  }
}

class _RankedNgoTile extends StatelessWidget {
  final Map<String, dynamic> item;
  const _RankedNgoTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final distance = item['distance_km'];
    final finalScore = item['final_score'];
    final rank = item['rank'];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item['ngo_name']?.toString() ?? 'NGO',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 13.5)),
                  const SizedBox(height: 4),
                  Text(
                    distance is num
                        ? '${distance.toStringAsFixed(1)} km away'
                        : 'Distance unknown',
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  finalScore is num
                      ? finalScore.toStringAsFixed(1)
                      : '—',
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 19,
                      color: c.bluePrimary),
                ),
                Text(rank is int ? 'Rank #${rank + 1}' : 'AI score',
                    style:
                        TextStyle(fontSize: 10.5, color: c.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProviderImpactTab extends StatefulWidget {
  final List<Donation> donations;
  const _ProviderImpactTab({required this.donations});

  @override
  State<_ProviderImpactTab> createState() => _ProviderImpactTabState();
}

class _ProviderImpactTabState extends State<_ProviderImpactTab> {
  Map<String, dynamic>? _reliability;
  bool _reliabilityLoading = true;
  String? _reliabilityError;

  @override
  void initState() {
    super.initState();
    _loadReliability();
  }

  Future<void> _loadReliability() async {
    setState(() {
      _reliabilityLoading = true;
      _reliabilityError = null;
    });
    try {
      final data = await context.read<AppState>().api.getReliability();
      if (!mounted) return;
      setState(() {
        _reliability = data;
        _reliabilityLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _reliabilityError = _aiFeatureErrorMessage(e,
            fallback: 'Could not load your reliability score right now.');
        _reliabilityLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final donations = widget.donations;
    final totalKg = donations.fold<double>(0, (sum, d) => sum + d.quantityKg);
    final meals = donations.fold<int>(0, (sum, d) => sum + d.servings);
    final completed =
        donations.where((d) => d.status == DonationStatus.delivered).length;

    final rawScore = _reliability?['reliability_score'];
    final scoreText = rawScore is num ? rawScore.toStringAsFixed(0) : '—';
    final grade = _reliability?['grade']?.toString() ?? '';

    return Scaffold(
      appBar: AppBar(
          title: const Text('Impact & Rewards'),
          actions: const [ThemeToggleButton()]),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 2.4,
            children: [
              ImpactCard(
                  emoji: '🌱',
                  value: '${totalKg.toStringAsFixed(0)} kg',
                  label: 'Food Saved'),
              ImpactCard(
                  emoji: '🍱', value: '$meals', label: 'Meals Supported'),
              ImpactCard(
                  emoji: '💙',
                  value: '$completed',
                  label: 'Donations Completed'),
              const ImpactCard(emoji: '⭐', value: '—', label: 'NGO Rating'),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          RewardCard(
            impactPoints: 0,
            levelLabel: 'NEW PROVIDER',
            badges: MockData.providerBadges(),
            statLines: [
              _StatLine(label: 'Reliability Score', value: scoreText),
              _StatLine(label: 'Donations Completed', value: '$completed'),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _ReliabilityStatusCard(
            loading: _reliabilityLoading,
            score: rawScore,
            grade: grade,
            error: _reliabilityError,
            onRetry: _loadReliability,
          ),
          const SizedBox(height: AppSpacing.lg),
          SecondaryButton(
            label: 'View Public Impact Leaderboard',
            icon: Icons.leaderboard_outlined,
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LeaderboardScreen())),
          ),
        ],
      ),
    );
  }
}

/// Honest AI-status strip for the provider's reliability score. Shows whatever
/// is actually known: the AI-computed score, or a clear reason it is missing.
class _ReliabilityStatusCard extends StatelessWidget {
  final bool loading;
  final Object? score;
  final String grade;
  final String? error;
  final VoidCallback onRetry;
  const _ReliabilityStatusCard({
    required this.loading,
    required this.score,
    required this.grade,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final Widget payload;
    if (loading) {
      payload = const Row(children: [
        SizedBox(
            height: 16,
            width: 16,
            child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 10),
        Text('Calculating your reliability score…',
            style: TextStyle(fontSize: 12.5)),
      ]);
    } else if (error != null) {
      payload = Row(children: [
        Icon(Icons.cloud_off_outlined, size: 16, color: c.textSecondary),
        const SizedBox(width: 8),
        Expanded(
            child: Text('AI reliability: $error',
                style: TextStyle(fontSize: 12.5, color: c.textSecondary))),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ]);
    } else {
      final scoreValue = score is num ? (score as num).toStringAsFixed(0) : '—';
      payload = Row(children: [
        Icon(Icons.verified_outlined, size: 16, color: c.bluePrimary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            grade.isNotEmpty && score is num
                ? 'AI-computed provider reliability: $scoreValue/100  •  $grade'
                : 'Your reliability score will appear here once you have donation history.',
            style: TextStyle(fontSize: 12.5, color: c.textSecondary),
          ),
        ),
      ]);
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: payload,
      ),
    );
  }
}

class _StatLine extends StatelessWidget {
  final String label;
  final String value;
  const _StatLine({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: TextStyle(color: c.textSecondary, fontSize: 13)),
        Text(value,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
      ]),
    );
  }
}

// =============================================================================
// NGO DASHBOARD
// =============================================================================

class NgoDashboardScreen extends StatefulWidget {
  const NgoDashboardScreen({super.key});
  @override
  State<NgoDashboardScreen> createState() => _NgoDashboardScreenState();
}

class _NgoDashboardScreenState extends State<NgoDashboardScreen> {
  int _tab = 0;
  final List<Donation> _nearby = [];
  final List<Donation> _claimed = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadNearby();
  }

  Future<void> _loadNearby() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await context.read<AppState>().api.getDonations();
      final list = [
        for (final item in raw)
          Donation.fromBackend(item is Map<String, dynamic> ? item : {}),
      ];
      if (!mounted) return;
      setState(() {
        _nearby
          ..clear()
          ..addAll(list);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _apiErrorMessage(e, fallback: 'Could not load nearby donations.');
        _loading = false;
      });
    }
  }

  Future<void> _claim(Donation d) async {
    await context.read<AppState>().api.createClaim({
      'donation_id': d.id,
      'requested_quantity': d.quantityKg,
      'notes': null,
    });
    if (!mounted) return;
    setState(() {
      d.status = DonationStatus.claimed;
      _claimed.add(d);
    });
    context.read<AppState>().pushNotification(
          'Donation Claimed',
          'You claimed "${d.foodName}"'
          ' (${d.quantityKg.toStringAsFixed(0)} kg) from ${d.providerLabel}.',
          NotificationCategory.donation,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    Widget pageAt(int index, Widget child) {
      if (_loading && _nearby.isEmpty) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (_error != null && _nearby.isEmpty) {
        return Scaffold(
          appBar: AppBar(title: const Text('Find Food')),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off_outlined,
                      size: 40, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: AppSpacing.md),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: AppSpacing.md),
                  TextButton.icon(
                    onPressed: _loadNearby,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      return child;
    }

    final pages = [
      pageAt(0, _NgoHomeTab(nearby: _nearby, claimed: _claimed, onClaim: _claim)),
      pageAt(1, _NgoFindFoodTab(nearby: _nearby, onClaim: _claim)),
      pageAt(2, _NgoClaimsTab(claimed: _claimed)),
      pageAt(3, _NgoImpactTab(claimed: _claimed)),
      ProfileTab(role: UserRole.ngo, name: state.currentOrgLabel),
    ];
    return Scaffold(
      body: pages[_tab],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab,
        onTap: (i) => setState(() => _tab = i),
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home),
              label: 'Home'),
          BottomNavigationBarItem(
              icon: Icon(Icons.search_outlined),
              activeIcon: Icon(Icons.search),
              label: 'Find Food'),
          BottomNavigationBarItem(
              icon: Icon(Icons.assignment_turned_in_outlined),
              activeIcon: Icon(Icons.assignment_turned_in),
              label: 'Claims'),
          BottomNavigationBarItem(
              icon: Icon(Icons.emoji_events_outlined),
              activeIcon: Icon(Icons.emoji_events),
              label: 'Impact'),
          BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: 'Profile'),
        ],
      ),
    );
  }
}

class _NgoHomeTab extends StatelessWidget {
  final List<Donation> nearby;
  final List<Donation> claimed;
  final Future<void> Function(Donation) onClaim;
  const _NgoHomeTab(
      {required this.nearby, required this.claimed, required this.onClaim});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final available =
        nearby.where((d) => d.status == DonationStatus.available).toList();
    final foodReceivedKg =
        claimed.fold<double>(0, (sum, d) => sum + d.quantityKg);
    final peopleServed = claimed.fold<int>(0, (sum, d) => sum + d.servings);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: DashboardHeader(
            greeting: 'Welcome, ${state.currentOrgLabel} 👋',
            subtitle: 'Pune, Maharashtra',
            roleLabel: 'NGO',
            onNotificationTap: () => _openNotifications(context, UserRole.ngo),
            onProfileTap: () {},
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Row(children: [
                Expanded(
                    child: StatCard(
                        label: 'Available Donations',
                        value: '${available.length}',
                        icon: Icons.inventory_2_outlined,
                        emphasis: Emphasis.strong)),
                const SizedBox(width: 10),
                Expanded(
                    child: StatCard(
                        label: 'Active Claims',
                        value: '${claimed.length}',
                        icon: Icons.assignment_turned_in_outlined,
                        emphasis: Emphasis.primary)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: StatCard(
                        label: 'Food Received',
                        value: '${foodReceivedKg.toStringAsFixed(0)} kg',
                        icon: Icons.local_shipping_outlined)),
                const SizedBox(width: 10),
                Expanded(
                    child: StatCard(
                        label: 'People Served',
                        value: '$peopleServed',
                        icon: Icons.groups_outlined)),
              ]),
              const SizedBox(height: AppSpacing.lg),
              const SectionHeader(title: 'Food Available Near You'),
              const SizedBox(height: 10),
              const MapPlaceholder(),
              const SizedBox(height: AppSpacing.lg),
              if (available.isNotEmpty)
                MatchScoreCard(donation: available.first),
              const SizedBox(height: AppSpacing.lg),
              ...available.take(2).map((d) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: DonationCard(
                      donation: d,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => DonationDetailScreen(
                              donation: d, onClaim: onClaim))),
                      trailingAction: Row(children: [
                        Expanded(
                            child: SecondaryButton(
                                label: 'VIEW',
                                onPressed: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                        builder: (_) => DonationDetailScreen(
                                            donation: d, onClaim: onClaim))))),
                        const SizedBox(width: 8),
                        Expanded(
                            child: PrimaryButton(
                                label: 'CLAIM',
                                onPressed: () async {
                                  if (await _claimDonation(context, d)) {
                                    if (!context.mounted) return;
                                    Navigator.of(context).push(MaterialPageRoute(
                                        builder: (_) => ClaimedDonationDashboard(
                                            donation: d)));
                                  }
                                })),
                      ]),
                    ),
                  )),
            ]),
          ),
        ),
      ],
    );
  }

  /// Confirms with the user, performs the real backend claim, and only
  /// reports success once the claim was actually created. Returns true when
  /// the caller should proceed to the claimed-donation screen.
  Future<bool> _claimDonation(BuildContext context, Donation d) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Claim'),
        content: Text(
            'Claim "${d.foodName}"'
            ' (${d.quantityKg.toStringAsFixed(0)} kg) from ${d.providerLabel}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return false;
    try {
      await onClaim(d);
    } on ApiException catch (e) {
      if (!context.mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            backgroundColor: AppColors.of(context).danger,
            content: Text(_apiErrorMessage(
                e, fallback: 'Could not claim this donation. Please try again.'))),
      );
      return false;
    }
    return true;
  }
}

class _NgoFindFoodTab extends StatefulWidget {
  final List<Donation> nearby;
  final Future<void> Function(Donation) onClaim;
  const _NgoFindFoodTab({required this.nearby, required this.onClaim});

  @override
  State<_NgoFindFoodTab> createState() => _NgoFindFoodTabState();
}

class _NgoFindFoodTabState extends State<_NgoFindFoodTab> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final results = q.isEmpty
        ? widget.nearby
        : widget.nearby.where((d) {
            return d.foodName.toLowerCase().contains(q) ||
                d.providerName.toLowerCase().contains(q) ||
                d.category.toLowerCase().contains(q);
          }).toList();

    return Scaffold(
      appBar: AppBar(
          title: const Text('Find Food'), actions: const [ThemeToggleButton()]),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
            child: AppInputField(
              label: 'Search food, restaurant or category',
              controller: _searchController,
              prefixIcon: Icons.search,
              onChanged: (v) => setState(() => _query = v),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
          ),
          Expanded(
            child: widget.nearby.isEmpty
                ? const EmptyState(
                    icon: Icons.search_off_outlined,
                    message: 'No nearby donations found.')
                : results.isEmpty
                    ? EmptyState(
                        icon: Icons.search_off_outlined,
                        message: 'No results for "$_query".')
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(
                            AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
                        itemCount: results.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          final d = results[i];
                          return DonationCard(
                            donation: d,
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => DonationDetailScreen(
                                        donation: d, onClaim: widget.onClaim))),
                          );
                        },
                      ),
          ),
        ],
      ),
      // Search re-runs on every keystroke via onChanged below.
    );
  }
}

class _NgoClaimsTab extends StatelessWidget {
  final List<Donation> claimed;
  const _NgoClaimsTab({required this.claimed});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text('My Claims'), actions: const [ThemeToggleButton()]),
      body: claimed.isEmpty
          ? const EmptyState(
              icon: Icons.assignment_outlined,
              message: 'No active claims yet. Claim a donation from Find Food.')
          : ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.lg),
              itemCount: claimed.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) => _ClaimSummaryCard(
                donation: claimed[i],
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        ClaimedDonationDashboard(donation: claimed[i]))),
              ),
            ),
    );
  }
}

/// A center-aligned presentation of a claimed donation, used only in My
/// Claims. Kept as its own widget (rather than editing the shared
/// DonationCard) so Provider's My Donations and NGO's Find Food screens
/// are completely unaffected.
class _ClaimSummaryCard extends StatelessWidget {
  final Donation donation;
  final VoidCallback onTap;
  const _ClaimSummaryCard({required this.donation, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(donation.foodName,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              StatusChip(
                  label: donationStatusLabel(donation.status),
                  color: donationStatusColor(donation.status, context)),
              const SizedBox(height: 6),
              if (donation.providerName.isNotEmpty)
                Text(donation.providerName,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.textSecondary, fontSize: 12.5)),
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 14,
                runSpacing: 6,
                children: [
                  _mini(context, Icons.scale_outlined,
                      '${donation.quantityKg.toStringAsFixed(0)} kg • ${donation.servings} servings'),
                  _mini(context, Icons.schedule_outlined, donation.expiryLabel),
                ],
              ),
              const SizedBox(height: 10),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.chevron_right, size: 16, color: c.textSecondary),
                Text('View claim details',
                    style: TextStyle(fontSize: 12, color: c.textSecondary)),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mini(BuildContext context, IconData icon, String text) {
    final c = AppColors.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: c.textSecondary),
      const SizedBox(width: 4),
      Text(text, style: TextStyle(fontSize: 12, color: c.textSecondary)),
    ]);
  }
}

class _NgoImpactTab extends StatelessWidget {
  final List<Donation> claimed;
  const _NgoImpactTab({required this.claimed});

  @override
  Widget build(BuildContext context) {
    final peopleServed = claimed.fold<int>(0, (sum, d) => sum + d.servings);
    final foodReceivedKg =
        claimed.fold<double>(0, (sum, d) => sum + d.quantityKg);

    return Scaffold(
      appBar: AppBar(
          title: const Text('Impact'), actions: const [ThemeToggleButton()]),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 2.4,
            children: [
              ImpactCard(
                  emoji: '🍱', value: '$peopleServed', label: 'People Served'),
              ImpactCard(
                  emoji: '📦',
                  value: '${foodReceivedKg.toStringAsFixed(0)} kg',
                  label: 'Food Received'),
              ImpactCard(
                  emoji: '✅',
                  value: '${claimed.length}',
                  label: 'Claims Completed'),
              const ImpactCard(
                  emoji: '⭐', value: '—', label: 'Provider Rating'),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SecondaryButton(
            label: 'View Public Impact Leaderboard',
            icon: Icons.leaderboard_outlined,
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LeaderboardScreen())),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// DONATION DETAIL (NGO claim flow: View -> Details -> Claim -> Confirmation)
// =============================================================================

class DonationDetailScreen extends StatelessWidget {
  final Donation donation;
  final Future<void> Function(Donation) onClaim;
  const DonationDetailScreen(
      {super.key, required this.donation, required this.onClaim});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isAvailable = donation.status == DonationStatus.available;
    return Scaffold(
      appBar: AppBar(title: const Text('Donation Details')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                  child: Text(donation.foodName,
                      style: Theme.of(context).textTheme.headlineSmall)),
              StatusChip(
                  label: donationStatusLabel(donation.status),
                  color: donationStatusColor(donation.status, context)),
            ]),
            const SizedBox(height: 4),
            if (donation.providerName.isNotEmpty)
              Text(donation.providerName,
                  style: TextStyle(color: c.textSecondary)),
            const SizedBox(height: AppSpacing.lg),
            const MapPlaceholder(height: 140),
            const SizedBox(height: AppSpacing.lg),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(children: [
                  _detailRow(context, Icons.category_outlined, 'Category',
                      donation.category),
                  _detailRow(context, Icons.scale_outlined, 'Quantity',
                      '${donation.quantityKg.toStringAsFixed(0)} kg'),
                  _detailRow(context, Icons.groups_outlined, 'Servings',
                      '${donation.servings}'),
                  if (donation.distanceKm > 0)
                    _detailRow(context, Icons.near_me_outlined, 'Distance',
                        '${donation.distanceKm.toStringAsFixed(1)} km'),
                  if (donation.expiryLabel.isNotEmpty)
                    _detailRow(context, Icons.schedule_outlined, 'Deadline',
                        donation.expiryLabel),
                  _detailRow(context, Icons.eco_outlined, 'Freshness',
                      donation.freshnessLabel),
                  if (donation.providerAddress != null &&
                      donation.providerAddress!.isNotEmpty)
                    _detailRow(context, Icons.location_on_outlined,
                        'Pickup Address', donation.providerAddress!),
                ]),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            MatchScoreCard(donation: donation),
            const SizedBox(height: AppSpacing.lg),
            if (isAvailable)
              PrimaryButton(
                label: 'CLAIM DONATION',
                onPressed: () async {
                  try {
                    await onClaim(donation);
                  } on ApiException catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          backgroundColor: AppColors.of(context).danger,
                          content: Text(_apiErrorMessage(e,
                              fallback: 'Could not claim this donation. Please try again.'))),
                    );
                    return;
                  }
                  if (!context.mounted) return;
                  Navigator.of(context).pushReplacement(MaterialPageRoute(
                      builder: (_) =>
                          ClaimedDonationDashboard(donation: donation)));
                },
              )
            else
              const StatusChip(label: 'Already claimed', color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(
      BuildContext context, IconData icon, String label, String value) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 18, color: c.textSecondary),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: TextStyle(color: c.textSecondary))),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

// =============================================================================
// POST-CLAIM DASHBOARD — shown once an NGO claims a donation. Covers GPS
// location, restaurant info, optional volunteer info, OTP handover
// verification, and a handover photo. Every field falls back to an honest
// "not provided yet" state rather than any invented value (Section 8/10).
// =============================================================================

class ClaimedDonationDashboard extends StatefulWidget {
  final Donation donation;
  const ClaimedDonationDashboard({super.key, required this.donation});

  @override
  State<ClaimedDonationDashboard> createState() =>
      _ClaimedDonationDashboardState();
}

class _ClaimedDonationDashboardState extends State<ClaimedDonationDashboard> {
  // A locally-generated handover code, standing in for a real SMS/OTP
  // gateway until the backend is connected. Regenerated once per screen visit.
  late final String _otp = (1000 + Random().nextInt(9000)).toString();
  final _otpInputController = TextEditingController();
  String? _otpError;
  bool _handoverVerified = false;
  File? _photo;

  @override
  void dispose() {
    _otpInputController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final picked = await ImagePicker()
          .pickImage(source: ImageSource.gallery, imageQuality: 80);
      if (picked == null) return;
      setState(() => _photo = File(picked.path));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            backgroundColor: AppColors.of(context).danger,
            content: const Text('Could not open photo library.')),
      );
    }
  }

  void _verifyOtp() {
    if (_otpInputController.text.trim() == _otp) {
      setState(() {
        _handoverVerified = true;
        _otpError = null;
      });
    } else {
      setState(() =>
          _otpError = 'That code doesn\'t match. Please check and try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.donation;
    final c = AppColors.of(context);
    final hasVolunteer = d.volunteerName != null && d.volunteerName!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Claimed Donation')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                  child: Text(d.foodName,
                      style: Theme.of(context).textTheme.headlineSmall)),
              StatusChip(
                  label: donationStatusLabel(d.status),
                  color: donationStatusColor(d.status, context)),
            ]),
            const SizedBox(height: 4),
            Text(
                '${d.quantityKg.toStringAsFixed(0)} kg • ${d.servings} servings',
                style: TextStyle(color: c.textSecondary)),
            const SizedBox(height: AppSpacing.lg),
            const SectionHeader(title: 'Location'),
            const SizedBox(height: 10),
            const MapPlaceholder(height: 150),
            const SizedBox(height: AppSpacing.lg),
            const SectionHeader(title: 'Restaurant Information'),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(children: [
                  _row(context, Icons.storefront_outlined, 'Name',
                      d.providerName),
                  _row(context, Icons.location_on_outlined, 'Address',
                      d.providerAddress ?? 'Not provided yet'),
                  _row(context, Icons.call_outlined, 'Contact',
                      d.providerContactNumber ?? 'Not available yet'),
                  _row(
                    context,
                    Icons.star_outline,
                    'Rating',
                    d.providerRating != null
                        ? '${d.providerRating!.toStringAsFixed(1)} / 5 (${d.providerReviewCount ?? 0} reviews)'
                        : 'No reviews yet',
                  ),
                ]),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            const SectionHeader(title: 'Volunteer'),
            const SizedBox(height: 10),
            if (hasVolunteer)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(children: [
                    _row(context, Icons.person_outline, 'Name',
                        d.volunteerName!),
                    _row(context, Icons.call_outlined, 'Contact',
                        d.volunteerPhone ?? 'Not available yet'),
                    _row(context, Icons.local_shipping_outlined, 'Status',
                        d.volunteerStatus ?? 'Assigned'),
                  ]),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 18, color: c.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No volunteer assigned. Volunteering is optional — this donation can proceed to handover without one.',
                      style: TextStyle(fontSize: 12, color: c.textSecondary),
                    ),
                  ),
                ]),
              ),
            const SizedBox(height: AppSpacing.lg),
            const SectionHeader(title: 'Handover Verification'),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: _handoverVerified
                    ? Row(children: [
                        Icon(Icons.check_circle, color: c.green),
                        const SizedBox(width: 8),
                        const Expanded(
                            child: Text('Handover verified successfully.')),
                      ])
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Share this code with the NGO representative at pickup to confirm handover.',
                            style: TextStyle(
                                fontSize: 12.5, color: c.textSecondary),
                          ),
                          const SizedBox(height: 10),
                          Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(
                                  color: c.surfaceAlt,
                                  borderRadius: BorderRadius.circular(12)),
                              child: Text(_otp,
                                  style: const TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 6)),
                            ),
                          ),
                          const SizedBox(height: 14),
                          AppInputField(
                            label: 'Enter handover code',
                            controller: _otpInputController,
                            keyboardType: TextInputType.number,
                            prefixIcon: Icons.password_outlined,
                            helperText: _otpError,
                          ),
                          const SizedBox(height: 12),
                          PrimaryButton(
                              label: 'VERIFY & CONFIRM HANDOVER',
                              onPressed: _verifyOtp),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            const SectionHeader(title: 'Handover Photo'),
            const SizedBox(height: 10),
            if (_photo != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: Image.file(_photo!,
                    height: 180, width: double.infinity, fit: BoxFit.cover),
              )
            else
              Container(
                height: 120,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  border: Border.all(color: c.border),
                ),
                child: Center(
                    child: Icon(Icons.photo_camera_outlined,
                        size: 32, color: c.textSecondary.withOpacity(0.6))),
              ),
            const SizedBox(height: 10),
            SecondaryButton(
              label: _photo == null ? 'ADD HANDOVER PHOTO' : 'REPLACE PHOTO',
              icon: Icons.add_a_photo_outlined,
              onPressed: _pickPhoto,
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, String label, String value) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 18, color: c.textSecondary),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: TextStyle(color: c.textSecondary))),
        Flexible(
            child: Text(value,
                style: const TextStyle(fontWeight: FontWeight.w700),
                textAlign: TextAlign.right)),
      ]),
    );
  }
}

// =============================================================================
// VOLUNTEER DASHBOARD
// =============================================================================

class VolunteerDashboardScreen extends StatefulWidget {
  const VolunteerDashboardScreen({super.key});
  @override
  State<VolunteerDashboardScreen> createState() =>
      _VolunteerDashboardScreenState();
}

class _VolunteerDashboardScreenState extends State<VolunteerDashboardScreen> {
  int _tab = 0;
  // Available-to-accept opportunities are intentionally left empty: there is
  // no backend endpoint yet for a volunteer to self-assign a delivery, so we
  // show an honest empty state instead of inventing one.
  late final List<DeliveryOpportunity> _opportunities =
      MockData.deliveryOpportunities();
  final List<DeliveryOpportunity> _myDeliveries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDeliveries();
  }

  Future<void> _loadDeliveries() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await context.read<AppState>().api.getDeliveries();
      final list = [
        for (final item in raw)
          DeliveryOpportunity.fromBackend(item is Map<String, dynamic> ? item : {}),
      ];
      if (!mounted) return;
      setState(() {
        _myDeliveries
          ..clear()
          ..addAll(list);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _apiErrorMessage(e, fallback: 'Could not load your deliveries.');
        _loading = false;
      });
    }
  }

  void _accept(DeliveryOpportunity d) {
    setState(() {
      d.status = DeliveryStatus.accepted;
      _myDeliveries.add(d);
    });
    context.read<AppState>().pushNotification(
          'Delivery Accepted',
          'You accepted delivery of "${d.foodName}" from ${d.providerName} to ${d.ngoName}.',
          NotificationCategory.volunteer,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    Widget pageAt(int index, Widget child) {
      if (_loading && _myDeliveries.isEmpty) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (_error != null && _myDeliveries.isEmpty) {
        return Scaffold(
          appBar: AppBar(title: const Text('My Deliveries')),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off_outlined,
                      size: 40, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: AppSpacing.md),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: AppSpacing.md),
                  TextButton.icon(
                    onPressed: _loadDeliveries,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      return child;
    }

    final pages = [
      pageAt(
          0,
          _VolunteerHomeTab(
              opportunities: _opportunities,
              myDeliveries: _myDeliveries,
              onAccept: _accept)),
      pageAt(1, _VolunteerDeliveriesTab(myDeliveries: _myDeliveries)),
      pageAt(2, _VolunteerImpactTab(myDeliveries: _myDeliveries)),
      NotificationsScreen(role: UserRole.volunteer, embedded: true),
      ProfileTab(role: UserRole.volunteer, name: state.currentName),
    ];
    return Scaffold(
      body: pages[_tab],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab,
        onTap: (i) => setState(() => _tab = i),
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home),
              label: 'Home'),
          BottomNavigationBarItem(
              icon: Icon(Icons.local_shipping_outlined),
              activeIcon: Icon(Icons.local_shipping),
              label: 'Deliveries'),
          BottomNavigationBarItem(
              icon: Icon(Icons.emoji_events_outlined),
              activeIcon: Icon(Icons.emoji_events),
              label: 'Impact'),
          BottomNavigationBarItem(
              icon: Icon(Icons.notifications_outlined),
              activeIcon: Icon(Icons.notifications),
              label: 'Alerts'),
          BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: 'Profile'),
        ],
      ),
    );
  }
}

class _VolunteerHomeTab extends StatelessWidget {
  final List<DeliveryOpportunity> opportunities;
  final List<DeliveryOpportunity> myDeliveries;
  final void Function(DeliveryOpportunity) onAccept;
  const _VolunteerHomeTab(
      {required this.opportunities,
      required this.myDeliveries,
      required this.onAccept});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final available = opportunities
        .where((o) => o.status == DeliveryStatus.available)
        .toList();
    final completed = myDeliveries
        .where((o) => o.status == DeliveryStatus.delivered)
        .toList();
    final distanceCovered =
        completed.fold<double>(0, (sum, o) => sum + o.distanceKm);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: DashboardHeader(
            greeting: 'Hi, ${state.currentName} 👋',
            subtitle: 'Ready to make an impact today?',
            roleLabel: 'VOLUNTEER (OPTIONAL ROLE)',
            onNotificationTap: () =>
                _openNotifications(context, UserRole.volunteer),
            onProfileTap: () {},
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Row(children: [
                Expanded(
                    child: StatCard(
                        label: 'Available Deliveries',
                        value: '${available.length}',
                        icon: Icons.local_shipping_outlined,
                        emphasis: Emphasis.strong)),
                const SizedBox(width: 10),
                Expanded(
                    child: StatCard(
                        label: 'Completed',
                        value: '${completed.length}',
                        icon: Icons.check_circle_outline,
                        emphasis: Emphasis.primary)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: StatCard(
                        label: 'Distance Covered',
                        value: '${distanceCovered.toStringAsFixed(0)} km',
                        icon: Icons.route_outlined)),
                const SizedBox(width: 10),
                Expanded(
                    child: StatCard(
                        label: 'Impact Points',
                        value: '0',
                        icon: Icons.workspace_premium_outlined)),
              ]),
              const SizedBox(height: AppSpacing.lg),
              Builder(builder: (context) {
                final c = AppColors.of(context);
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Icon(Icons.info_outline, size: 18, color: c.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(
                            'Volunteering is optional — donations are never blocked waiting for a volunteer.',
                            style: TextStyle(
                                fontSize: 12, color: c.textSecondary))),
                  ]),
                );
              }),
              const SizedBox(height: AppSpacing.lg),
              const SectionHeader(title: 'Delivery Opportunities Near You'),
              const SizedBox(height: 10),
              if (available.isEmpty)
                const EmptyState(
                    icon: Icons.local_shipping_outlined,
                    message: 'No delivery opportunities near you right now.')
              else
                ...available.map((o) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _DeliveryCard(
                        opportunity: o,
                        onView: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => DeliveryDetailScreen(
                                    opportunity: o, onAccept: onAccept))),
                        onAccept: () => onAccept(o),
                      ),
                    )),
            ]),
          ),
        ),
      ],
    );
  }
}

class _DeliveryCard extends StatelessWidget {
  final DeliveryOpportunity opportunity;
  final VoidCallback onView;
  final VoidCallback onAccept;
  const _DeliveryCard(
      {required this.opportunity,
      required this.onView,
      required this.onAccept});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isUrgent = opportunity.deadline.toLowerCase().contains('urgent');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                  child: Text(
                      '${opportunity.quantityKg.toStringAsFixed(0)} kg ${opportunity.foodName}',
                      style: Theme.of(context).textTheme.titleMedium)),
              if (isUrgent) StatusChip(label: 'URGENT', color: c.danger),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('PROVIDER',
                        style: TextStyle(
                            fontSize: 10,
                            color: c.textSecondary,
                            fontWeight: FontWeight.w700)),
                    Text(opportunity.providerName,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12.5)),
                  ])),
              Icon(Icons.arrow_forward, size: 16, color: c.textSecondary),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                    Text('NGO',
                        style: TextStyle(
                            fontSize: 10,
                            color: c.textSecondary,
                            fontWeight: FontWeight.w700)),
                    Text(opportunity.ngoName,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12.5),
                        textAlign: TextAlign.right),
                  ])),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 14, runSpacing: 6, children: [
              _mini(context, Icons.near_me_outlined,
                  '${opportunity.distanceKm.toStringAsFixed(1)} km'),
              _mini(context, Icons.schedule_outlined, opportunity.deadline),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: SecondaryButton(
                      label: 'VIEW DETAILS', onPressed: onView)),
              const SizedBox(width: 8),
              Expanded(
                  child: PrimaryButton(
                      label: "I'LL DELIVER", onPressed: onAccept)),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _mini(BuildContext context, IconData icon, String text) {
    final c = AppColors.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: c.textSecondary),
      const SizedBox(width: 4),
      Text(text, style: TextStyle(fontSize: 12, color: c.textSecondary))
    ]);
  }
}

class DeliveryDetailScreen extends StatefulWidget {
  final DeliveryOpportunity opportunity;
  final void Function(DeliveryOpportunity) onAccept;
  const DeliveryDetailScreen(
      {super.key, required this.opportunity, required this.onAccept});

  @override
  State<DeliveryDetailScreen> createState() => _DeliveryDetailScreenState();
}

class _DeliveryDetailScreenState extends State<DeliveryDetailScreen> {
  static const _steps = [
    DeliveryStatus.accepted,
    DeliveryStatus.pickedUp,
    DeliveryStatus.inTransit,
    DeliveryStatus.delivered
  ];

  int get _currentStepIndex {
    final idx = _steps.indexOf(widget.opportunity.status);
    return idx;
  }

  Future<void> _advance() async {
    final idx = _currentStepIndex;
    if (idx >= _steps.length - 1) return;
    final previous = widget.opportunity.status;
    final next = _steps[idx + 1];
    setState(() => widget.opportunity.status = next);
    try {
      await context.read<AppState>().api.updateDeliveryStatus(
            widget.opportunity.id,
            {'status': _deliveryStatusToBackend(next)},
          );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => widget.opportunity.status = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            backgroundColor: AppColors.of(context).danger,
            content: Text(_apiErrorMessage(
                e, fallback: 'Could not update the delivery status. Please try again.'))),
      );
      return;
    }
    if (!mounted) return;
    if (widget.opportunity.status == DeliveryStatus.delivered) {
      context.read<AppState>().pushNotification(
            'Delivery Completed',
            'You delivered "${widget.opportunity.foodName}"'
            ' to ${widget.opportunity.ngoName}. Thank you for helping SAHAAY!',
            NotificationCategory.reward,
          );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            backgroundColor: AppColors.of(context).green,
            content: const Text(
                'Delivery completed! Thank you for helping SAHAAY.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.opportunity;
    final c = AppColors.of(context);
    final started = o.status != DeliveryStatus.available;

    return Scaffold(
      appBar: AppBar(title: const Text('Delivery Details')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${o.quantityKg.toStringAsFixed(0)} kg ${o.foodName}',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 6),
            StatusChip(
                label: deliveryStatusLabel(o.status), color: c.bluePrimary),
            const SizedBox(height: AppSpacing.lg),
            const MapPlaceholder(height: 150),
            const SizedBox(height: AppSpacing.lg),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(children: [
                  _row(context, Icons.storefront_outlined, 'Provider',
                      o.providerName),
                  _row(context, Icons.apartment_outlined, 'NGO Destination',
                      o.ngoName),
                  _row(context, Icons.near_me_outlined, 'Distance',
                      '${o.distanceKm.toStringAsFixed(1)} km'),
                  _row(
                      context, Icons.schedule_outlined, 'Deadline', o.deadline),
                ]),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (!started)
              PrimaryButton(
                label: 'ACCEPT DELIVERY',
                onPressed: () {
                  widget.onAccept(o);
                  setState(() {});
                },
              )
            else ...[
              _DeliveryStepper(currentIndex: _currentStepIndex),
              const SizedBox(height: AppSpacing.lg),
              if (o.status != DeliveryStatus.delivered)
                PrimaryButton(
                    label:
                        'MARK "${deliveryStatusLabel(_steps[_currentStepIndex + 1]).toUpperCase()}"',
                    onPressed: _advance)
              else
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                      color: c.greenSoft,
                      borderRadius: BorderRadius.circular(AppRadius.card)),
                  child: Row(children: [
                    Icon(Icons.check_circle, color: c.green),
                    const SizedBox(width: 8),
                    const Expanded(
                        child: Text(
                            'Delivery completed. Thank you for helping SAHAAY!')),
                  ]),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, String label, String value) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 18, color: c.textSecondary),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: TextStyle(color: c.textSecondary))),
        Flexible(
            child: Text(value,
                style: const TextStyle(fontWeight: FontWeight.w700),
                textAlign: TextAlign.right)),
      ]),
    );
  }
}

class _DeliveryStepper extends StatelessWidget {
  final int currentIndex;
  const _DeliveryStepper({required this.currentIndex});
  static const _labels = ['Accepted', 'Picked Up', 'In Transit', 'Delivered'];

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      children: List.generate(_labels.length, (i) {
        final done = i <= currentIndex;
        return Expanded(
          child: Column(children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: done ? c.bluePrimary : c.surfaceAlt,
              child: Icon(done ? Icons.check : Icons.circle,
                  size: 14, color: done ? Colors.white : c.textSecondary),
            ),
            const SizedBox(height: 4),
            Text(_labels[i],
                style: TextStyle(
                    fontSize: 10,
                    color: done ? c.bluePrimary : c.textSecondary,
                    fontWeight: FontWeight.w700),
                textAlign: TextAlign.center),
          ]),
        );
      }),
    );
  }
}

class _VolunteerDeliveriesTab extends StatelessWidget {
  final List<DeliveryOpportunity> myDeliveries;
  const _VolunteerDeliveriesTab({required this.myDeliveries});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text('My Deliveries'),
          actions: const [ThemeToggleButton()]),
      body: myDeliveries.isEmpty
          ? const EmptyState(
              icon: Icons.local_shipping_outlined,
              message: 'No accepted deliveries yet.')
          : ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.lg),
              itemCount: myDeliveries.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final o = myDeliveries[i];
                return Card(
                  child: ListTile(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => DeliveryDetailScreen(
                            opportunity: o, onAccept: (_) {}))),
                    title: Text(
                        '${o.foodName} — ${o.quantityKg.toStringAsFixed(0)} kg'),
                    subtitle: Text('${o.providerName} → ${o.ngoName}'),
                    trailing: StatusChip(
                        label: deliveryStatusLabel(o.status),
                        color: AppColors.of(context).bluePrimary),
                  ),
                );
              },
            ),
    );
  }
}

class _VolunteerImpactTab extends StatelessWidget {
  final List<DeliveryOpportunity> myDeliveries;
  const _VolunteerImpactTab({required this.myDeliveries});

  @override
  Widget build(BuildContext context) {
    final completed = myDeliveries
        .where((o) => o.status == DeliveryStatus.delivered)
        .toList();
    final distanceCovered =
        completed.fold<double>(0, (sum, o) => sum + o.distanceKm);
    final kgDelivered =
        completed.fold<double>(0, (sum, o) => sum + o.quantityKg);

    return Scaffold(
      appBar: AppBar(
          title: const Text('Impact & Rewards'),
          actions: const [ThemeToggleButton()]),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 2.4,
            children: [
              ImpactCard(
                  emoji: '🚚',
                  value: '${completed.length}',
                  label: 'Deliveries'),
              ImpactCard(
                  emoji: '📦',
                  value: '${kgDelivered.toStringAsFixed(0)} kg',
                  label: 'Food Delivered'),
              ImpactCard(
                  emoji: '📍',
                  value: '${distanceCovered.toStringAsFixed(0)} km',
                  label: 'Distance Covered'),
              const ImpactCard(emoji: '⭐', value: '—', label: 'Reliability'),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          RewardCard(
            impactPoints: 0,
            levelLabel: 'VOLUNTEER',
            badges: MockData.volunteerBadges(),
            statLines: const [
              _StatLine(label: 'Reliability', value: '—'),
              _StatLine(label: 'Cancelled Deliveries', value: '0'),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// ADMIN DASHBOARD
// =============================================================================

/// Read-only admin resources backed by the `/api/v1/admin/*` endpoints.
enum AdminResource {
  users('Users', Icons.people_outline),
  providers('Providers', Icons.storefront_outlined),
  ngos('NGOs', Icons.apartment_outlined),
  volunteers('Volunteers', Icons.volunteer_activism_outlined),
  donations('Donations', Icons.receipt_long_outlined),
  claims('Claims', Icons.assignment_turned_in_outlined),
  deliveries('Deliveries', Icons.local_shipping_outlined);

  final String label;
  final IconData icon;
  const AdminResource(this.label, this.icon);
}

/// Live overview counters from GET /api/v1/admin/summary.
class AdminSummary {
  final int totalUsers;
  final int providers;
  final int ngos;
  final int volunteers;
  final int totalDonations;
  final int completedRedistributions;
  final int pendingClaims;
  final int activeDeliveries;
  const AdminSummary({
    required this.totalUsers,
    required this.providers,
    required this.ngos,
    required this.volunteers,
    required this.totalDonations,
    required this.completedRedistributions,
    required this.pendingClaims,
    required this.activeDeliveries,
  });

  factory AdminSummary.fromBackend(Map<String, dynamic> json) => AdminSummary(
        totalUsers: (json['total_users'] as num?)?.toInt() ?? 0,
        providers: (json['providers'] as num?)?.toInt() ?? 0,
        ngos: (json['ngos'] as num?)?.toInt() ?? 0,
        volunteers: (json['volunteers'] as num?)?.toInt() ?? 0,
        totalDonations: (json['total_donations'] as num?)?.toInt() ?? 0,
        completedRedistributions:
            (json['completed_redistributions'] as num?)?.toInt() ?? 0,
        pendingClaims: (json['pending_claims'] as num?)?.toInt() ?? 0,
        activeDeliveries: (json['active_deliveries'] as num?)?.toInt() ?? 0,
      );
}

/// Impact metrics from GET /api/v1/admin/analytics.
class AdminAnalytics {
  final double totalFoodDonatedKg;
  final double totalFoodRedistributedKg;
  final int expiredDonations;
  final int unclaimedAvailableDonations;
  final int successfulRedistributions;
  final int completedDeliveries;
  const AdminAnalytics({
    required this.totalFoodDonatedKg,
    required this.totalFoodRedistributedKg,
    required this.expiredDonations,
    required this.unclaimedAvailableDonations,
    required this.successfulRedistributions,
    required this.completedDeliveries,
  });

  factory AdminAnalytics.fromBackend(Map<String, dynamic> json) =>
      AdminAnalytics(
        totalFoodDonatedKg:
            (json['total_food_donated_kg'] as num?)?.toDouble() ?? 0,
        totalFoodRedistributedKg:
            (json['total_food_redistributed_kg'] as num?)?.toDouble() ?? 0,
        expiredDonations: (json['expired_donations'] as num?)?.toInt() ?? 0,
        unclaimedAvailableDonations:
            (json['unclaimed_available_donations'] as num?)?.toInt() ?? 0,
        successfulRedistributions:
            (json['successful_redistributions'] as num?)?.toInt() ?? 0,
        completedDeliveries:
            (json['completed_deliveries'] as num?)?.toInt() ?? 0,
      );
}

/// Integer-less kg label: "12" / "12.5" / "1.25".
String _adminKgLabel(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(
      RegExp(r'\.$'), '');
}

String _titleCase(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1);
}

Color _adminStatusColor(BuildContext context, String status) {
  final c = AppColors.of(context);
  switch (status) {
    case 'accepted':
    case 'in_transit':
      return c.bluePrimary;
    case 'completed':
    case 'delivered':
    case 'available':
      return c.green;
    case 'rejected':
    case 'cancelled':
    case 'failed':
      return c.danger;
    case 'pending':
    case 'assigned':
    case 'picked_up':
    case 'claimed':
    case 'pickup_assigned':
      return c.warning;
    default:
      return c.textSecondary;
  }
}

Color _adminRoleColor(BuildContext context, String role) {
  final c = AppColors.of(context);
  switch (role) {
    case 'admin':
      return c.green;
    case 'ngo':
      return c.warning;
    case 'volunteer':
      return c.bluePrimary;
    default:
      return c.textSecondary;
  }
}

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});
  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController =
      TabController(length: 3, vsync: this);

  AdminSummary? _summary;
  AdminAnalytics? _analytics;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<AppState>().api;
      final results = await Future.wait<dynamic>([
        api.getAdminSummary(),
        api.getAdminAnalytics(),
      ]);
      if (!mounted) return;
      setState(() {
        _summary = AdminSummary.fromBackend(
            results[0] is Map<String, dynamic>
                ? results[0] as Map<String, dynamic>
                : <String, dynamic>{});
        _analytics = AdminAnalytics.fromBackend(
            results[1] is Map<String, dynamic>
                ? results[1] as Map<String, dynamic>
                : <String, dynamic>{});
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error =
            _apiErrorMessage(e, fallback: 'Could not load the admin dashboard.');
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error =
            'Could not reach the server. Please check your connection and try again.';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      body: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverToBoxAdapter(
            child: DashboardHeader(
              greeting: 'Admin Console',
              subtitle: 'Platform-wide activity & analytics',
              roleLabel: 'ADMIN',
              onNotificationTap: () =>
                  _openNotifications(context, UserRole.admin),
              onProfileTap: () {},
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
              child: Container(
                decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(color: c.border)),
                child: TabBar(
                  controller: _tabController,
                  labelColor: c.bluePrimary,
                  unselectedLabelColor: c.textSecondary,
                  indicatorColor: c.bluePrimary,
                  tabs: const [
                    Tab(text: 'Overview'),
                    Tab(text: 'Management'),
                    Tab(text: 'Reports')
                  ],
                ),
              ),
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabController,
          children: [
            _AdminOverviewTab(
              summary: _summary,
              analytics: _analytics,
              loading: _loading,
              error: _error,
              onRetry: _load,
            ),
            const _AdminManagementTab(),
            _AdminReportsTab(analytics: _analytics),
          ],
        ),
      ),
    );
  }
}

class _AdminOverviewTab extends StatelessWidget {
  final AdminSummary? summary;
  final AdminAnalytics? analytics;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  const _AdminOverviewTab({
    required this.summary,
    required this.analytics,
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null) {
      return _AdminErrorBanner(message: error!, onRetry: onRetry);
    }
    final s = summary;
    final a = analytics;
    final isAllZero =
        s == null || a == null || (s.totalUsers == 0 && s.providers == 0);
    return RefreshIndicator(
      onRefresh: () async => onRetry(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
        children: [
          if (isAllZero)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Icon(Icons.info_outline, size: 18, color: c.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'No platform activity yet — live numbers will appear here as providers, NGOs, and volunteers join.',
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                  ),
                ),
              ]),
            ),
          if (isAllZero) const SizedBox(height: AppSpacing.md),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.5,
            children: [
              StatCard(
                  label: 'Total Users',
                  value: '${s!.totalUsers}',
                  icon: Icons.people_outline,
                  emphasis: Emphasis.strong),
              StatCard(
                  label: 'Providers',
                  value: '${s.providers}',
                  icon: Icons.storefront_outlined,
                  emphasis: Emphasis.primary),
              StatCard(
                  label: 'NGOs',
                  value: '${s.ngos}',
                  icon: Icons.apartment_outlined),
              StatCard(
                  label: 'Volunteers',
                  value: '${s.volunteers}',
                  icon: Icons.volunteer_activism_outlined),
              StatCard(
                  label: 'Completed Deliveries',
                  value: '${a!.completedDeliveries}',
                  icon: Icons.local_shipping_outlined),
              StatCard(
                  label: 'Food Redistributed',
                  value: '${_adminKgLabel(a.totalFoodRedistributedKg)} kg',
                  icon: Icons.scale_outlined),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const SectionHeader(title: 'Recent Activity'),
          const SizedBox(height: 10),
          const Card(
            child: EmptyState(
                icon: Icons.history_outlined,
                message:
                    'No recent activity yet — this will populate as donations move through the platform.'),
          ),
        ],
      ),
    );
  }
}

class _AdminErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _AdminErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 40, color: c.textSecondary),
            const SizedBox(height: 10),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textSecondary)),
            const SizedBox(height: 16),
            SecondaryButton(label: 'Retry', onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}

class _AdminManagementTab extends StatelessWidget {
  const _AdminManagementTab();
  static const _items = [
    (AdminResource.users, 'User Management'),
    (AdminResource.providers, 'Provider Management'),
    (AdminResource.ngos, 'NGO Management'),
    (AdminResource.volunteers, 'Volunteer Management'),
    (AdminResource.donations, 'Donation Monitoring'),
    (AdminResource.claims, 'Claim Monitoring'),
    (AdminResource.deliveries, 'Delivery Monitoring'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final resource = _items[i].$1;
        return RoleCard(
          icon: resource.icon,
          title: _items[i].$2,
          subtitle:
              'View all ${resource.label.toLowerCase()} across the platform.',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => AdminListScreen(resource: resource))),
        );
      },
    );
  }
}

class _AdminReportsTab extends StatelessWidget {
  final AdminAnalytics? analytics;
  const _AdminReportsTab({required this.analytics});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final a = analytics;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.stacked_bar_chart_outlined, color: c.bluePrimary),
                  const SizedBox(width: 8),
                  const Expanded(
                      child: Text('Real Impact Metrics',
                          style: TextStyle(fontWeight: FontWeight.w700))),
                ]),
                const SizedBox(height: 12),
                if (a == null)
                  const EmptyState(
                      icon: Icons.monitor_heart_outlined,
                      message: 'Loading live impact metrics…')
                else ...[
                  _AdminMetricRow(
                      icon: Icons.scale_outlined,
                      label: 'Food Donated',
                      value: '${_adminKgLabel(a.totalFoodDonatedKg)} kg',
                      color: c.bluePrimary),
                  _AdminMetricRow(
                      icon: Icons.volunteer_activism_outlined,
                      label: 'Food Redistributed',
                      value:
                          '${_adminKgLabel(a.totalFoodRedistributedKg)} kg',
                      color: c.green),
                  _AdminMetricRow(
                      icon: Icons.check_circle_outline,
                      label: 'Successful Redistributions',
                      value: '${a.successfulRedistributions}',
                      color: c.green),
                  _AdminMetricRow(
                      icon: Icons.local_shipping_outlined,
                      label: 'Completed Deliveries',
                      value: '${a.completedDeliveries}',
                      color: c.bluePrimary),
                  _AdminMetricRow(
                      icon: Icons.hourglass_empty,
                      label: 'Expired Donations',
                      value: '${a.expiredDonations}',
                      color: c.danger),
                  _AdminMetricRow(
                      icon: Icons.inventory_outlined,
                      label: 'Unclaimed Available',
                      value: '${a.unclaimedAvailableDonations}',
                      color: c.warning),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.bar_chart_outlined, color: c.bluePrimary),
                  const SizedBox(width: 8),
                  const Expanded(
                      child: Text('Weekly Redistribution Trend',
                          style: TextStyle(fontWeight: FontWeight.w700))),
                ]),
                const SizedBox(height: 16),
                const EmptyState(
                    icon: Icons.show_chart_outlined,
                    message:
                        'This chart will populate once real donation data is available.'),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        SecondaryButton(
          label: 'View Public Impact Leaderboard',
          icon: Icons.leaderboard_outlined,
          onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LeaderboardScreen())),
        ),
      ],
    );
  }
}

class _AdminMetricRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _AdminMetricRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Container(
          height: 40,
          width: 40,
          decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
            child:
                Text(label, style: TextStyle(color: c.textSecondary))),
        Text(value,
            style: TextStyle(
                fontWeight: FontWeight.w800, fontSize: 16, color: c.textPrimary)),
      ]),
    );
  }
}

/// Read-only, paginated list screen for one admin resource backed by the
/// `/api/v1/admin/*` endpoints. Reads real data through [AppState.api].
class AdminListScreen extends StatefulWidget {
  final AdminResource resource;
  const AdminListScreen({super.key, required this.resource});

  @override
  State<AdminListScreen> createState() => _AdminListScreenState();
}

class _AdminListScreenState extends State<AdminListScreen> {
  static const _pageSize = 50;
  final List<Map<String, dynamic>> _items = [];
  int _total = 0;
  int _page = 1;
  bool _loading = true;
  String? _error;
  String? _roleFilter;

  bool get _hasMore => _items.length < _total;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _fetch({required int page}) {
    final api = context.read<AppState>().api;
    switch (widget.resource) {
      case AdminResource.users:
        return api.getAdminUsers(role: _roleFilter, page: page, pageSize: _pageSize);
      case AdminResource.providers:
        return api.getAdminProviders(page: page, pageSize: _pageSize);
      case AdminResource.ngos:
        return api.getAdminNgos(page: page, pageSize: _pageSize);
      case AdminResource.volunteers:
        return api.getAdminVolunteers(page: page, pageSize: _pageSize);
      case AdminResource.donations:
        return api.getAdminDonations(page: page, pageSize: _pageSize);
      case AdminResource.claims:
        return api.getAdminClaims(page: page, pageSize: _pageSize);
      case AdminResource.deliveries:
        return api.getAdminDeliveries(page: page, pageSize: _pageSize);
    }
  }

  Future<void> _load({bool append = false}) async {
    if (!append) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final response = await _fetch(page: append ? _page + 1 : 1);
      final rawItems = response['items'];
      final list = <Map<String, dynamic>>[
        for (final item in (rawItems is List ? rawItems : const <dynamic>[]))
          if (item is Map<String, dynamic>) item,
      ];
      if (!mounted) return;
      setState(() {
        if (append) {
          _page += 1;
          _items.addAll(list);
        } else {
          _page = 1;
          _items
            ..clear()
            ..addAll(list);
        }
        _total = (response['total'] as num?)?.toInt() ?? list.length;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _apiErrorMessage(
            e, fallback: 'Could not load ${widget.resource.label}.');
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error =
            'Could not reach the server. Please check your connection and try again.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.resource.label),
        actions: const [ThemeToggleButton()],
      ),
      body: Column(
        children: [
          if (widget.resource == AdminResource.users)
            _AdminRoleFilterBar(
              selected: _roleFilter,
              onChanged: (role) {
                setState(() => _roleFilter = role);
                _load();
              },
            ),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return _AdminErrorBanner(message: _error!, onRetry: () => _load());
    }
    if (_items.isEmpty) {
      final c = AppColors.of(context);
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          EmptyState(
              icon: widget.resource.icon,
              message: 'No ${widget.resource.label.toLowerCase()} found yet.'),
          const SizedBox(height: AppSpacing.md),
          Center(
            child: TextButton(
              onPressed: () => _load(),
              child: Text('Refresh', style: TextStyle(color: c.bluePrimary)),
            ),
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: _items.length + (_hasMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          if (i == _items.length) {
            return Center(
              child: TextButton(
                onPressed: () => _load(append: true),
                child: const Text('Load more'),
              ),
            );
          }
          return _AdminResourceTile(
              resource: widget.resource, item: _items[i]);
        },
      ),
    );
  }
}

class _AdminRoleFilterBar extends StatelessWidget {
  final String? selected;
  final ValueChanged<String?> onChanged;
  const _AdminRoleFilterBar({required this.selected, required this.onChanged});

  static const _allRoles = ['provider', 'ngo', 'volunteer', 'admin'];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.xs),
            child: ChoiceChip(
              label: const Text('All'),
              selected: selected == null,
              onSelected: (_) => onChanged(null),
            ),
          ),
          for (final role in _allRoles)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: ChoiceChip(
                label: Text(_titleCase(role)),
                selected: selected == role,
                onSelected: (_) => onChanged(role),
              ),
            ),
        ]),
      ),
    );
  }
}

class _AdminResourceTile extends StatelessWidget {
  final AdminResource resource;
  final Map<String, dynamic> item;
  const _AdminResourceTile({required this.resource, required this.item});

  Map<String, dynamic> _nested(String key) {
    final value = item[key];
    return value is Map<String, dynamic> ? value : <String, dynamic>{};
  }

  String _titleOf() {
    switch (resource) {
      case AdminResource.users:
        return item['full_name']?.toString() ??
            item['email']?.toString() ??
            '—';
      case AdminResource.providers:
        return item['organization_name']?.toString() ?? 'Untitled provider';
      case AdminResource.ngos:
        return item['organization_name']?.toString() ?? 'Untitled NGO';
      case AdminResource.volunteers:
        return item['user_full_name']?.toString() ?? 'Unnamed volunteer';
      case AdminResource.donations:
        return item['food_name']?.toString() ?? 'Untitled donation';
      case AdminResource.claims:
        return _nested('donation')['food_name']?.toString() ?? 'Food claim';
      case AdminResource.deliveries:
        return _nested('donation')['food_name']?.toString() ?? 'Food delivery';
    }
  }

  String _subtitleOf() {
    switch (resource) {
      case AdminResource.users:
        final email = item['email']?.toString() ?? '—';
        return '$email • ${_titleCase(item['role']?.toString() ?? 'user')}';
      case AdminResource.providers:
        final owner = item['user_full_name']?.toString() ?? '';
        final city = item['city']?.toString() ?? '';
        return '$city • ${owner.isEmpty ? item['user_email'] ?? '' : owner}';
      case AdminResource.ngos:
        final city = item['city']?.toString() ?? '';
        final capacity = item['food_capacity']?.toString() ?? '—';
        return '$city • Capacity $capacity kg';
      case AdminResource.volunteers:
        final email = item['user_email']?.toString() ?? '';
        final status = item['availability_status']?.toString() ?? '';
        return '$email • ${_titleCase(status)}';
      case AdminResource.donations:
        final quantity = item['quantity']?.toString() ?? '—';
        final unit = item['unit']?.toString() ?? '';
        final provider = _nested('provider')['organization_name']?.toString();
        return '$quantity $unit • ${provider ?? 'no provider'}';
      case AdminResource.claims:
        final ngo = _nested('ngo')['organization_name']?.toString();
        final requested = item['requested_quantity']?.toString() ?? '—';
        return '${ngo ?? 'no NGO'} • requested $requested';
      case AdminResource.deliveries:
        final ngo = _nested('ngo')['organization_name']?.toString();
        final volunteer = _nested('volunteer')['user_full_name']?.toString();
        return '${ngo ?? 'no NGO'} • ${volunteer ?? 'awaiting volunteer'}';
    }
  }

  (String, Color)? _statusOf(BuildContext context) {
    switch (resource) {
      case AdminResource.users:
        final role = item['role']?.toString() ?? '';
        return (_titleCase(role), _adminRoleColor(context, role));
      case AdminResource.providers:
        final verified = item['verified'] == true;
        return (verified ? 'Verified' : 'Unverified', verified
            ? AppColors.of(context).green
            : AppColors.of(context).warning);
      case AdminResource.ngos:
        final verified = item['verified'] == true;
        return (verified ? 'Verified' : 'Unverified', verified
            ? AppColors.of(context).green
            : AppColors.of(context).warning);
      case AdminResource.volunteers:
        final status = item['availability_status']?.toString() ?? '';
        return (_titleCase(status), _adminStatusColor(context, status));
      case AdminResource.donations:
        final status = item['status']?.toString() ?? '';
        final donationStatus = _donationStatusFromBackend(status);
        return (donationStatusLabel(donationStatus),
            donationStatusColor(donationStatus, context));
      case AdminResource.claims:
      case AdminResource.deliveries:
        final status = item['status']?.toString() ?? '';
        return (_titleCase(status), _adminStatusColor(context, status));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final status = _statusOf(context);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () {},
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Container(
                height: 44,
                width: 44,
                decoration: BoxDecoration(
                    color: c.bluePrimary.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12)),
                child: Icon(resource.icon, color: c.bluePrimary, size: 20),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_titleOf(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(_subtitleOf(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: c.textSecondary, fontSize: 12.5)),
                  ],
                ),
              ),
              if (status != null) ...[
                const SizedBox(width: AppSpacing.sm),
                StatusChip(label: status.$1, color: status.$2),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// LEADERBOARD (public impact — FR-19)
// =============================================================================

class LeaderboardScreen extends StatelessWidget {
  const LeaderboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final entries = MockData.leaderboard();
    return Scaffold(
      appBar: AppBar(
          title: const Text('Public Impact Leaderboard'),
          actions: const [ThemeToggleButton()]),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            color: c.headerFill(context),
            child: const Text('City-level impact, ranked by food redistributed',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
          ),
          Expanded(
            child: entries.isEmpty
                ? const EmptyState(
                    icon: Icons.leaderboard_outlined,
                    message:
                        'The leaderboard will populate as providers and NGOs complete donations.')
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: i == 0
                                ? c.green.withOpacity(0.15)
                                : c.surfaceAlt,
                            child: Text('#${e.rank}',
                                style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: i == 0 ? c.green : c.textPrimary)),
                          ),
                          title: Text(e.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text(
                              '${e.city} • ${e.kgRedistributed.toStringAsFixed(0)} kg redistributed'),
                          trailing: Text('${e.impactPoints} pts',
                              style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: c.bluePrimary)),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// NOTIFICATIONS (shared across roles)
// =============================================================================

NotificationCategory _notificationCategoryFromType(String? t) {
  switch (t) {
    case 'donation':
      return NotificationCategory.donation;
    case 'matching':
      return NotificationCategory.matching;
    case 'volunteer':
      return NotificationCategory.volunteer;
    case 'reward':
      return NotificationCategory.reward;
    default:
      return NotificationCategory.system;
  }
}

class NotificationsScreen extends StatefulWidget {
  final UserRole role;
  final bool
      embedded; // true when used as a bottom-nav tab (no back button needed)
  const NotificationsScreen(
      {super.key, required this.role, this.embedded = false});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  // Backend notifications loaded once. When the backend has none (it never
  // writes notifications yet), the session-based local ones are shown as a
  // fallback so the user still sees what their own actions triggered.
  List<AppNotificationItem>? _serverItems;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final raw = await context.read<AppState>().api.getNotifications();
      final items = [
        for (final item in raw)
          if (item is Map<String, dynamic>)
            AppNotificationItem(
              id: item['id']?.toString(),
              title: item['title']?.toString() ?? '',
              body: item['message']?.toString() ?? '',
              time: _fromIsoTime(item['created_at']),
              category:
                  _notificationCategoryFromType(item['type']?.toString()),
              read: item['is_read'] == true,
            ),
      ];
      if (!mounted) return;
      setState(() {
        _serverItems = items;
        _loading = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _markRead(AppNotificationItem item) async {
    final id = item.id;
    if (id == null) {
      final session = context.read<AppState>().notifications;
      final index = session.indexOf(item);
      if (index >= 0) context.read<AppState>().markNotificationRead(index);
      return;
    }
    try {
      await context.read<AppState>().api.markNotificationRead(id);
      if (!mounted) return;
      setState(() => item.read = true);
    } on ApiException {
      // Cosmetic only — never block the UI on a failed read-marker.
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final List<AppNotificationItem> items;
    if (_loading) {
      items = const [];
    } else if (_serverItems != null && _serverItems!.isNotEmpty) {
      items = _serverItems!;
    } else {
      items = List.of(state.notifications);
    }

    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (items.isEmpty) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _failed
                  ? Icons.cloud_off_outlined
                  : Icons.notifications_none_outlined,
              size: 40,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 10),
            Text(
              _failed ? 'Could not load notifications.' : 'No notifications yet.',
              style: const TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            if (_failed) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      );
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) => NotificationTile(
          item: items[i],
          onTap: () => _markRead(items[i]),
        ),
      );
    }

    if (widget.embedded) {
      return Scaffold(
          appBar: AppBar(
              title: const Text('Notifications'),
              automaticallyImplyLeading: false,
              actions: const [ThemeToggleButton()]),
          body: body);
    }
    return Scaffold(
        appBar: AppBar(title: const Text('Notifications')), body: body);
  }
}

// =============================================================================
// SHARED PROFILE TAB
// =============================================================================

class ProfileTab extends StatelessWidget {
  final UserRole role;
  final String name;
  const ProfileTab({super.key, required this.role, required this.name});

  String get _roleLabel {
    switch (role) {
      case UserRole.provider:
        return 'FOOD PROVIDER';
      case UserRole.ngo:
        return 'NGO';
      case UserRole.volunteer:
        return 'VOLUNTEER';
      case UserRole.admin:
        return 'ADMIN';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(
          title: const Text('Profile'), actions: const [ThemeToggleButton()]),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(children: [
                CircleAvatar(
                    radius: 28,
                    backgroundColor: c.bluePrimary.withOpacity(0.12),
                    child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: TextStyle(
                            color: c.bluePrimary,
                            fontWeight: FontWeight.w800,
                            fontSize: 22))),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 4),
                        StatusChip(label: _roleLabel, color: c.bluePrimary),
                      ]),
                ),
              ]),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Card(
            child: Column(children: [
              ListTile(
                  leading: const Icon(Icons.leaderboard_outlined),
                  title: const Text('Public Impact Leaderboard'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const LeaderboardScreen()))),
              const Divider(height: 1),
              ListTile(
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Settings'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SettingsScreen(role: role, name: name)))),
              const Divider(height: 1),
              ListTile(
                  leading: const Icon(Icons.help_outline),
                  title: const Text('Help & Support'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const HelpSupportScreen()))),
            ]),
          ),
          const SizedBox(height: AppSpacing.lg),
          SecondaryButton(
              label: 'LOG OUT',
              icon: Icons.logout,
              onPressed: () => _logout(context)),
        ],
      ),
    );
  }
}

// =============================================================================
// SETTINGS DASHBOARD
// =============================================================================

class SettingsScreen extends StatefulWidget {
  final UserRole role;
  final String name;
  const SettingsScreen({super.key, required this.role, required this.name});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Local, genuine app preferences (not backend/user data) — safe to keep
  // as real, functional toggles even before a backend exists.
  bool _donationAlerts = true;
  bool _matchingAlerts = true;
  bool _rewardAlerts = true;
  bool _showOnLeaderboard = true;

  String get _roleLabel {
    switch (widget.role) {
      case UserRole.provider:
        return 'FOOD PROVIDER';
      case UserRole.ngo:
        return 'NGO';
      case UserRole.volunteer:
        return 'VOLUNTEER';
      case UserRole.admin:
        return 'ADMIN';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final state = context.watch<AppState>();
    final isDark = state.themeMode == ThemeMode.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          const SectionHeader(title: 'Account'),
          const SizedBox(height: 10),
          Card(
            child: Column(children: [
              ListTile(
                leading: Icon(Icons.person_outline, color: c.bluePrimary),
                title: Text(widget.name.isEmpty ? 'Not set' : widget.name),
                subtitle: Text(_roleLabel),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit profile details'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text(
                          'Profile editing will be available once account data is connected.')),
                ),
              ),
            ]),
          ),
          const SizedBox(height: AppSpacing.lg),
          const SectionHeader(title: 'Notification Preferences'),
          const SizedBox(height: 10),
          Card(
            child: Column(children: [
              SwitchListTile(
                secondary: const Icon(Icons.inventory_2_outlined),
                title: const Text('Donation & claim updates'),
                value: _donationAlerts,
                onChanged: (v) => setState(() => _donationAlerts = v),
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: const Icon(Icons.hub_outlined),
                title: const Text('Matching & volunteer assignment alerts'),
                value: _matchingAlerts,
                onChanged: (v) => setState(() => _matchingAlerts = v),
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: const Icon(Icons.workspace_premium_outlined),
                title: const Text('Reward & impact updates'),
                value: _rewardAlerts,
                onChanged: (v) => setState(() => _rewardAlerts = v),
              ),
            ]),
          ),
          const SizedBox(height: AppSpacing.lg),
          const SectionHeader(title: 'Privacy'),
          const SizedBox(height: 10),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.leaderboard_outlined),
              title:
                  const Text('Show my organization on the public leaderboard'),
              value: _showOnLeaderboard,
              onChanged: (v) => setState(() => _showOnLeaderboard = v),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const SectionHeader(title: 'App Preferences'),
          const SizedBox(height: 10),
          Card(
            child: Column(children: [
              SwitchListTile(
                secondary: Icon(isDark
                    ? Icons.dark_mode_outlined
                    : Icons.light_mode_outlined),
                title: const Text('Dark mode'),
                value: isDark,
                onChanged: (_) => context.read<AppState>().toggleTheme(),
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(Icons.language_outlined),
                title: Text('Language'),
                trailing: Text('English',
                    style: TextStyle(color: AppColors.light.textSecondary)),
              ),
            ]),
          ),
          const SizedBox(height: AppSpacing.lg),
          SecondaryButton(
              label: 'LOG OUT',
              icon: Icons.logout,
              onPressed: () => _logout(context)),
        ],
      ),
    );
  }
}

// =============================================================================
// HELP & SUPPORT DASHBOARD
// =============================================================================

class HelpSupportScreen extends StatelessWidget {
  const HelpSupportScreen({super.key});

  static const _faqs = [
    (
      'How SAHAAY Works',
      'Food providers list surplus food, NGOs discover and claim it nearby, and a volunteer can optionally help deliver it. A donation never depends on a volunteer being available.',
    ),
    (
      'Donation Help',
      'Providers can create a donation from the Home tab with food details, quantity, and a safe-consumption window. Once created, it becomes visible to nearby NGOs immediately.',
    ),
    (
      'Claim Help',
      'NGOs can browse nearby donations from Find Food, view full details, and claim one with a single confirmation. Claimed donations appear under My Claims with a full handover dashboard.',
    ),
    (
      'Account Help',
      'Your role (Provider, NGO, or Volunteer) is set during registration and determines which dashboard and features you see. Contact support if you need your role corrected.',
    ),
  ];

  void _openFeedbackSheet(BuildContext context,
      {required String title, required String hint}) {
    final controller = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final c = AppColors.of(ctx);
        return Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            decoration: BoxDecoration(
                color: c.surface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24))),
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: AppSpacing.md),
                    decoration: BoxDecoration(
                        color: c.border,
                        borderRadius: BorderRadius.circular(4)),
                  ),
                ),
                Text(title, style: Theme.of(ctx).textTheme.headlineMedium),
                const SizedBox(height: AppSpacing.md),
                AppInputField(label: hint, controller: controller, maxLines: 4),
                const SizedBox(height: AppSpacing.lg),
                PrimaryButton(
                  label: 'SUBMIT',
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          backgroundColor: AppColors.of(context).green,
                          content: const Text(
                              'Thanks — your message has been noted.')),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Help & Support')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Card(
            child: Column(
              children: _faqs.asMap().entries.map((e) {
                final isLast = e.key == _faqs.length - 1;
                final faq = e.value;
                return Column(children: [
                  ExpansionTile(
                    title: Text(faq.$1,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    childrenPadding: const EdgeInsets.fromLTRB(
                        AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(faq.$2,
                          style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 13,
                              height: 1.4))
                    ],
                  ),
                  if (!isLast) const Divider(height: 1),
                ]);
              }).toList(),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const SectionHeader(title: 'Get in Touch'),
          const SizedBox(height: 10),
          Card(
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.support_agent_outlined),
                title: const Text('Contact Support'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openFeedbackSheet(context,
                    title: 'Contact Support', hint: 'How can we help?'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Report a Problem'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openFeedbackSheet(context,
                    title: 'Report a Problem',
                    hint: 'Describe the issue you ran into'),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}
