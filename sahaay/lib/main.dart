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
//     no pre-seeded content anywhere.
//   - Leaderboard, AI predictions, match scores, freshness/quality scores,
//     platform-wide admin analytics: show an honest empty/pending state
//     until the real database/AI service is connected — no invented numbers.
//   - Maps: interactive Google Maps views using only saved coordinates.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:url_launcher/url_launcher.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'services/api_service.dart';
import 'services/distance.dart';
import 'services/firebase_auth_service.dart';
import 'services/geo_service.dart';
import 'services/phone_contact.dart';
import 'services/pdf_saver.dart';
import 'services/permission_service.dart';
import 'services/notification_copy.dart';
import 'services/profile_completion.dart';
import 'services/push_notifications.dart';
import 'services/supabase_service.dart';
import 'widgets/location_picker.dart';
import 'widgets/readable_address_text.dart';
import 'widgets/sahaay_google_map.dart';

/// Lets the FCM tap handler route into the app from outside the widget tree.
final GlobalKey<NavigatorState> _appNavigatorKey = GlobalKey<NavigatorState>();

/// Opens Google Maps centered on the given [latitude] and [longitude].
/// Uses the Android geo: intent scheme, which launches the Google Maps app
/// (or shows the web fallback if the app isn't installed).
Future<void> _openGoogleMaps(double latitude, double longitude) async {
  final url = 'geo:$latitude,$longitude';
  if (await canLaunch(url)) {
    await launch(url);
  } else {
    // Fallback to the web version if the native app isn't available.
    final webUrl =
        'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude';
    if (await canLaunch(webUrl)) {
      await launch(webUrl);
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Push plumbing: the background isolate handler plus the audible Android
  // channel must exist before any message can arrive.
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  await FirebaseMessaging.instance.setAutoInitEnabled(true);
  await PushNotifications.initialize();
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

String _dateTimeLabel(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = value.toLocal();
  return '${months[local.month - 1]} ${local.day}, ${_timeLabel(local)}';
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
      return e.message.isEmpty ? fallback : e.message;
    case 502:
    case 503:
      return fallback;
    case 401:
      return 'Your session has expired. Please sign in again.';
    case 403:
      return e.message.isEmpty
          ? 'You are not allowed to perform this action.'
          : e.message;
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

String _donationSubmissionErrorMessage(
  ApiException error, {
  required String operation,
}) {
  if (error.statusCode == 502 || error.statusCode == 503) {
    return operation == 'photo upload'
        ? 'Food photo upload is temporarily unavailable. Your donation details are saved; please retry.'
        : 'Donation submission is temporarily unavailable. Your donation details are saved; please retry.';
  }
  if (error.statusCode == 400) {
    return 'The donation request was rejected. Review the details and try again.';
  }
  return _apiErrorMessage(
    error,
    fallback: operation == 'photo upload'
        ? 'Could not upload your food photo. Your donation details are saved; please retry.'
        : 'Could not create your donation. Your details are saved; please retry.',
  );
}

/// Friendly, feature-neutral message for AI-integration errors (matching,
/// escalation, reliability, acknowledgments). Kept separate from [_apiErrorMessage]
/// because that helper is scoped to the food-safety create-donation flow.
String _aiFeatureErrorMessage(ApiException e, {required String fallback}) {
  switch (e.statusCode) {
    case 502:
      return 'The AI service returned an invalid response. Please try again.';
    case 503:
      if (e.message.toLowerCase().contains('ai service')) {
        return 'The AI service is temporarily unavailable. Please try again.';
      }
      return e.message.isEmpty ? fallback : e.message;
    case 401:
      return 'Your session has expired. Please sign in again.';
    case 403:
      return e.message.isEmpty
          ? 'You are not allowed to perform this action.'
          : e.message;
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

/// Saves an acknowledgment/receipt PDF's bytes to a user-findable location
/// (Android shared Downloads via MediaStore, otherwise the app documents
/// directory) and returns where it landed. Shared by the provider and NGO
/// receipt downloads so both parties end up with the exact same document.
Future<SavedPdf> saveAcknowledgmentPdf(String donationId, List<int> bytes) {
  final safeId = donationId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final fileName = 'sahaay_acknowledgment_$safeId.pdf';
  return savePdfToDownloads(fileName, bytes);
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

String transportCoordinationStatusLabel(Object? value) {
  switch (value) {
    case 'provider_transport':
      return 'Provider delivery';
    case 'ngo_transport':
      return 'NGO pickup';
    case 'searching_for_volunteers':
      return 'Searching for volunteers';
    case 'volunteer_assigned':
    case 'transport_coordination':
      return 'Volunteer assigned';
    case 'completed':
      return 'Completed';
    case 'awaiting_responses':
      return 'Awaiting transport responses';
    default:
      return 'Not available';
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
      return DeliveryStatus
          .accepted; // assigned / accepted / failed / cancelled
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

/// Parses a WGS-84 coordinate defensively: accepts a [num] or a numeric
/// [String], and returns null for anything absent, non-numeric or out of
/// range. A coordinate is only ever carried when the backend supplied a real
/// one — nothing is invented upstream of the map.
double? _coordinateFromMap(
    Map<String, dynamic> json, String key, double limit) {
  final value = json[key];
  if (value == null) return null;
  final parsed =
      value is num ? value.toDouble() : double.tryParse(value.toString());
  if (parsed == null || !parsed.isFinite || parsed.abs() > limit) return null;
  return parsed;
}

String? _addressWithCity(Object? addressValue, Object? cityValue) {
  final address = addressValue?.toString().trim() ?? '';
  final city = cityValue?.toString().trim() ?? '';
  if (address.isEmpty) return city.isEmpty ? null : city;
  if (city.isEmpty || address.toLowerCase().contains(city.toLowerCase())) {
    return address;
  }
  return '$address, $city';
}

Uri? googleMapsUriForLocation({
  double? latitude,
  double? longitude,
  String? address,
}) {
  final hasCoordinates = latitude != null &&
      longitude != null &&
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;
  final query =
      hasCoordinates ? '$latitude,$longitude' : (address ?? '').trim();
  if (query.isEmpty) return null;
  return Uri.https(
    'www.google.com',
    '/maps/search/',
    <String, String>{'api': '1', 'query': query},
  );
}

Map<String, dynamic> _roleProfileMap(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is List && value.isNotEmpty && value.first is Map) {
    return Map<String, dynamic>.from(value.first as Map);
  }
  return <String, dynamic>{};
}

/// Same as [_coordinateFromMap] but reading from a nested object, e.g.
/// `json['provider']['latitude']` when the row joins the donor in.
double? _nestedCoordinate(
    Map<String, dynamic> json, String childKey, String key, double limit) {
  final child = json[childKey];
  if (child is Map) {
    return _coordinateFromMap(Map<String, dynamic>.from(child), key, limit);
  }
  return null;
}

class Donation {
  final String id;
  final String foodName;
  final String category;
  final double quantityKg;
  final double quantity;
  final String quantityUnit;
  final int servings;
  final String description;
  final String? foodImageUrl;
  final String vegType;
  final Map<String, dynamic>? surplusPrediction;
  final String providerName;

  /// Straight-line distance from the viewer, or null when either end is
  /// unknown. Never fabricated as 0 — a 0 km reading would mean "right here".
  final double? distanceKm;
  final String expiryLabel;
  final String freshness; // AI-provided label e.g. "Good", "Excellent"
  DonationStatus status;

  /// Real WGS-84 pickup coordinates. Null until the backend row carries them —
  /// map cards degrade to the honest "location unavailable" state otherwise.
  final double? latitude;
  final double? longitude;

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
  final String? claimStatus;
  final String? foodExpiryLabel;
  final DateTime? createdAt;
  final DateTime? preparedAt;

  Donation({
    required this.id,
    required this.foodName,
    required this.category,
    required this.quantityKg,
    required this.quantity,
    required this.quantityUnit,
    required this.servings,
    this.description = '',
    this.foodImageUrl,
    this.vegType = '',
    this.surplusPrediction,
    required this.providerName,
    required this.distanceKm,
    required this.expiryLabel,
    required this.freshness,
    required this.status,
    this.latitude,
    this.longitude,
    this.providerAddress,
    this.providerContactNumber,
    this.providerRating,
    this.providerReviewCount,
    this.volunteerName,
    this.volunteerPhone,
    this.volunteerStatus,
    this.claimStatus,
    this.foodExpiryLabel,
    this.createdAt,
    this.preparedAt,
  });

  /// Builds a Donation from a backend donation row, optionally enriched with
  /// provider details from an authorized claim response.
  factory Donation.fromBackend(
    Map<String, dynamic> json, {
    double? referenceLatitude,
    double? referenceLongitude,
    bool includePrivateContacts = false,
  }) {
    final deadline =
        DateTime.tryParse(json['pickup_deadline']?.toString() ?? '');
    final foodExpiry = DateTime.tryParse(json['expiry_time']?.toString() ?? '');
    final createdAt = DateTime.tryParse(json['created_at']?.toString() ?? '');
    final preparedAt = DateTime.tryParse(json['prepared_at']?.toString() ?? '');
    final donationLatitude = _coordinateFromMap(json, 'latitude', 90) ??
        _nestedCoordinate(json, 'provider', 'latitude', 90);
    final donationLongitude = _coordinateFromMap(json, 'longitude', 180) ??
        _nestedCoordinate(json, 'provider', 'longitude', 180);
    final providerValue = json['provider'];
    final provider = providerValue is Map
        ? Map<String, dynamic>.from(providerValue)
        : const <String, dynamic>{};
    final predictionValue = json['surplus_prediction'];
    final prediction = predictionValue is Map
        ? Map<String, dynamic>.from(predictionValue)
        : null;
    final rawQuantity = json['quantity'];
    final parsedQuantity = rawQuantity is num
        ? rawQuantity.toDouble()
        : double.tryParse(rawQuantity?.toString() ?? '') ?? 0;
    return Donation(
      id: json['id']?.toString() ?? '',
      foodName: json['food_name']?.toString() ?? 'Untitled food item',
      category: json['food_category']?.toString() ?? 'Other',
      quantityKg: parsedQuantity,
      quantity: parsedQuantity,
      quantityUnit: json['unit']?.toString() ?? 'kg',
      servings: (json['servings'] as num?)?.toInt() ?? 0,
      description: json['description']?.toString() ?? '',
      foodImageUrl: json['food_image_url']?.toString(),
      vegType: json['veg_type']?.toString() ?? '',
      surplusPrediction: prediction,
      providerName: provider['organization_name']?.toString() ?? '',
      distanceKm: haversineKm(donationLatitude, donationLongitude,
          referenceLatitude, referenceLongitude),
      expiryLabel: deadline == null ? '' : 'Pickup by ${_timeLabel(deadline)}',
      status: _donationStatusFromBackend(json['status']?.toString()),
      latitude: donationLatitude,
      longitude: donationLongitude,
      providerAddress:
          json['pickup_address']?.toString() ?? provider['address']?.toString(),
      providerContactNumber:
          includePrivateContacts || provider['verified'] == true
              ? provider['phone']?.toString()
              : null,
      freshness: json['freshness']?.toString() ??
          json['freshness_label']?.toString() ??
          '',
      claimStatus: json['claim_status']?.toString(),
      foodExpiryLabel:
          foodExpiry == null ? null : 'Expires ${_dateTimeLabel(foodExpiry)}',
      createdAt: createdAt,
      preparedAt: preparedAt,
    );
  }

  /// Safe display fallback used in notifications and cards whenever the
  /// backend row has no joined provider name.
  String get providerLabel =>
      providerName.isEmpty ? 'a nearby provider' : providerName;

  String get freshnessLabel => freshness.isEmpty ? 'Not available' : freshness;
}

class DeliveryOpportunity {
  final String id;
  final String providerName;
  final String ngoName;
  final String foodName;
  final double quantityKg;

  /// Straight-line distance when a real point pair exists, otherwise null.
  final double? distanceKm;
  final String deadline;
  DeliveryStatus status;

  /// Real WGS-84 pickup coordinates. Null until the backend ever supplies
  /// them (legacy rows predate the coordinate columns).
  final double? latitude;
  final double? longitude;
  final double? dropoffLatitude;
  final double? dropoffLongitude;
  final String pickupAddress;
  final String dropoffAddress;
  final Map<String, dynamic> provider;
  final Map<String, dynamic> ngo;
  final Map<String, dynamic> coordination;
  final Map<String, dynamic> volunteer;
  final Donation? donation;

  DeliveryOpportunity({
    required this.id,
    required this.providerName,
    required this.ngoName,
    required this.foodName,
    required this.quantityKg,
    required this.distanceKm,
    required this.deadline,
    required this.status,
    this.latitude,
    this.longitude,
    this.dropoffLatitude,
    this.dropoffLongitude,
    this.pickupAddress = '',
    this.dropoffAddress = '',
    this.provider = const <String, dynamic>{},
    this.ngo = const <String, dynamic>{},
    this.coordination = const <String, dynamic>{},
    this.volunteer = const <String, dynamic>{},
    this.donation,
  });

  /// Builds a DeliveryOpportunity from a backend deliveries row. The
  /// backend currently returns only ids/addresses/times/status for the
  /// volunteer's deliveries — food name, provider name and NGO name are NOT
  /// joined onto the row — so this uses the pickup/delivery addresses and an
  /// honest generic food label. (Known backend limitation; see report.)
  factory DeliveryOpportunity.fromBackend(
    Map<String, dynamic> json, {
    double? viewerLatitude,
    double? viewerLongitude,
  }) {
    final pickup = DateTime.tryParse(json['pickup_time']?.toString() ?? '');
    final donationValue = json['donation'];
    final providerValue = json['provider'];
    final ngoValue = json['ngo'];
    final claimValue = json['claim'];
    final coordinationValue = json['transport_coordination'];
    final volunteerValue = json['volunteer'];
    final donationMap = donationValue is Map
        ? Map<String, dynamic>.from(donationValue)
        : <String, dynamic>{};
    final providerMap = providerValue is Map
        ? Map<String, dynamic>.from(providerValue)
        : <String, dynamic>{};
    final ngoMap = ngoValue is Map
        ? Map<String, dynamic>.from(ngoValue)
        : <String, dynamic>{};
    final claimMap = claimValue is Map
        ? Map<String, dynamic>.from(claimValue)
        : <String, dynamic>{};
    final coordinationMap = coordinationValue is Map
        ? Map<String, dynamic>.from(coordinationValue)
        : <String, dynamic>{};
    final volunteerMap = volunteerValue is Map
        ? Map<String, dynamic>.from(volunteerValue)
        : <String, dynamic>{};
    final donation = donationMap.isEmpty
        ? null
        : Donation.fromBackend(
            donationMap..['claim_status'] = claimMap['status'],
            includePrivateContacts: true,
          );
    final latitude = _coordinateFromMap(json, 'pickup_latitude', 90) ??
        _coordinateFromMap(donationMap, 'latitude', 90) ??
        _coordinateFromMap(json, 'latitude', 90);
    final longitude = _coordinateFromMap(json, 'pickup_longitude', 180) ??
        _coordinateFromMap(donationMap, 'longitude', 180) ??
        _coordinateFromMap(json, 'longitude', 180);
    final dropoffLatitude = _coordinateFromMap(json, 'dropoff_latitude', 90) ??
        _coordinateFromMap(ngoMap, 'latitude', 90);
    final dropoffLongitude =
        _coordinateFromMap(json, 'dropoff_longitude', 180) ??
            _coordinateFromMap(ngoMap, 'longitude', 180);
    // Only a real straight-line figure when BOTH the pickup pin and the
    // volunteer's own stored location are known; otherwise it stays null so the
    // UI shows an honest "—" instead of a fake 0 km.
    final distanceKm =
        haversineKm(viewerLatitude, viewerLongitude, latitude, longitude);
    return DeliveryOpportunity(
      id: json['id']?.toString() ?? '',
      providerName: providerMap['organization_name']?.toString() ??
          readableAddressOrUnavailable(json['pickup_address']?.toString()),
      ngoName: ngoMap['organization_name']?.toString() ??
          readableAddressOrUnavailable(json['delivery_address']?.toString()),
      foodName: donationMap['food_name']?.toString() ?? 'Food pickup',
      quantityKg: (donationMap['quantity'] as num?)?.toDouble() ?? 0,
      distanceKm: distanceKm,
      deadline: pickup == null ? '' : _timeLabel(pickup),
      status: _deliveryStatusFromBackend(json['status']?.toString()),
      latitude: latitude,
      longitude: longitude,
      dropoffLatitude: dropoffLatitude,
      dropoffLongitude: dropoffLongitude,
      pickupAddress: json['pickup_address']?.toString() ??
          donationMap['pickup_address']?.toString() ??
          '',
      dropoffAddress: json['delivery_address']?.toString() ?? '',
      provider: providerMap,
      ngo: ngoMap,
      coordination: coordinationMap,
      volunteer: volunteerMap,
      donation: donation,
    );
  }
}

/// Food-pickup marker points for an NGO home map: every available donation
/// that actually carries coordinates, each labelled with its food name.
///
/// When [ngoPoint] is supplied and usable it is prepended as the NGO's own
/// destination pin, which renders in a distinct hue.
List<SahaayMapPoint> ngoHomeMapPoints(
  List<Donation> donations, {
  SahaayMapPoint? ngoPoint,
}) {
  final points = <SahaayMapPoint>[];
  if (ngoPoint != null && ngoPoint.isUsable) points.add(ngoPoint);
  for (final donation in donations) {
    final latitude = donation.latitude;
    final longitude = donation.longitude;
    if (latitude == null || longitude == null) continue;
    final point = SahaayMapPoint(
      latitude: latitude,
      longitude: longitude,
      title: donation.foodName,
      snippet: readableAddressOrUnavailable(donation.providerAddress),
    );
    if (point.isUsable) points.add(point);
  }
  return points;
}

/// Resolves the signed-in NGO's own destination pin from a `GET /profile`
/// response (which or one of their list-shaped joins). Returns null — and the
/// map shows the honest unavailable state — when no usable coordinates exist.
SahaayMapPoint? ngoMapPointFromProfile(Map<String, dynamic> json) {
  final raw = json['profile'];
  Map<String, dynamic>? profileMap;
  if (raw is List && raw.isNotEmpty && raw.first is Map) {
    profileMap = Map<String, dynamic>.from(raw.first as Map);
  } else if (raw is Map) {
    profileMap = Map<String, dynamic>.from(raw);
  }
  if (profileMap == null) return null;
  final latitude = _coordinateFromMap(profileMap, 'latitude', 90);
  final longitude = _coordinateFromMap(profileMap, 'longitude', 180);
  if (latitude == null || longitude == null) return null;
  final name = profileMap['organization_name']?.toString() ?? '';
  return SahaayMapPoint(
    latitude: latitude,
    longitude: longitude,
    title: name.isEmpty ? null : name,
    snippet: 'Your NGO',
    markerHue: SahaayMapPoint.destinationHue,
  );
}

/// An open delivery that no volunteer has accepted yet, published after both
/// claim participants explicitly decline transport.
///
/// Every field comes from a real database row joined by
/// `GET /deliveries/transport-required`. Nothing is fabricated, and a missing
/// value is shown as unknown rather than filled in with a placeholder.
class VolunteerTransportTask {
  final String id;
  final String pickupAddress;
  final String deliveryAddress;

  final String? foodName;
  final String? providerName;
  final String? ngoName;
  final double? quantityKg;
  final String? unit;
  final int? servings;
  final String? vegType;
  final DateTime? pickupDeadline;
  final DateTime? expiresAt;
  final DateTime? preparedAt;
  final DateTime? createdAt;
  final String? description;
  final String? category;
  final String? foodImageUrl;
  final String? freshness;
  final String? donationStatus;
  final String? claimStatus;
  final double? pickupLatitude;
  final double? pickupLongitude;
  final double? dropoffLatitude;
  final double? dropoffLongitude;
  final String? providerAddress;
  final String? providerPhone;
  final String? ngoAddress;
  final String? ngoPhone;
  final String? notes;

  const VolunteerTransportTask({
    required this.id,
    required this.pickupAddress,
    required this.deliveryAddress,
    this.foodName,
    this.providerName,
    this.ngoName,
    this.quantityKg,
    this.unit,
    this.servings,
    this.vegType,
    this.pickupDeadline,
    this.expiresAt,
    this.preparedAt,
    this.createdAt,
    this.description,
    this.category,
    this.foodImageUrl,
    this.freshness,
    this.donationStatus,
    this.claimStatus,
    this.pickupLatitude,
    this.pickupLongitude,
    this.dropoffLatitude,
    this.dropoffLongitude,
    this.providerAddress,
    this.providerPhone,
    this.ngoAddress,
    this.ngoPhone,
    this.notes,
  });

  factory VolunteerTransportTask.fromBackend(Map<String, dynamic> json) {
    final donation = json['donation'];
    final provider = json['provider'];
    final ngo = json['ngo'];
    final donationMap = donation is Map
        ? Map<String, dynamic>.from(donation)
        : const <String, dynamic>{};
    final providerMap = provider is Map
        ? Map<String, dynamic>.from(provider)
        : const <String, dynamic>{};
    final ngoMap =
        ngo is Map ? Map<String, dynamic>.from(ngo) : const <String, dynamic>{};
    final quantity = donationMap['quantity'];
    final servings = donationMap['servings'];
    return VolunteerTransportTask(
      id: json['id']?.toString() ?? '',
      pickupAddress: readableAddressOrUnavailable(
        _addressWithCity(
          json['pickup_address'] ?? donationMap['pickup_address'],
          providerMap['city'],
        ),
      ),
      deliveryAddress: readableAddressOrUnavailable(
        _addressWithCity(
          json['delivery_address'] ?? ngoMap['address'],
          ngoMap['city'],
        ),
      ),
      foodName: donationMap['food_name']?.toString(),
      providerName: providerMap['organization_name']?.toString(),
      ngoName: ngoMap['organization_name']?.toString(),
      quantityKg: quantity is num ? quantity.toDouble() : null,
      unit: donationMap['unit']?.toString(),
      servings: servings is num ? servings.toInt() : null,
      vegType: donationMap['veg_type']?.toString(),
      description: donationMap['description']?.toString(),
      category: donationMap['food_category']?.toString(),
      foodImageUrl: donationMap['food_image_url']?.toString(),
      freshness: donationMap['freshness']?.toString() ??
          donationMap['freshness_label']?.toString(),
      donationStatus: donationMap['status']?.toString(),
      claimStatus:
          (json['claim'] is Map ? (json['claim'] as Map)['status'] : null)
              ?.toString(),
      pickupDeadline: DateTime.tryParse(json['pickup_time']?.toString() ??
          donationMap['pickup_deadline']?.toString() ??
          ''),
      expiresAt:
          DateTime.tryParse(donationMap['expiry_time']?.toString() ?? ''),
      preparedAt:
          DateTime.tryParse(donationMap['prepared_at']?.toString() ?? ''),
      createdAt: DateTime.tryParse(donationMap['created_at']?.toString() ?? ''),
      pickupLatitude: _coordinateFromMap(json, 'pickup_latitude', 90) ??
          _coordinateFromMap(donationMap, 'latitude', 90),
      pickupLongitude: _coordinateFromMap(json, 'pickup_longitude', 180) ??
          _coordinateFromMap(donationMap, 'longitude', 180),
      dropoffLatitude: _coordinateFromMap(json, 'dropoff_latitude', 90) ??
          _coordinateFromMap(ngoMap, 'latitude', 90),
      dropoffLongitude: _coordinateFromMap(json, 'dropoff_longitude', 180) ??
          _coordinateFromMap(ngoMap, 'longitude', 180),
      providerAddress: providerMap['address']?.toString(),
      providerPhone: providerMap['phone']?.toString(),
      ngoAddress: ngoMap['address']?.toString(),
      ngoPhone: ngoMap['phone']?.toString(),
      notes: json['notes']?.toString(),
    );
  }

  /// "10 kg" or "40 servings", whichever the donation actually recorded. Null
  /// when the backend has no quantity, rather than a fabricated number.
  String? get quantityLabel {
    if (quantityKg != null) {
      final amount = quantityKg == quantityKg!.roundToDouble()
          ? quantityKg!.toStringAsFixed(0)
          : quantityKg!.toStringAsFixed(1);
      return '$amount ${unit ?? 'kg'}';
    }
    if (servings != null) return '$servings servings';
    return null;
  }

  /// True for tasks returned by the backend's volunteer-search endpoint.
  bool get volunteerRequired => true;
}

enum NotificationCategory { donation, matching, volunteer, reward, system }

/// Single source of truth mapping a notification `type` onto its icon category.
/// Used both for the in-app list rows (which carry the backend's real `type`
/// column) and for push payloads, so the two never drift. Anything unrecognised
/// is an honest `system` update rather than an invented category.
NotificationCategory notificationCategoryForType(String? type) {
  switch (type) {
    case 'donation':
    case 'donation_created':
    case 'new_nearby_donation':
      return NotificationCategory.donation;
    case 'claim':
    case 'claim_created':
    case 'claim_status':
    case 'claim_submitted':
    case 'claim_rejected':
    case 'claim_cancelled':
    case 'claim_completed':
    case 'claim_escalation':
    case 'donation_claimed':
    case 'donation_offer':
    case 'donation_offers_exhausted':
    case 'donation_no_match':
      return NotificationCategory.matching;
    case 'delivery':
    case 'delivery_status':
    case 'volunteer_transport':
    case 'volunteer_assigned':
    case 'pickup_updated':
    case 'delivery_completed':
    case 'delivery_failed':
    case 'handover':
    case 'handover_verified':
    case 'handover_completed':
    case 'acknowledgment_ready':
      return NotificationCategory.volunteer;
    case 'ngo_demo_verification':
      return NotificationCategory.system;
    case 'reward':
      return NotificationCategory.reward;
    default:
      return NotificationCategory.system;
  }
}

/// Maps a push payload onto the in-app notification list. The backend sends a
/// `type` in the data block (donation/claim/delivery/handover); anything
/// unrecognised is a system update rather than an invented category.
({String title, String body, NotificationCategory category})
    notificationTapContent(RemoteMessage message) {
  final type = message.data['type']?.toString();
  final category = notificationCategoryForType(type);
  final copy = safeNotificationCopy(
    message.notification?.title ?? message.data['title']?.toString(),
    message.notification?.body ?? message.data['body']?.toString(),
    fallbackBody: notificationFallbackBodyForType(type),
  );
  return (
    title: copy.title,
    body: copy.body,
    category: category,
  );
}

class AppNotificationItem {
  final String? id; // backend notification id (null for local session ones)
  final String? relatedDonationId;
  final String title;
  final String body;
  final String time;
  final NotificationCategory category;
  bool read;
  AppNotificationItem({
    this.id,
    this.relatedDonationId,
    required this.title,
    required this.body,
    required this.time,
    this.category = NotificationCategory.system,
    this.read = false,
  });
}

/// One real entry on the Public Impact Leaderboard (FR-19). Every field is
/// read from the backend's aggregation of `impact_records` for completed
/// donations — there are no invented points and no placeholder organizations.
class LeaderboardEntry {
  final int rank;
  final String name;
  final String city;
  final String type; // 'provider' | 'ngo'
  final double kgRedistributed;
  final int mealsRescued;
  final int donations;

  LeaderboardEntry({
    required this.rank,
    required this.name,
    required this.city,
    required this.type,
    required this.kgRedistributed,
    required this.mealsRescued,
    required this.donations,
  });

  factory LeaderboardEntry.fromBackend(Map<String, dynamic> json) {
    return LeaderboardEntry(
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? 'Unnamed organization',
      city: json['city']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      kgRedistributed: (json['kg_redistributed'] as num?)?.toDouble() ?? 0,
      mealsRescued: (json['meals_rescued'] as num?)?.toInt() ?? 0,
      donations: (json['donations'] as num?)?.toInt() ?? 0,
    );
  }
}

class RewardBadge {
  final String name;
  final IconData icon;
  final bool earned;
  RewardBadge(this.name, this.icon, this.earned);
}

// =============================================================================
// DAILY FOOD ENTRY — a provider's per-day food log + its AI prediction.
// This is NOT a donation: no quantity/servings, address, expiry, deadline,
// status, NGO or photo. It exists so a provider must report what they prepared
// and sold today before the dashboard is reachable, and so the existing AI
// surplus-prediction service is called with a real daily observation.
//
// The BACKEND is authoritative. `DailyFoodEntry.fromToday` returns null only
// when the server says today's entry is missing; the client never decides that
// from a local clock.
// =============================================================================

class DailyFoodEntry {
  final String id;
  final String entryDate;
  final String foodCategory;
  final double foodPreparedKg;
  final double foodSoldKg;
  final String? mealType;

  /// The AI block exactly as the backend returned it. Null when the entry
  /// exists but no prediction could be produced (AI unreachable, etc.).
  final Map<String, dynamic>? prediction;

  const DailyFoodEntry({
    required this.id,
    required this.entryDate,
    required this.foodCategory,
    required this.foodPreparedKg,
    required this.foodSoldKg,
    this.mealType,
    this.prediction,
  });

  /// Parses a `GET /api/v1/daily-food/today` body. Returns null when the server
  /// reports the entry is still required (this is the gate signal).
  static DailyFoodEntry? fromToday(Map<String, dynamic> body) {
    if (body['entry_required'] == true) return null;
    final entry = body['data'];
    if (entry is! Map<String, dynamic>) return null;
    return DailyFoodEntry._fromEntry(entry, body['prediction']);
  }

  /// Parses a `POST /api/v1/daily-food` body, which is the entry row itself
  /// plus a `prediction` block.
  static DailyFoodEntry fromCreateResponse(Map<String, dynamic> body) =>
      DailyFoodEntry._fromEntry(body, body['prediction']);

  factory DailyFoodEntry._fromEntry(
      Map<String, dynamic> entry, dynamic prediction) {
    return DailyFoodEntry(
      id: entry['id']?.toString() ?? '',
      entryDate: entry['entry_date']?.toString() ?? '',
      foodCategory: entry['food_category']?.toString() ?? '',
      foodPreparedKg: _asDouble(entry['food_prepared_kg']),
      foodSoldKg: _asDouble(entry['food_sold_kg']),
      mealType: entry['meal_type']?.toString(),
      prediction: prediction is Map<String, dynamic> ? prediction : null,
    );
  }

  /// True only when the backend actually stored a prediction for this entry.
  bool get hasPrediction => prediction?['status'] == 'saved';

  /// 'saved' | 'skipped' | 'error' | 'unavailable' — whatever the backend said.
  String? get predictionStatus => prediction?['status']?.toString();

  /// The backend's explanation when a prediction is not available.
  String? get predictionReason => prediction?['reason']?.toString();

  double? get predictedSurplusKg => hasPrediction
      ? _asDoubleOrNull(prediction?['predicted_surplus_kg'])
      : null;

  double? get recommendedPrepareKg => hasPrediction
      ? _asDoubleOrNull(prediction?['recommended_prepare_kg'])
      : null;

  String? get preparationRecommendation =>
      prediction?['preparation_recommendation']?.toString();

  String? get predictionDate => prediction?['prediction_date']?.toString();

  String? get modelVersion => prediction?['model_version']?.toString();
}

double _asDouble(dynamic value) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

double? _asDoubleOrNull(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
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
// APP STATE — theme mode + authenticated session. Centralized on purpose so the
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
  ProfileCompletion? profileCompletion;

  // Push-notification state. The token is registered with the backend once the
  // user is signed in; a tap that arrives before login is held until the role
  // is known so it can be routed.
  String? fcmToken;
  Map<String, dynamic>? _pendingNotificationData;
  bool _pendingLocalNotificationTap = false;

  /// The signed-in organization's real WGS-84 location, read from the role
  /// profile join on `GET /profile`. Null until a profile with stored
  /// coordinates has been loaded.
  double? userLatitude;
  double? userLongitude;

  /// Whether the signed-in organization opted into the public leaderboard
  /// (`users.leaderboard_public`, default false). Mirrors the value the
  /// backend returns on `GET /profile`.
  bool leaderboardPublic = false;

  /// The signed-in user's saved profile photo URL (`users.profile_image_url`),
  /// surfaced on every avatar in the app. Null when none was uploaded, so the
  /// fallback icon/initial is shown instead.
  String? currentProfileImageUrl;

  // Real, session-based notifications — generated only from actual actions
  // the signed-in user takes (creating a donation, claiming one, accepting
  // or completing a delivery). Never pre-seeded with invented content.
  final List<AppNotificationItem> notifications = [];

  AppState(this.authService) {
    ready = _initializeAuth();
    _initializeFcm().ignore();
  }

  /// Backend API access — adds the Firebase ID token as a Bearer header on
  /// every request. Dashboards read this through [context.read<AppState>()].
  ApiService get api => authService.api;

  /// True when Firebase has an authenticated user, regardless of whether a
  /// SAHAAY `users` row exists yet (e.g. a brand-new Google user mid-enrollment).
  bool get hasFirebaseUser => authService.hasFirebaseUser;

  Future<void> _initializeAuth() async {
    // Initialize with a timeout so startup never hangs on a slow backend.
    // If the profile fetch takes too long, we still transition the user out
    // of the splash — they can refresh their profile from the login screen.
    await _initializeAuthWithTimeout().timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        // Timeout is not a failure — proceed with whatever we have so far.
        return null;
      },
    );
    _applyProfile(null); // will be re-applied when the auth stream delivers
    notifyListeners();
  }

  /// Returns the profile from the auth service, bounded by a timeout.
  Future<AuthProfile?> _initializeAuthWithTimeout() async {
    final result = <AuthProfile?>[];
    final completer = Completer<AuthProfile?>();
    // Race: first to complete wins — the asyncMap stream or our timeout.
    _authSubscription = authService.authStateChanges.listen((profile) {
      _applyProfile(profile);
      notifyListeners();
      completer.complete(profile);
    }, onError: (Object _) {
      _applyProfile(null);
      notifyListeners();
      if (!completer.isCompleted) completer.complete(null);
    });
    // Fetch the initial profile with a timeout.
    try {
      final profile = await authService.currentProfile.timeout(
        const Duration(seconds: 10),
        onTimeout: () => null,
      );
      result.add(profile);
    } catch (_) {
      result.add(null);
    }
    // If the stream fires before the timeout, it already re-applied the profile
    // (the listener calls _applyProfile and notifyListeners). If not, the timeout
    // result will be applied below.
    if (completer.isCompleted) {
      // Stream already applied it; no further action needed.
    } else {
      _applyProfile(result.isNotEmpty ? result.first : null);
      notifyListeners();
    }
    return result.isNotEmpty ? result.first : null;
  }

  void _applyProfile(AuthProfile? profile) {
    if (profile == null) {
      isLoggedIn = false;
      currentRole = null;
      currentName = '';
      currentOrgLabel = '';
      profileCompletion = null;
      userLatitude = null;
      userLongitude = null;
      leaderboardPublic = false;
      currentProfileImageUrl = null;
      fcmToken = null;
      _pendingNotificationData = null;
      return;
    }
    final role = UserRole.values
        .where((value) => value.name == profile.role)
        .firstOrNull;
    if (role == null) return;
    currentRole = role;
    currentName = profile.fullName;
    currentOrgLabel = profile.orgLabel;
    profileCompletion = profile.profileCompletion;
    userLatitude = profile.latitude;
    userLongitude = profile.longitude;
    leaderboardPublic = profile.leaderboardPublic;
    currentProfileImageUrl = profile.profileImageUrl;
    isLoggedIn = true;
    refreshFcmTokenRegistration().ignore();
    final pending = _pendingNotificationData;
    if (pending != null) {
      _pendingNotificationData = null;
      scheduleMicrotask(() => _handleNotificationData(pending));
    }
    if (_pendingLocalNotificationTap) {
      _pendingLocalNotificationTap = false;
      scheduleMicrotask(_openNotificationsFromTap);
    }
  }

  /// Subscribes to FCM token refresh and incoming messages, and routes a
  /// notification tap into the app. Every step is best-effort.
  Future<void> _initializeFcm() async {
    try {
      PushNotifications.onNotificationTap = (payload) {
        if (payload != null && payload.isNotEmpty) {
          try {
            final decoded = jsonDecode(payload);
            if (decoded is Map) {
              _handleNotificationData(
                Map<String, dynamic>.from(decoded),
              );
              return;
            }
          } on FormatException {
            // Older local notification payloads carried only the type.
          }
        }
        if (!isLoggedIn || currentRole == null) {
          _pendingLocalNotificationTap = true;
          return;
        }
        _openNotificationsFromTap();
      };
      FirebaseMessaging.instance.onTokenRefresh.listen((token) {
        if (token.isNotEmpty) {
          registerFcmTokenWithBackend(token, PushNotifications.platform)
              .ignore();
        }
      });
      // A foreground push is not shown by the system, so render it ourselves on
      // the audible channel and record it in the in-app list.
      FirebaseMessaging.onMessage.listen((message) {
        PushNotifications.showForeground(message);
        final content = notificationTapContent(message);
        pushNotification(content.title, content.body, content.category);
      });
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _handleNotificationTap(initial);
      FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
              alert: true, badge: true, sound: true);
    } catch (_) {
      // Push must never block normal app use.
    }
  }

  /// Requests permission and registers this device's FCM token with the
  /// backend. Safe to call on every profile load.
  Future<void> refreshFcmTokenRegistration() async {
    if (!isLoggedIn) return;
    try {
      final permission =
          await activePermissionService().status(AppPermission.notifications);
      if (permission != PermissionOutcome.granted &&
          permission != PermissionOutcome.notRequired) {
        return;
      }
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      await registerFcmTokenWithBackend(token, PushNotifications.platform);
    } catch (_) {
      // Best-effort.
    }
  }

  Future<void> registerFcmTokenWithBackend(
      String token, String platform) async {
    if (!isLoggedIn) return;
    try {
      await api.registerFcmToken(token, platform);
      fcmToken = token;
      notifyListeners();
    } catch (_) {
      // Best-effort.
    }
  }

  void _handleNotificationTap(RemoteMessage message) {
    _handleNotificationData(message.data);
  }

  void _handleNotificationData(Map<String, dynamic> data) {
    if (!isLoggedIn || currentRole == null) {
      _pendingLocalNotificationTap = true;
      return;
    }
    final donationId = data['donation_id']?.toString();
    if (donationId != null &&
        donationId.isNotEmpty &&
        (currentRole == UserRole.provider || currentRole == UserRole.ngo)) {
      _openClaimFromNotification(donationId).ignore();
      return;
    }
    _openNotificationsFromTap();
  }

  Future<void> _openClaimFromNotification(String donationId) async {
    final role = currentRole;
    if (role != UserRole.provider && role != UserRole.ngo) {
      _openNotificationsFromTap();
      return;
    }
    try {
      final claims = role == UserRole.provider
          ? await api.getProviderClaims()
          : await api.getClaims();
      for (final raw in claims) {
        if (raw is! Map || raw['donation_id']?.toString() != donationId) {
          continue;
        }
        final claim = Map<String, dynamic>.from(raw);
        final donationValue = claim['donation'];
        if (donationValue is! Map) break;
        final donation = Donation.fromBackend(
          Map<String, dynamic>.from(donationValue),
          includePrivateContacts: true,
        );
        final page = role == UserRole.provider
            ? ProviderClaimedDonationScreen(donation: donation)
            : ClaimedDonationDashboard(donation: donation);
        _appNavigatorKey.currentState?.push(
          MaterialPageRoute<void>(builder: (_) => page),
        );
        return;
      }
      _openNotificationsFromTap();
    } on ApiException {
      _openNotificationsFromTap();
    }
  }

  void _openNotificationsFromTap() {
    final role = currentRole;
    if (role != null) {
      _appNavigatorKey.currentState?.push(MaterialPageRoute<void>(
        builder: (_) => NotificationsScreen(role: role),
      ));
    }
  }

  /// Reloads the signed-in profile from the backend and reapplies it. Called
  /// after Edit Profile saves, so maps, distance and greetings refresh too.
  /// A null profile (e.g. profile endpoint unreachable) leaves the current
  /// session untouched instead of signing the user out.
  Future<AuthProfile?> refreshProfile() async {
    final profile = await authService.currentProfile;
    if (profile != null) _applyProfile(profile);
    notifyListeners();
    return profile;
  }

  void updateProfileCompletionFromResponse(Map<String, dynamic> response) {
    final backend = response['profile_completion'];
    if (backend is Map) {
      profileCompletion =
          ProfileCompletion.fromBackend(Map<String, dynamic>.from(backend));
    } else {
      final role = response['role']?.toString() ?? currentRole?.name ?? '';
      profileCompletion = ProfileCompletion.calculate(
        role: role,
        account: response,
        roleProfile: _roleProfileMap(response['profile']),
      );
    }
    notifyListeners();
  }

  /// Persists the signed-in organization's public-leaderboard visibility and
  /// updates the cached session value so the Settings toggle stays in sync.
  Future<void> setLeaderboardPublic(bool value) async {
    await api.setLeaderboardVisibility(value);
    leaderboardPublic = value;
    notifyListeners();
  }

  /// Destination pin for the signed-in organization on map cards. Null when
  /// the loaded profile has no usable coordinates, so maps show the honest
  /// "location unavailable" state instead of a guessed pin.
  SahaayMapPoint? get ngoMapPoint {
    final latitude = userLatitude;
    final longitude = userLongitude;
    if (latitude == null || longitude == null) return null;
    final point = SahaayMapPoint(
      latitude: latitude,
      longitude: longitude,
      title: currentOrgLabel.isEmpty ? null : currentOrgLabel,
      snippet: 'Your location',
      markerHue: SahaayMapPoint.destinationHue,
    );
    return point.isUsable ? point : null;
  }

  Future<void> login(String email, String password) async {
    _applyProfile(await authService.signIn(email: email, password: password));
    notifyListeners();
  }

  /// Google OAuth via Firebase. Returns the loaded [AuthProfile] when the
  /// user is an existing SAHAAY member, or `null` when the user cancelled the
  /// Google picker OR when the Firebase session has no SAHAAY profile yet
  /// (caller should route `hasFirebaseUser == true` into enrollment).
  Future<AuthProfile?> loginWithGoogle() async {
    final profile = await authService.signInWithGoogle();
    if (profile != null) _applyProfile(profile);
    notifyListeners();
    return profile;
  }

  /// Completes first-time enrollment for an already-Firebase-authenticated
  /// (Google) user — role selection + existing profile form -> POST /api/v1/profile.
  Future<void> enroll({
    required UserRole role,
    required String fullName,
    required String orgLabel,
    String? phone,
    Map<String, dynamic>? roleProfile,
  }) async {
    _applyProfile(await authService.completeEnrollment(
      role: role.name,
      fullName: fullName,
      orgLabel: orgLabel,
      phone: phone,
      roleProfile: roleProfile,
    ));
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
    try {
      await authService.signOut();
    } finally {
      _applyProfile(null);
      notifications.clear();
      notifyListeners();
    }
  }

  void pushNotification(
      String title, String body, NotificationCategory category) {
    final copy = safeNotificationCopy(title, body);
    notifications.insert(
        0,
        AppNotificationItem(
            title: copy.title,
            body: copy.body,
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
            navigatorKey: _appNavigatorKey,
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

  /// Retained for backwards compatibility and tests. SAHAAY's brand treatment
  /// is the standalone S mark only, so this no longer selects a different
  /// asset: the wordmark/tagline are never rendered as part of the logo.
  final bool showWordmark;

  const SahaayLogo({super.key, this.size = 96, this.showWordmark = false});

  /// The one official logo asset: the original S artwork with a genuine
  /// transparent background (RGBA). Preserved exactly as supplied — never
  /// redrawn, recoloured or cropped.
  static const String assetPath = 'assets/images/sahaay_icon_transparent.png';

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    // The S sits directly on the screen background: no white canvas, card,
    // padding or shadow. Transparency comes from the asset itself, so the
    // mark reads cleanly on both light and dark backgrounds.
    return Image.asset(
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
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[
                  Icon(icon, size: 20),
                  const SizedBox(width: 8)
                ],
                Text(label),
              ]),
            ),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  /// Optional leading raster brand mark (e.g. the multicolour Google G). When
  /// set it takes precedence over [icon].
  final String? imageAsset;
  final bool isLoading;
  const SecondaryButton(
      {super.key,
      required this.label,
      required this.onPressed,
      this.icon,
      this.imageAsset,
      this.isLoading = false});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: isLoading ? null : onPressed,
      child: isLoading
          ? const SizedBox(
              height: 22,
              width: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4))
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (imageAsset != null) ...[
                  Image.asset(imageAsset!, width: 20, height: 20),
                  const SizedBox(width: 8),
                ] else if (icon != null) ...[
                  Icon(icon, size: 20),
                  const SizedBox(width: 8)
                ],
                Text(label),
              ]),
            ),
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
              ReadableAddressText(
                address: donation.providerAddress,
                latitude: donation.latitude,
                longitude: donation.longitude,
                style: TextStyle(color: c.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _miniInfo(context, Icons.scale_outlined,
                      '${donation.quantityKg.toStringAsFixed(0)} kg • ${donation.servings} servings'),
                  _miniInfo(
                    context,
                    Icons.near_me_outlined,
                    straightLineDistanceLabel(donation.distanceKm) ??
                        'Distance unavailable',
                  ),
                  if (donation.expiryLabel.isNotEmpty)
                    _miniInfo(
                        context, Icons.schedule_outlined, donation.expiryLabel),
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
/// Shared avatar that shows the real saved profile photo when one exists and
/// only falls back to an icon/initial when it genuinely does not. Used by the
/// dashboard header and the Profile screen so an uploaded picture appears
/// everywhere instead of a hard-coded person icon.
class SahaayAvatar extends StatelessWidget {
  final double radius;
  final String? imageUrl;
  final String? fallbackText;
  final IconData fallbackIcon;
  final Color? backgroundColor;
  final Color? foregroundColor;

  const SahaayAvatar({
    super.key,
    this.radius = 18,
    this.imageUrl,
    this.fallbackText,
    this.fallbackIcon = Icons.person,
    this.backgroundColor,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim();
    final hasImage = url != null && url.isNotEmpty;
    final foreground = foregroundColor ?? Colors.white;
    final initial = (fallbackText ?? '').trim();
    final Widget fallback = initial.isNotEmpty
        ? Text(initial[0].toUpperCase(),
            style: TextStyle(
                color: foreground,
                fontWeight: FontWeight.w800,
                fontSize: radius * 0.8))
        : Icon(fallbackIcon, color: foreground, size: radius * 1.1);
    return CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor ?? Colors.white24,
      child: hasImage
          ? ClipOval(
              child: Image.network(
                url,
                width: radius * 2,
                height: radius * 2,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => fallback,
              ),
            )
          : fallback,
    );
  }
}

class DashboardHeader extends StatelessWidget {
  final String greeting;
  final String subtitle;
  final String roleLabel;
  final String? imageUrl;
  final VoidCallback onNotificationTap;
  final VoidCallback onProfileTap;
  const DashboardHeader({
    super.key,
    required this.greeting,
    required this.subtitle,
    required this.roleLabel,
    required this.onNotificationTap,
    required this.onProfileTap,
    this.imageUrl,
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
              child: SahaayAvatar(radius: 18, imageUrl: imageUrl),
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

/// Content-sized two-column grid of [ImpactCard]s. A [Wrap] lets each card be
/// only as tall as its own text requires, instead of a fixed aspect ratio that
/// clipped the bottom row of the label on narrow screens or larger font scales
/// (the reported "BOTTOM OVERFLOWED BY 16 PIXELS").
class ImpactCardGrid extends StatelessWidget {
  final List<ImpactCard> cards;
  const ImpactCardGrid({super.key, required this.cards});

  @override
  Widget build(BuildContext context) {
    const spacing = 10.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - spacing) / 2;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: cards
              .map((card) => SizedBox(width: itemWidth, child: card))
              .toList(),
        );
      },
    );
  }
}

/// AI result card — food surplus prediction. Shows a real result once the
/// FastAPI prediction service is connected; until then it honestly shows
/// a pending state rather than any invented numbers.
/// AI Food Surplus Prediction — renders the REAL prediction the backend
/// returned for today's daily food entry. There are no placeholder numbers
/// here: every value shown comes from the AI service response, and a failed
/// prediction renders as a clear, non-crashing error state instead.
class SurplusPredictionCard extends StatelessWidget {
  /// Today's entry, or null when the server says it is still required.
  final DailyFoodEntry? entry;

  /// Re-reads today's entry from the backend. Used by the failed-prediction
  /// state so the provider can retry without leaving the dashboard.
  final Future<void> Function()? onRefresh;
  final bool refreshing;
  final String? refreshError;

  const SurplusPredictionCard({
    super.key,
    this.entry,
    this.onRefresh,
    this.refreshing = false,
    this.refreshError,
  });

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
              if (entry?.hasPrediction == true && entry?.modelVersion != null)
                Text(entry!.modelVersion!,
                    style: TextStyle(
                        fontSize: 10,
                        color: c.textSecondary,
                        letterSpacing: 0.3)),
            ]),
            const SizedBox(height: 12),
            ..._body(context, c),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, AppColors c) {
    if (entry == null) {
      return [
        Row(children: [
          Icon(Icons.hourglass_empty, size: 16, color: c.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "Today's food entry has not been submitted yet. Complete the daily food entry to generate a prediction.",
              style: TextStyle(fontSize: 12.5, color: c.textSecondary),
            ),
          ),
        ]),
      ];
    }

    if (!entry!.hasPrediction) {
      return [
        Row(children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: c.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry!.predictionReason ??
                  'The AI prediction is not available for today yet.',
              style: TextStyle(fontSize: 12.5, color: c.textSecondary),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Text(
          'Refresh retries using the saved entry. No forecast is shown if '
          'required inputs are missing.',
          style: TextStyle(fontSize: 12, color: c.textSecondary),
        ),
        if (refreshError != null) ...[
          const SizedBox(height: 8),
          Text(
            refreshError!,
            style: TextStyle(fontSize: 12, color: c.danger),
          ),
        ],
        if (onRefresh != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: refreshing ? null : () => onRefresh!(),
              icon: refreshing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: Text(refreshing ? 'Refreshing…' : 'Refresh'),
              style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            ),
          ),
        ],
      ];
    }

    return [
      Row(children: [
        Expanded(
          child: _metric(
            context,
            c,
            label: 'Predicted surplus',
            value: '${_kg(entry!.predictedSurplusKg)} kg',
            icon: Icons.trending_down,
            strong: true,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _metric(
            context,
            c,
            label: 'Recommended preparation',
            value: '${_kg(entry!.recommendedPrepareKg)} kg',
            icon: Icons.restaurant_outlined,
          ),
        ),
      ]),
      const SizedBox(height: 10),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.lightbulb_outline, size: 16, color: c.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            entry!.preparationRecommendation ?? '',
            style: TextStyle(fontSize: 12.5, color: c.textPrimary),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Icon(Icons.event_outlined, size: 14, color: c.textSecondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Prediction date: ${entry!.predictionDate ?? entry!.entryDate}',
            style: TextStyle(fontSize: 11.5, color: c.textSecondary),
          ),
        ),
      ]),
    ];
  }

  Widget _metric(BuildContext context, AppColors c,
      {required String label,
      required String value,
      required IconData icon,
      bool strong = false}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: strong ? c.bluePrimary.withOpacity(0.10) : c.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 14, color: strong ? c.bluePrimary : c.textSecondary),
          const SizedBox(width: 5),
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 10.5, color: c.textSecondary)),
          ),
        ]),
        const SizedBox(height: 6),
        Text(
          value,
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w800,
            color: strong ? c.bluePrimary : c.textPrimary,
          ),
        ),
      ]),
    );
  }

  /// Formats a backend-supplied kg value, never substituting a default number.
  static String _kg(double? value) =>
      value == null ? '—' : value.toStringAsFixed(1);
}

/// AI result card — NGO/donation weighted match score (FR-13). Renders a
/// real score once the matching engine provides one; until then it shows
/// an honest pending state instead of any invented percentage.
class MatchScoreCard extends StatelessWidget {
  final Map<String, dynamic>? offer;
  const MatchScoreCard({super.key, required this.offer});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final state = context.watch<AppState>();
    final donationValue = offer?['donation'];
    final donation =
        donationValue is Map ? Map<String, dynamic>.from(donationValue) : null;
    final candidateValue = offer?['ranked_candidate'];
    final candidate = candidateValue is Map
        ? Map<String, dynamic>.from(candidateValue)
        : const <String, dynamic>{};
    final detailsValue = candidate['score_details'];
    final details = detailsValue is Map
        ? Map<String, dynamic>.from(detailsValue)
        : const <String, dynamic>{};
    final score = candidate['final_score'];
    final distance = details['distance_km'];
    final hasPendingOffer = offer?['status'] == 'pending';
    final completion = state.profileCompletion;
    final noOfferMessage = completion != null && !completion.isComplete
        ? 'No active ranked offer is available. Complete the required matching details: '
            '${completion.missingFields.join(', ')}.'
        : 'No active ranked offer is currently addressed to this account. '
            'Offers are sent in rank order as earlier offers are resolved.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                donation == null
                    ? 'NGO match score'
                    : 'Recommended: ${donation['food_name'] ?? 'Food donation'}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (hasPendingOffer)
              Text(
                'Saved backend ranking • Rank #${offer?['candidate_rank'] ?? '—'}',
                style: TextStyle(fontSize: 12, color: c.textSecondary),
              ),
            const SizedBox(height: 12),
            Row(children: [
              Icon(Icons.hub_outlined, size: 16, color: c.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hasPendingOffer
                      ? matchScoreLabel(score is num ? score : null)
                      : noOfferMessage,
                  style: TextStyle(fontSize: 12.5, color: c.textSecondary),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              _pill(
                  context,
                  'Distance',
                  matchingDistanceLabel(
                    distance is num ? distance : null,
                    details['distance_source'],
                  )),
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
    // Nullable lookup so the button is safe anywhere it is mounted without an
    // AppState above it (e.g. widget tests, isolated previews). When the state
    // is present its behaviour is unchanged.
    final state = context.watch<AppState?>();
    final isDark = state?.themeMode == ThemeMode.dark;
    return IconButton(
      tooltip: isDark ? 'Switch to light theme' : 'Switch to dark theme',
      icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
      onPressed:
          state == null ? null : () => context.read<AppState>().toggleTheme(),
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
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    // Scene A of the startup animation: the standalone S fades in and gently
    // settles to full size, centred on the existing app background.
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.72, end: 1.0).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
    // Hand over as soon as the entrance animation has played: no artificial
    // delay, so no lingering async timer is left behind.
    _controller.forward().whenComplete(() {
      if (mounted) _navigateNext();
    });
  }

  Future<void> _navigateNext() async {
    // Always transition out of splash within a bounded time, even if AppState.ready
    // takes too long (e.g. backend profile fetch slow/no network). The AppState ready
    // watcher will still update the UI asynchronously after the transition.
    await _safeWaitForReady(
      context.read<AppState>().ready,
      // If ready takes longer than 15s, just transition based on current known state.
      maxWait: const Duration(seconds: 15),
    );
    if (!mounted) return;
    // Authenticated users keep going straight to their role dashboard; signed
    // out users go directly to the animated login screen.
    final destination = context.read<AppState>().isLoggedIn
        ? const RoleRouter()
        : const LoginScreen();
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => destination));
  }

  /// Waits for [future] to complete, but aborts after [maxWait].
  /// Returns the value returned by [future] if it completes in time, otherwise null.
  static Future<T?> _safeWaitForReady<T>(Future<T> future,
      {required Duration maxWait}) async {
    final completer = Completer<T?>();
    final timer = Timer(maxWait, () {
      completer.complete(null);
    });
    try {
      final result = await future;
      timer.cancel();
      completer.complete(result);
      return result;
    } on TimeoutException {
      timer.cancel();
      completer.complete(null);
      return null;
    } catch (_) {
      timer.cancel();
      completer.complete(null);
      return null;
    }
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
          child: ScaleTransition(
            scale: _scale,
            child: const SahaayLogo(size: 140),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// (The former role-selection "welcome" screen was removed from the startup
// flow. Unauthenticated users now land directly on the animated LoginScreen;
// role selection still lives in RoleSelectionScreen during registration.)
// =============================================================================

// =============================================================================
// LOGIN SCREEN
// =============================================================================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;
  bool _isLoading = false;
  bool _googleLoading = false;
  String? _error;

  // Scene B/C/D of the startup animation, continued from the splash: the S
  // rises into place, the enlarged "Welcome back!" heading fades in beneath it,
  // then the form fades in. One finite controller, run once per screen.
  late final AnimationController _intro;
  late final Animation<double> _logoFade;
  late final Animation<Offset> _logoSlide;
  late final Animation<double> _headingFade;
  late final Animation<double> _formFade;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _logoFade = CurvedAnimation(
        parent: _intro,
        curve: const Interval(0.0, 0.45, curve: Curves.easeOut));
    _logoSlide = Tween<Offset>(begin: const Offset(0, 0.45), end: Offset.zero)
        .animate(CurvedAnimation(
            parent: _intro,
            curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic)));
    _headingFade = CurvedAnimation(
        parent: _intro,
        curve: const Interval(0.30, 0.70, curve: Curves.easeOut));
    _formFade = CurvedAnimation(
        parent: _intro,
        curve: const Interval(0.50, 1.0, curve: Curves.easeOut));
    _intro.forward();
  }

  @override
  void dispose() {
    _intro.dispose();
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

  Future<void> _signInWithGoogle() async {
    if (_googleLoading || _isLoading) return; // ignore duplicate taps
    final state = context.read<AppState>();
    setState(() {
      _googleLoading = true;
      _error = null;
    });
    try {
      final profile = await state.loginWithGoogle();
      if (!mounted) return;
      if (profile != null) {
        // Existing SAHAAY user -> straight to their dashboard.
        setState(() => _googleLoading = false);
        Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const RoleRouter()),
            (route) => false);
        return;
      }
      if (!state.hasFirebaseUser) {
        // User cancelled the Google account picker; nothing changed.
        setState(() => _googleLoading = false);
        return;
      }
      // Firebase session exists but no SAHAAY profile -> first-time enrollment.
      setState(() => _googleLoading = false);
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => const RoleSelectionScreen(googleEnrollment: true)));
      if (!mounted) return;
      final refreshed = context.read<AppState>();
      if (!refreshed.isLoggedIn && refreshed.hasFirebaseUser) {
        // Enrollment cancelled/not completed -> leave no orphaned session.
        await refreshed.signOut();
      }
    } on AuthException catch (error) {
      if (mounted) {
        setState(() {
          _googleLoading = false;
          _error = error.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _googleLoading = false;
          _error = 'Something went wrong. Please try again.';
        });
      }
    }
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
                // Scene B: the standalone S rises into the header position.
                FadeTransition(
                  opacity: _logoFade,
                  child: SlideTransition(
                    position: _logoSlide,
                    child: const Center(child: SahaayLogo(size: 76)),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                // Scene C: the enlarged "Welcome back!" heading.
                FadeTransition(
                  opacity: _headingFade,
                  child: Text('Welcome back!',
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(
                              fontSize: 30, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 4),
                FadeTransition(
                  opacity: _headingFade,
                  child: Text('Log in to continue making an impact.',
                      style: TextStyle(color: c.textSecondary)),
                ),
                const SizedBox(height: AppSpacing.lg),
                // Scene D: the existing login form fades in, otherwise unchanged.
                FadeTransition(
                  opacity: _formFade,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
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
                        validator: (v) => (v == null || v.isEmpty)
                            ? 'Password is required'
                            : null,
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
                              style:
                                  TextStyle(color: c.danger, fontSize: 12.5)),
                        ),
                        const SizedBox(height: 10),
                      ],
                      PrimaryButton(
                          label: 'LOGIN',
                          isLoading: _isLoading,
                          onPressed: _login),
                      const SizedBox(height: AppSpacing.sm),
                      SecondaryButton(
                        label: 'Continue with Google',
                        imageAsset: 'assets/icons/google_logo.png',
                        isLoading: _googleLoading,
                        onPressed: _signInWithGoogle,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text("Don't have an account?",
                                style: TextStyle(color: c.textSecondary)),
                            TextButton(
                              onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const RoleSelectionScreen())),
                              child: const Text('Register'),
                            ),
                          ]),
                    ],
                  ),
                ),
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
  /// True when reached from Google first-time enrollment: the Firebase session
  /// already exists and the user only needs to choose a role to complete their
  /// SAHAAY profile. Normal registration always creates the Firebase account.
  final bool googleEnrollment;
  const RoleSelectionScreen({super.key, this.googleEnrollment = false});

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
            Text(
                googleEnrollment
                    ? 'Finish setting up your account'
                    : 'What would you like to do?',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppSpacing.sm),
            if (googleEnrollment) ...[
              Text(
                'You are signed in with Google. Choose a role to create your SAHAAY profile.',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: AppColors.of(context).textSecondary),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            RoleCard(
              icon: Icons.restaurant_outlined,
              title: 'Food Provider',
              subtitle:
                  'Restaurant, hotel, college canteen or caterer donating surplus food.',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => RegisterProviderScreen(
                      googleEnrollment: googleEnrollment))),
            ),
            const SizedBox(height: AppSpacing.md),
            RoleCard(
              icon: Icons.apartment_outlined,
              title: 'NGO',
              subtitle: 'Discover and claim surplus food for your community.',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      RegisterNgoScreen(googleEnrollment: googleEnrollment))),
            ),
            const SizedBox(height: AppSpacing.md),
            RoleCard(
              icon: Icons.volunteer_activism_outlined,
              title: 'Volunteer',
              subtitle:
                  'Optionally help deliver food from providers to NGOs nearby.',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => RegisterVolunteerScreen(
                      googleEnrollment: googleEnrollment))),
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
  const RegisterProviderScreen({super.key, this.googleEnrollment = false});
  final bool googleEnrollment;
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

  // Real coordinates chosen through the location picker. Null until the user
  // picks a place on the map — they never get invented.
  double? _latitude;
  double? _longitude;

  /// Opens SAHAAY's one location picker and adopts whatever real place was
  /// chosen: readable address, city, and coordinates when available.
  Future<void> _chooseLocation() async {
    final result = await showLocationPicker(
      context,
      title: 'Set your location',
      latitude: _latitude,
      longitude: _longitude,
      address: _address.text.trim(),
    );
    if (result == null || !mounted) return;
    setState(() {
      _latitude = result.latitude;
      _longitude = result.longitude;
      _address.text = result.address;
      if (result.city != null && result.city!.trim().isNotEmpty) {
        _city.text = result.city!;
      } else if (result.addressIsCoordinates) {
        _city.text = '';
      }
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!widget.googleEnrollment && _password.text != _confirmPassword.text) {
      _showSnack('Passwords do not match.', isError: true);
      return;
    }
    setState(() => _isLoading = true);
    try {
      if (widget.googleEnrollment) {
        await context.read<AppState>().enroll(
          role: UserRole.provider,
          fullName: _contactPerson.text.trim(),
          orgLabel: _orgName.text.trim(),
          phone: normalizeIndianMobileNumber(_phone.text)!,
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
            'phone': normalizeIndianMobileNumber(_phone.text)!,
            if (_latitude != null) 'latitude': _latitude,
            if (_longitude != null) 'longitude': _longitude,
          },
        );
      } else {
        await context.read<AppState>().register(
          role: UserRole.provider,
          email: _email.text,
          password: _password.text,
          fullName: _contactPerson.text.trim(),
          orgLabel: _orgName.text.trim(),
          phone: normalizeIndianMobileNumber(_phone.text)!,
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
            'phone': normalizeIndianMobileNumber(_phone.text)!,
            if (_latitude != null) 'latitude': _latitude,
            if (_longitude != null) 'longitude': _longitude,
          },
        );
      }
    } on AuthException catch (error) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnack(error.message, isError: true);
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnack(
            'Could not reach SAHAAY. Check your connection and try again.',
            isError: true);
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
                if (!widget.googleEnrollment)
                  AppInputField(
                      label: 'Email',
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      prefixIcon: Icons.email_outlined,
                      validator: _emailValidator),
                if (widget.googleEnrollment) ...[
                  Text(
                    'Signed in with Google — your Gmail will be used as your account email.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: AppColors.of(context).textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
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
                OutlinedButton.icon(
                  onPressed: _chooseLocation,
                  icon: const Icon(Icons.map_outlined),
                  label: Text(_latitude == null
                      ? 'Choose location on map'
                      : 'Location chosen — tap to change'),
                ),
                const SizedBox(height: AppSpacing.md),
                if (!widget.googleEnrollment)
                  AppInputField(
                      label: 'Password',
                      controller: _password,
                      obscureText: true,
                      prefixIcon: Icons.lock_outline,
                      validator: _passwordValidator),
                const SizedBox(height: AppSpacing.md),
                if (!widget.googleEnrollment)
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
const _kDonationFoodTypes = <String, String>{
  'vegetarian': 'Vegetarian',
  'non_vegetarian': 'Non-vegetarian',
  'vegan': 'Vegan',
  'mixed': 'Mixed (vegetarian and non-vegetarian)',
};
const _kDietaryPreferenceLabels = <String, String>{
  'vegetarian': 'Vegetarian',
  'non_vegetarian': 'Non-vegetarian',
  'vegan': 'Vegan',
  'mixed': 'Mixed',
  'any': 'All dietary types',
};

typedef OperatingHoursValue = ({String? from, String? to});

class OperatingHoursFields extends StatelessWidget {
  const OperatingHoursFields({
    super.key,
    required this.value,
    required this.onChanged,
    this.requiredForMatching = false,
  });

  final OperatingHoursValue value;
  final ValueChanged<OperatingHoursValue> onChanged;
  final bool requiredForMatching;

  String _display(String? value) {
    if (value == null) return 'Choose time';
    final parts = value.split(':');
    if (parts.length != 2) return value;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null || hour > 23 || minute > 59) {
      return value;
    }
    final shownHour = hour % 12 == 0 ? 12 : hour % 12;
    return '$shownHour:${minute.toString().padLeft(2, '0')} ${hour < 12 ? 'AM' : 'PM'}';
  }

  Future<void> _choose(BuildContext context, {required bool opening}) async {
    final stored = opening ? value.from : value.to;
    final parts = stored?.split(':');
    final initialTime = parts != null && parts.length == 2
        ? TimeOfDay(
            hour: int.tryParse(parts[0]) ?? 9,
            minute: int.tryParse(parts[1]) ?? 0,
          )
        : const TimeOfDay(hour: 9, minute: 0);
    final selected =
        await showTimePicker(context: context, initialTime: initialTime);
    if (selected == null) return;
    final formatted =
        '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}';
    onChanged((
      from: opening ? formatted : value.from,
      to: opening ? value.to : formatted,
    ));
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            requiredForMatching
                ? 'Operating hours (required for matching)'
                : 'Operating hours',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _choose(context, opening: true),
                  icon: const Icon(Icons.login_outlined),
                  label: Text('Opens: ${_display(value.from)}'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _choose(context, opening: false),
                  icon: const Icon(Icons.logout_outlined),
                  label: Text('Closes: ${_display(value.to)}'),
                ),
              ),
            ],
          ),
          if (value.from != null || value.to != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => onChanged((from: null, to: null)),
                child: const Text('Clear hours'),
              ),
            ),
        ],
      );
}

class RegisterNgoScreen extends StatefulWidget {
  const RegisterNgoScreen({super.key, this.googleEnrollment = false});
  final bool googleEnrollment;
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
  final _maxDonationCapacityKg = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final Set<String> _categories = {};
  final Set<String> _dietaryPreferences = {};
  bool _isLoading = false;
  String? _availableFrom;
  String? _availableTo;

  // Real coordinates chosen through the location picker. Null until the user
  // picks a place on the map — they never get invented.
  double? _latitude;
  double? _longitude;

  /// Opens SAHAAY's one location picker and adopts whatever real place was
  /// chosen: readable address, city, and coordinates when available.
  Future<void> _chooseLocation() async {
    final result = await showLocationPicker(
      context,
      title: 'Set your location',
      latitude: _latitude,
      longitude: _longitude,
      address: _address.text.trim(),
    );
    if (result == null || !mounted) return;
    if (!result.hasCoordinates) {
      _showSnack(
        'Choose a real map pin with coordinates for matching.',
        isError: true,
      );
      return;
    }
    setState(() {
      _latitude = result.latitude;
      _longitude = result.longitude;
      _address.text = result.address;
      if (result.city != null && result.city!.trim().isNotEmpty) {
        _city.text = result.city!;
      } else if (result.addressIsCoordinates) {
        _city.text = '';
      }
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!widget.googleEnrollment && _password.text != _confirmPassword.text) {
      _showSnack('Passwords do not match.', isError: true);
      return;
    }
    final capacityText = _maxDonationCapacityKg.text.trim();
    final maxDonationCapacityKg =
        capacityText.isEmpty ? null : double.tryParse(capacityText);
    if (capacityText.isNotEmpty &&
        (maxDonationCapacityKg == null ||
            !maxDonationCapacityKg.isFinite ||
            maxDonationCapacityKg <= 0)) {
      _showSnack(
        'Enter a positive food weight in kilograms, or leave it blank to configure later.',
        isError: true,
      );
      return;
    }
    setState(() => _isLoading = true);
    try {
      if (widget.googleEnrollment) {
        await context.read<AppState>().enroll(
          role: UserRole.ngo,
          fullName: _contactPerson.text.trim(),
          orgLabel: _ngoName.text.trim(),
          phone: normalizeIndianMobileNumber(_phone.text)!,
          roleProfile: {
            'organization_name': _ngoName.text.trim(),
            'registration_number': _regId.text.trim(),
            'address': _address.text.trim(),
            'city': _city.text.trim(),
            'phone': normalizeIndianMobileNumber(_phone.text)!,
            if (_capacity.text.trim().isNotEmpty)
              'food_capacity': int.parse(_capacity.text.trim()),
            if (maxDonationCapacityKg != null)
              'max_capacity_kg': maxDonationCapacityKg,
            if (_categories.isNotEmpty)
              'preferred_food_types': _categories.toList(),
            if (_dietaryPreferences.isNotEmpty)
              'dietary_preferences': _dietaryPreferences.toList(),
            if (_availableFrom != null && _availableTo != null) ...{
              'available_from': _availableFrom,
              'available_to': _availableTo,
            },
            if (_latitude != null && _longitude != null) ...{
              'latitude': _latitude,
              'longitude': _longitude,
            },
          },
        );
      } else {
        await context.read<AppState>().register(
          role: UserRole.ngo,
          email: _email.text,
          password: _password.text,
          fullName: _contactPerson.text.trim(),
          orgLabel: _ngoName.text.trim(),
          phone: normalizeIndianMobileNumber(_phone.text)!,
          roleProfile: {
            'organization_name': _ngoName.text.trim(),
            'registration_number': _regId.text.trim(),
            'address': _address.text.trim(),
            'city': _city.text.trim(),
            'phone': normalizeIndianMobileNumber(_phone.text)!,
            if (_capacity.text.trim().isNotEmpty)
              'food_capacity': int.parse(_capacity.text.trim()),
            if (maxDonationCapacityKg != null)
              'max_capacity_kg': maxDonationCapacityKg,
            if (_categories.isNotEmpty)
              'preferred_food_types': _categories.toList(),
            if (_dietaryPreferences.isNotEmpty)
              'dietary_preferences': _dietaryPreferences.toList(),
            if (_availableFrom != null && _availableTo != null) ...{
              'available_from': _availableFrom,
              'available_to': _availableTo,
            },
            if (_latitude != null && _longitude != null) ...{
              'latitude': _latitude,
              'longitude': _longitude,
            },
          },
        );
      }
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
                if (!widget.googleEnrollment)
                  AppInputField(
                      label: 'Email',
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      prefixIcon: Icons.email_outlined,
                      validator: _emailValidator),
                if (widget.googleEnrollment) ...[
                  Text(
                    'Signed in with Google — your Gmail will be used as your account email.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: AppColors.of(context).textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
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
                OutlinedButton.icon(
                  onPressed: _chooseLocation,
                  icon: const Icon(Icons.map_outlined),
                  label: Text(_latitude == null
                      ? 'Choose location on map (needed for matching)'
                      : 'Location chosen — tap to change'),
                ),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Capacity Served (people/day, optional)',
                    controller: _capacity,
                    keyboardType: TextInputType.number,
                    prefixIcon: Icons.groups_outlined,
                    validator: (value) {
                      final capacity = int.tryParse(value?.trim() ?? '');
                      return (value?.trim().isNotEmpty ?? false) &&
                              (capacity == null || capacity <= 0)
                          ? 'Enter a positive number of people served per day, or leave blank.'
                          : null;
                    }),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                    label: 'Maximum donation amount (kg, optional)',
                    controller: _maxDonationCapacityKg,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    prefixIcon: Icons.scale_outlined,
                    validator: (value) {
                      final capacity = double.tryParse(value?.trim() ?? '');
                      return (value?.trim().isNotEmpty ?? false) &&
                              (capacity == null ||
                                  !capacity.isFinite ||
                                  capacity <= 0)
                          ? 'Enter a positive food weight, or leave blank to configure later.'
                          : null;
                    }),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Matching details are optional during registration. Add a real location, hours, food preferences, and per-donation capacity before expecting matches.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.md),
                OperatingHoursFields(
                  requiredForMatching: false,
                  value: (from: _availableFrom, to: _availableTo),
                  onChanged: (hours) => setState(() {
                    _availableFrom = hours.from;
                    _availableTo = hours.to;
                  }),
                ),
                const SizedBox(height: AppSpacing.md),
                Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Food Categories Accepted',
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Dietary Types Accepted',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _kDietaryPreferenceLabels.entries.map((entry) {
                    final selected = _dietaryPreferences.contains(entry.key);
                    return FilterChip(
                      label: Text(entry.value),
                      selected: selected,
                      onSelected: (value) => setState(() => value
                          ? _dietaryPreferences.add(entry.key)
                          : _dietaryPreferences.remove(entry.key)),
                    );
                  }).toList(),
                ),
                const SizedBox(height: AppSpacing.md),
                if (!widget.googleEnrollment)
                  AppInputField(
                      label: 'Password',
                      controller: _password,
                      obscureText: true,
                      prefixIcon: Icons.lock_outline,
                      validator: _passwordValidator),
                const SizedBox(height: AppSpacing.md),
                if (!widget.googleEnrollment)
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
  const RegisterVolunteerScreen({super.key, this.googleEnrollment = false});
  final bool googleEnrollment;
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
    if (!widget.googleEnrollment && _password.text != _confirmPassword.text) {
      _showSnack('Passwords do not match.', isError: true);
      return;
    }
    setState(() => _isLoading = true);
    try {
      if (widget.googleEnrollment) {
        await context.read<AppState>().enroll(
          role: UserRole.volunteer,
          fullName: _fullName.text.trim(),
          orgLabel: _fullName.text.trim(),
          phone: normalizeIndianMobileNumber(_phone.text)!,
          roleProfile: {
            'availability_status': _days.isEmpty ? 'offline' : 'available',
          },
        );
      } else {
        await context.read<AppState>().register(
          role: UserRole.volunteer,
          email: _email.text,
          password: _password.text,
          fullName: _fullName.text.trim(),
          orgLabel: _fullName.text.trim(),
          phone: normalizeIndianMobileNumber(_phone.text)!,
          roleProfile: {
            'availability_status': _days.isEmpty ? 'offline' : 'available',
          },
        );
      }
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
                if (!widget.googleEnrollment)
                  AppInputField(
                      label: 'Email',
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      prefixIcon: Icons.email_outlined,
                      validator: _emailValidator),
                if (widget.googleEnrollment) ...[
                  Text(
                    'Signed in with Google — your Gmail will be used as your account email.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: AppColors.of(context).textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
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
                if (!widget.googleEnrollment)
                  AppInputField(
                      label: 'Password',
                      controller: _password,
                      obscureText: true,
                      prefixIcon: Icons.lock_outline,
                      validator: _passwordValidator),
                const SizedBox(height: AppSpacing.md),
                if (!widget.googleEnrollment)
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
String? _phoneValidator(String? v) => normalizeIndianMobileNumber(v) == null
    ? 'Enter a valid 10-digit Indian mobile number'
    : null;
String? _passwordValidator(String? v) =>
    (v == null || v.length < 6) ? 'Minimum 6 characters' : null;

// =============================================================================
// DAILY FOOD ENTRY — mandatory gate before the Provider dashboard
// -----------------------------------------------------------------------------
// A daily food entry is a food log, NOT a donation. This screen therefore asks
// for exactly three required things (category, prepared kg, sold kg) plus an
// optional meal type, and nothing donation-shaped: no quantity/servings, no
// pickup address, no expiry, no pickup deadline, no donation status, no NGO,
// no volunteer and no food photo.
//
// The provider is never asked for or allowed to send an id or a date — the
// backend derives both from the Firebase token and its own clock.
// =============================================================================

/// Categories offered here are only those the EXISTING AI mapping can resolve
/// (cooked | bakery | dairy | packaged | raw). 'Other' is deliberately absent
/// because it has no AI mapping and the backend rejects it.
const _kDailyFoodCategories = [
  'Cooked Meals',
  'Rice',
  'Bread',
  'Bakery',
  'Dairy',
  'Packaged Food',
  'Fruits',
  'Vegetables',
];

const _kMealTypes = [
  ('breakfast', 'Breakfast'),
  ('lunch', 'Lunch'),
  ('snacks', 'Snacks'),
  ('dinner', 'Dinner'),
  ('other', 'Other'),
];

/// Shown after a successful submission. Also renders the error state when the
/// AI service could not produce a prediction, so the provider is never shown a
/// fake or missing number.
class DailyFoodEntryResultView extends StatelessWidget {
  final DailyFoodEntry entry;
  const DailyFoodEntryResultView({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('AI Food Surplus Prediction',
          style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 4),
      Text('${entry.entryDate} · ${entry.foodCategory}',
          style: TextStyle(color: c.textSecondary)),
      const SizedBox(height: AppSpacing.md),
      SurplusPredictionCard(entry: entry),
      const SizedBox(height: AppSpacing.md),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Today\'s food entry',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('Prepared: ${entry.foodPreparedKg.toStringAsFixed(1)} kg',
              style: TextStyle(fontSize: 13, color: c.textSecondary)),
          Text('Sold / consumed: ${entry.foodSoldKg.toStringAsFixed(1)} kg',
              style: TextStyle(fontSize: 13, color: c.textSecondary)),
          if (entry.mealType != null)
            Text('Meal type: ${entry.mealType}',
                style: TextStyle(fontSize: 13, color: c.textSecondary)),
        ]),
      ),
    ]);
  }
}

class DailyFoodEntryScreen extends StatefulWidget {
  /// Called with the saved entry so the gate can hand the provider through to
  /// the dashboard without re-showing this form.
  final ValueChanged<DailyFoodEntry> onSubmitted;

  /// Overridable so the submit path can be exercised without a live backend.
  @visibleForTesting
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> payload)?
      submit;

  const DailyFoodEntryScreen(
      {super.key, required this.onSubmitted, this.submit});

  @override
  State<DailyFoodEntryScreen> createState() => _DailyFoodEntryScreenState();
}

class _DailyFoodEntryScreenState extends State<DailyFoodEntryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _preparedController = TextEditingController();
  final _soldController = TextEditingController();
  String _category = _kDailyFoodCategories.first;
  String? _mealType;
  bool _submitting = false;
  String? _submitError;
  DailyFoodEntry? _saved;

  @override
  void dispose() {
    _preparedController.dispose();
    _soldController.dispose();
    super.dispose();
  }

  /// Same rule the donation flow already uses: prepared > 0, sold >= 0 and
  /// sold <= prepared. Both values are always required here (unlike the
  /// optional donation pair) and are always kilograms — never servings.
  String? _validateKg(String? raw, {required bool isPrepared}) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) {
      return isPrepared ? 'Prepared (kg) is required' : 'Sold (kg) is required';
    }
    final value = double.tryParse(text);
    if (value == null) return 'Enter a number';
    if (isPrepared && value <= 0) {
      return 'Prepared (kg) must be greater than 0';
    }
    if (!isPrepared && value < 0) return 'Sold (kg) cannot be negative';
    return null;
  }

  String? _validateSoldAgainstPrepared(String? raw) {
    final base = _validateKg(raw, isPrepared: false);
    if (base != null) return base;
    final prepared = double.tryParse(_preparedController.text.trim());
    final sold = double.tryParse(raw!.trim());
    if (prepared != null && sold != null && sold > prepared) {
      return 'Sold (kg) cannot exceed Prepared (kg)';
    }
    return null;
  }

  Future<void> _submit() async {
    final formValid = _formKey.currentState!.validate();
    if (!formValid) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });

    final payload = <String, dynamic>{
      'food_category': _category,
      'food_prepared_kg': double.parse(_preparedController.text.trim()),
      'food_sold_kg': double.parse(_soldController.text.trim()),
      if (_mealType != null) 'meal_type': _mealType,
      // No provider_id and no date: the backend owns both.
    };

    try {
      final response = widget.submit != null
          ? await widget.submit!(payload)
          : await context.read<AppState>().api.createDailyFoodEntry(payload);
      if (!mounted) return;
      final entry = DailyFoodEntry.fromCreateResponse(response);
      setState(() {
        _saved = entry;
        _submitting = false;
      });
      widget.onSubmitted(entry);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = e is ApiException
            ? _apiErrorMessage(e,
                fallback:
                    'Could not save today\'s food entry. Please try again.')
            : 'Could not save today\'s food entry. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final saved = _saved;

    return Scaffold(
      body: SafeArea(
        child: saved != null
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: DailyFoodEntryResultView(entry: saved),
              )
            : ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  const SahaayLogo(),
                  const SizedBox(height: AppSpacing.lg),
                  Text('Daily Food Entry',
                      style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 6),
                  Text(
                    'Tell us what you prepared and sold today so SAHAAY can '
                    'predict your surplus. One entry per day.',
                    style: TextStyle(color: c.textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  if (_submitError != null) ...[
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: c.danger.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        border:
                            Border.all(color: c.danger.withValues(alpha: 0.4)),
                      ),
                      child: Row(children: [
                        Icon(Icons.error_outline, color: c.danger, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_submitError!,
                              style:
                                  TextStyle(fontSize: 12.5, color: c.danger)),
                        ),
                      ]),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DropdownButtonFormField<String>(
                          initialValue: _category,
                          decoration:
                              const InputDecoration(labelText: 'Food Category'),
                          items: _kDailyFoodCategories
                              .map((cat) => DropdownMenuItem(
                                  value: cat, child: Text(cat)))
                              .toList(),
                          onChanged: _submitting
                              ? null
                              : (v) =>
                                  setState(() => _category = v ?? _category),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Row(children: [
                          Expanded(
                            child: AppInputField(
                              label: 'Prepared food (kg)',
                              controller: _preparedController,
                              prefixIcon: Icons.kitchen_outlined,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              validator: (v) =>
                                  _validateKg(v, isPrepared: true),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: AppInputField(
                              label: 'Sold / consumed (kg)',
                              controller: _soldController,
                              prefixIcon: Icons.point_of_sale_outlined,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              validator: _validateSoldAgainstPrepared,
                            ),
                          ),
                        ]),
                        const SizedBox(height: AppSpacing.md),
                        DropdownButtonFormField<String>(
                          initialValue: _mealType,
                          decoration: const InputDecoration(
                            labelText: 'Meal type (optional)',
                            hintText: 'Not specified',
                          ),
                          items: _kMealTypes
                              .map((m) => DropdownMenuItem(
                                  value: m.$1, child: Text(m.$2)))
                              .toList(),
                          onChanged: _submitting
                              ? null
                              : (v) => setState(() => _mealType = v),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        PrimaryButton(
                          label: 'SUBMIT TODAY\'S ENTRY',
                          icon: Icons.check,
                          isLoading: _submitting,
                          onPressed: _submit,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          'This is a food log, not a donation. Submitting it '
                          'does not list any food for NGOs.',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(fontSize: 12, color: c.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Gates the Provider dashboard on the BACKEND's answer to "does today's entry
/// exist?". The client never decides this from a local date, and once the entry
/// is saved the form is not shown again.
class ProviderDailyEntryGate extends StatefulWidget {
  /// Overridable so the gate can be exercised without a live backend.
  @visibleForTesting
  final Future<Map<String, dynamic>> Function()? loadToday;

  /// Overridable so the prediction retry can be tested without a live backend.
  @visibleForTesting
  final Future<Map<String, dynamic>> Function()? refreshPrediction;

  const ProviderDailyEntryGate(
      {super.key, this.loadToday, this.refreshPrediction});

  @override
  State<ProviderDailyEntryGate> createState() => _ProviderDailyEntryGateState();
}

class _ProviderDailyEntryGateState extends State<ProviderDailyEntryGate> {
  bool _loading = true;
  String? _error;
  DailyFoodEntry? _entry;
  bool _refreshingPrediction = false;
  String? _predictionRefreshError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final body = widget.loadToday != null
          ? await widget.loadToday!()
          : await context.read<AppState>().api.getTodayDailyFoodEntry();
      if (!mounted) return;
      setState(() {
        _entry = DailyFoodEntry.fromToday(body);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException
            ? _apiErrorMessage(e,
                fallback: 'Could not check today\'s food entry.')
            : 'Could not check today\'s food entry.';
        _loading = false;
      });
    }
  }

  Future<void> _refreshPrediction() async {
    if (_refreshingPrediction) return;
    setState(() {
      _refreshingPrediction = true;
      _predictionRefreshError = null;
    });
    try {
      final response = widget.refreshPrediction != null
          ? await widget.refreshPrediction!()
          : await context
              .read<AppState>()
              .api
              .refreshTodayDailyFoodPrediction();
      if (!mounted) return;
      setState(() {
        _entry = DailyFoodEntry.fromCreateResponse(response);
        _refreshingPrediction = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _refreshingPrediction = false;
        _predictionRefreshError = e is ApiException
            ? ((e.statusCode == 502 || e.statusCode == 503) &&
                    e.message.isNotEmpty
                ? e.message
                : _apiErrorMessage(e,
                    fallback: 'Could not refresh the prediction.'))
            : 'Could not refresh the prediction. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    if (_loading) {
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            const SizedBox(height: AppSpacing.md),
            Text('Checking today\'s food entry…',
                style: TextStyle(color: c.textSecondary)),
          ]),
        ),
      );
    }

    // A failed check must NOT be treated as "no entry required" — the
    // dashboard stays locked until the backend can confirm the entry exists.
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.cloud_off_outlined, size: 40, color: c.textSecondary),
              const SizedBox(height: AppSpacing.md),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.textSecondary)),
              const SizedBox(height: AppSpacing.md),
              SecondaryButton(
                label: 'RETRY',
                icon: Icons.refresh,
                onPressed: _load,
              ),
            ]),
          ),
        ),
      );
    }

    final entry = _entry;
    if (entry == null) {
      return DailyFoodEntryScreen(
        onSubmitted: (saved) => setState(() => _entry = saved),
      );
    }

    return ProviderDashboardScreen(
      dailyEntry: entry,
      onDailyEntryChanged: _refreshPrediction,
      refreshingPrediction: _refreshingPrediction,
      predictionRefreshError: _predictionRefreshError,
    );
  }
}

// =============================================================================
// ROLE ROUTER — sends the signed-in user to the correct dashboard
// =============================================================================

class PermissionOnboardingScreen extends StatefulWidget {
  static const String prefsKey = 'sahaay_permission_onboarding_complete';

  final PermissionService permissions;
  final bool reviewMode;
  final Widget Function() finishDestination;
  final Future<void> Function()? onComplete;

  const PermissionOnboardingScreen({
    super.key,
    required this.permissions,
    required this.finishDestination,
    this.reviewMode = false,
    this.onComplete,
  });

  @override
  State<PermissionOnboardingScreen> createState() =>
      _PermissionOnboardingScreenState();
}

class _PermissionOnboardingScreenState
    extends State<PermissionOnboardingScreen> {
  static const _permissions = [
    AppPermission.camera,
    AppPermission.location,
    AppPermission.notifications,
  ];

  final Map<AppPermission, PermissionOutcome> _outcomes = {};
  bool _loading = true;
  bool _requesting = false;
  bool _requestedOnce = false;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var completed = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      completed = !widget.reviewMode &&
          prefs.getBool(PermissionOnboardingScreen.prefsKey) == true;
    } catch (error, stackTrace) {
      debugPrint(
          'Could not read permission-onboarding state: $error\n$stackTrace');
    }
    final outcomes = <AppPermission, PermissionOutcome>{};
    if (!completed) {
      for (final permission in _permissions) {
        try {
          outcomes[permission] = await widget.permissions.status(permission);
        } catch (error, stackTrace) {
          debugPrint('Could not read $permission status: $error\n$stackTrace');
          outcomes[permission] = PermissionOutcome.denied;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _completed = completed;
      _outcomes
        ..clear()
        ..addAll(outcomes);
      _loading = false;
    });
  }

  Future<void> _requestPermissions() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    final outcomes = <AppPermission, PermissionOutcome>{};
    for (final permission in _permissions) {
      try {
        outcomes[permission] = await widget.permissions.request(permission);
      } catch (error, stackTrace) {
        debugPrint(
            'Could not request $permission permission: $error\n$stackTrace');
        outcomes[permission] = PermissionOutcome.denied;
      }
    }
    if (!mounted) return;
    setState(() {
      _outcomes
        ..clear()
        ..addAll(outcomes);
      _requesting = false;
      _requestedOnce = true;
    });
  }

  String _statusLabel(PermissionOutcome? outcome) {
    switch (outcome) {
      case PermissionOutcome.granted:
        return 'Allowed';
      case PermissionOutcome.permanentlyDenied:
      case PermissionOutcome.restricted:
        return 'Blocked in Settings';
      case PermissionOutcome.serviceDisabled:
        return 'Location services off';
      case PermissionOutcome.denied:
        return 'Not allowed';
      case PermissionOutcome.notRequired:
        return 'Not required';
      case PermissionOutcome.notRequested:
      case null:
        return 'Not requested';
    }
  }

  Future<void> _openSettings(AppPermission permission) async {
    if (permission == AppPermission.location &&
        _outcomes[permission] == PermissionOutcome.serviceDisabled) {
      await widget.permissions.openLocationSettings();
    } else {
      await widget.permissions.openAppSettings();
    }
  }

  Future<void> _finish({required bool persist}) async {
    if (persist && !widget.reviewMode) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(PermissionOnboardingScreen.prefsKey, true);
      } catch (error, stackTrace) {
        debugPrint(
            'Could not save permission-onboarding state: $error\n$stackTrace');
      }
    }
    await widget.onComplete?.call();
    if (!mounted) return;
    if (widget.reviewMode) {
      Navigator.of(context).pop();
    } else {
      setState(() => _completed = true);
    }
  }

  Widget _permissionRow(AppPermission permission) {
    final outcome = _outcomes[permission];
    final showSettings = outcome == PermissionOutcome.permanentlyDenied ||
        outcome == PermissionOutcome.restricted ||
        outcome == PermissionOutcome.serviceDisabled;
    final title = switch (permission) {
      AppPermission.camera => 'Camera',
      AppPermission.location => 'Location',
      AppPermission.notifications => 'Notifications',
    };
    final reason = switch (permission) {
      AppPermission.camera => 'Take food and handover photos.',
      AppPermission.location =>
        'Use your location to find nearby food and plan pickups.',
      AppPermission.notifications =>
        'Receive claim, pickup, delivery and status updates.',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                Text(_statusLabel(outcome)),
              ],
            ),
            const SizedBox(height: 4),
            Text(reason),
            if (showSettings)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _openSettings(permission),
                  child: const Text('Settings'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_completed) return widget.finishDestination();
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
            widget.reviewMode ? 'Permissions' : 'Allow SAHAAY permissions'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.reviewMode)
              const Text(
                'Allow SAHAAY permissions',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            if (!widget.reviewMode) const SizedBox(height: 12),
            for (final permission in _permissions) _permissionRow(permission),
            const Card(
              margin: EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Photos',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    SizedBox(height: 4),
                    Text('Choose images using the system photo picker; '
                        'SAHAAY does not need broad photo-library access.'),
                  ],
                ),
              ),
            ),
            if (_outcomes.values.any((outcome) =>
                outcome == PermissionOutcome.denied ||
                outcome == PermissionOutcome.permanentlyDenied ||
                outcome == PermissionOutcome.restricted ||
                outcome == PermissionOutcome.serviceDisabled))
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Text(
                  'You can continue without granting permissions. Some device-dependent features may be unavailable.',
                  style: TextStyle(color: c.textSecondary),
                ),
              ),
            FilledButton(
              onPressed: _requesting ? null : _requestPermissions,
              child: _requesting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Allow Permissions'),
            ),
            if (!widget.reviewMode && !_requesting) ...[
              TextButton(
                onPressed: () => _finish(persist: true),
                child: const Text('Not Now'),
              ),
              if (_requestedOnce)
                TextButton(
                  onPressed: () => _finish(persist: true),
                  child: const Text('Continue'),
                ),
            ],
            if (widget.reviewMode && !_requesting)
              TextButton(
                onPressed: () => _finish(persist: false),
                child: const Text('Done'),
              ),
          ],
        ),
      ),
    );
  }
}

class _PermissionOnboardingGate extends StatefulWidget {
  final Widget child;

  const _PermissionOnboardingGate({required this.child});

  @override
  State<_PermissionOnboardingGate> createState() =>
      _PermissionOnboardingGateState();
}

class _PermissionOnboardingGateState extends State<_PermissionOnboardingGate> {
  late final Future<bool> _completed = _readCompletion();

  Future<bool> _readCompletion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(PermissionOnboardingScreen.prefsKey) == true;
    } catch (error, stackTrace) {
      debugPrint(
          'Could not load permission-onboarding state: $error\n$stackTrace');
      return true;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
        future: _completed,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.data == true) return widget.child;
          return PermissionOnboardingScreen(
            permissions: activePermissionService(),
            finishDestination: () => widget.child,
            onComplete: () =>
                context.read<AppState>().refreshFcmTokenRegistration(),
          );
        },
      );
}

class RoleRouter extends StatelessWidget {
  const RoleRouter({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.isLoggedIn || state.currentRole == null) {
      return const LoginScreen();
    }
    final Widget dashboard;
    switch (state.currentRole!) {
      case UserRole.provider:
        // Providers pass through the mandatory daily food entry gate first.
        dashboard = const ProviderDailyEntryGate();
        break;
      case UserRole.ngo:
        dashboard = const NgoDashboardScreen();
        break;
      case UserRole.volunteer:
        dashboard = const VolunteerDashboardScreen();
        break;
      case UserRole.admin:
        dashboard = const AdminDashboardScreen();
        break;
    }
    return _PermissionOnboardingGate(child: dashboard);
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
      MaterialPageRoute(builder: (_) => const LoginScreen()), (route) => false);
}

void _openNotifications(BuildContext context, UserRole role) {
  Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => NotificationsScreen(role: role)));
}

Future<bool> _requireCompleteProfile(
  BuildContext context, {
  required UserRole role,
  required String action,
}) async {
  final state = context.read<AppState>();
  final completion = state.profileCompletion;
  if (completion?.isComplete == true) return true;
  final missing = completion?.missingFields ?? const <String>[];
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Complete your profile first'),
      content: Text(
        missing.isEmpty
            ? 'We could not verify that your required profile details are complete. Refresh your profile and try again.'
            : 'Complete these required fields before $action:\n\n${missing.map((field) => '• $field').join('\n')}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => EditProfileScreen(role: role),
            ));
          },
          child: const Text('Complete profile'),
        ),
      ],
    ),
  );
  return false;
}

class ProfileCompletionCard extends StatelessWidget {
  final UserRole role;
  final ProfileCompletion completion;

  const ProfileCompletionCard({
    super.key,
    required this.role,
    required this.completion,
  });

  @override
  Widget build(BuildContext context) {
    if (!shouldShowProfileProgress(completion)) {
      return const SizedBox.shrink();
    }
    final colors = AppColors.of(context);
    final value = completion.percentage.clamp(0, 100) / 100;
    final message = !completion.isComplete
        ? 'Remaining: ${completion.missingFields.join(', ')}'
        : 'Your profile is ready.';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Profile completion',
                      style:
                          TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                ),
                Text('${completion.percentage.clamp(0, 100)}%',
                    style: TextStyle(
                        color: colors.bluePrimary,
                        fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 8),
            Semantics(
              label:
                  'Profile ${completion.percentage.clamp(0, 100)} percent complete',
              value:
                  '${completion.completedFields} of ${completion.totalFields} required fields',
              child: LinearProgressIndicator(value: value),
            ),
            const SizedBox(height: 6),
            Text(
              '${completion.completedFields} of ${completion.totalFields} required fields complete',
              style: TextStyle(color: colors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Text(message, style: TextStyle(color: colors.textSecondary)),
            if (!completion.isComplete) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => EditProfileScreen(role: role),
                    ),
                  ),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Complete profile'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

bool shouldShowProfileProgress(ProfileCompletion completion) =>
    completion.percentage < 100;

// =============================================================================
// PROVIDER DASHBOARD
// =============================================================================

class ProviderDashboardScreen extends StatefulWidget {
  /// Today's daily food entry, resolved by [ProviderDailyEntryGate] from the
  /// backend. Null only when the entry is somehow missing after the gate.
  final DailyFoodEntry? dailyEntry;

  /// Re-reads today's entry from the backend (used by the prediction retry).
  final Future<void> Function()? onDailyEntryChanged;
  final bool refreshingPrediction;
  final String? predictionRefreshError;
  @visibleForTesting
  final File? testDonationPhoto;

  const ProviderDashboardScreen({
    super.key,
    this.dailyEntry,
    this.onDailyEntryChanged,
    this.refreshingPrediction = false,
    this.predictionRefreshError,
    this.testDonationPhoto,
  });

  @override
  State<ProviderDashboardScreen> createState() =>
      _ProviderDashboardScreenState();
}

class _ProviderDashboardScreenState extends State<ProviderDashboardScreen> {
  int _tab = 0;
  final List<Donation> _donations = [];
  List<Map<String, dynamic>> _providerClaims = [];
  bool _loading = true;
  String? _error;
  bool _creatingDonation = false;
  _NewDonationInput? _donationDraft;
  String? _uploadedDonationPhotoPath;
  String? _uploadedDonationPhotoUrl;

  /// Tri-state vehicle answer, loaded from the backend. Starts unanswered so
  /// the prompt is not hidden before the real value is known, and `_vehicleLoaded`
  /// suppresses the card while the read is in flight so it never flashes.
  VehicleAvailability _vehicle = VehicleAvailability.unanswered;
  bool _vehicleLoaded = false;
  bool _savingVehicle = false;

  @override
  void initState() {
    super.initState();
    _loadDonations();
    _loadVehicle();
  }

  /// Reads the provider's real stored answer. On failure the state stays
  /// unanswered so the prompt remains visible rather than disappearing behind a
  /// failed read.
  Future<void> _loadVehicle() async {
    try {
      final state = context.read<AppState>();
      final profile = await state.api.getProfile();
      state.updateProfileCompletionFromResponse(profile);
      if (!mounted) return;
      setState(() {
        _vehicle = VehicleAvailability.fromBackend(vehicleFromProfile(profile));
        _vehicleLoaded = true;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _vehicle = VehicleAvailability.unanswered;
        _vehicleLoaded = true;
      });
    }
  }

  /// Persists the answer, then updates local state only after the backend
  /// confirms it, so a rejected write never looks saved.
  Future<void> _answerVehicle(VehicleAvailability choice) async {
    if (_savingVehicle) return;
    setState(() => _savingVehicle = true);
    try {
      final result = await context
          .read<AppState>()
          .api
          .setProviderVehicleAvailability(choice.backendValue);
      if (!mounted) return;
      setState(() {
        _vehicle = VehicleAvailability.fromBackend(
            result['vehicle_available'] ?? choice.backendValue);
        _savingVehicle = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _savingVehicle = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(_apiErrorMessage(e, fallback: 'Could not save your answer.')),
      ));
    } catch (error, stackTrace) {
      debugPrint(
          'Could not save provider vehicle availability: $error\n$stackTrace');
      if (!mounted) return;
      setState(() => _savingVehicle = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Could not save your answer. Check your connection and try again.'),
      ));
    }
  }

  Future<void> _loadDonations() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = context.read<AppState>();
      final raw = await state.api.getDonations();
      final list = [
        for (final item in raw)
          Donation.fromBackend(item is Map<String, dynamic> ? item : {},
              referenceLatitude: state.userLatitude,
              referenceLongitude: state.userLongitude),
      ];
      if (!mounted) return;
      setState(() {
        _donations
          ..clear()
          ..addAll(list);
        _loading = false;
      });
      await _loadProviderClaims();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error =
            _apiErrorMessage(e, fallback: 'Could not load your donations.');
        _loading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('Could not refresh provider donations: $error\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _error = 'Could not refresh your donations. Check your connection.';
        _loading = false;
      });
    }
  }

  Future<void> _loadProviderClaims() async {
    try {
      final rows = await context.read<AppState>().api.getProviderClaims();
      if (!mounted) return;
      setState(() {
        _providerClaims = rows
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
      });
    } on ApiException catch (error) {
      debugPrint('Could not refresh provider claim details: ${error.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    Widget pageAt(int index, Widget child, {bool needsData = false}) {
      if (needsData) {
        if (_loading && _donations.isEmpty) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
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
          donations: _donations,
          onCreateDonation: _createDonation,
          dailyEntry: widget.dailyEntry,
          onRefreshPrediction: widget.onDailyEntryChanged,
          refreshingPrediction: widget.refreshingPrediction,
          predictionRefreshError: widget.predictionRefreshError,
          vehicleAvailability: _vehicleLoaded ? _vehicle : null,
          onVehicleAnswer: _answerVehicle,
          savingVehicle: _savingVehicle,
          creatingDonation: _creatingDonation,
        ),
      ),
      pageAt(
          1,
          _ProviderDonationsTab(
              donations: _donations,
              claims: _providerClaims,
              onRefresh: _loadDonations)),
      pageAt(
        2,
        _ProviderImpactTab(donations: _donations),
      ),
      NotificationsScreen(role: UserRole.provider, embedded: true),
      ProfileTab(
        role: UserRole.provider,
        name: state.currentOrgLabel,
        imageUrl: state.currentProfileImageUrl,
        vehicleAvailability: _vehicleLoaded ? _vehicle : null,
        onVehicleAnswer: _answerVehicle,
        savingVehicle: _savingVehicle,
      ),
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
    if (_creatingDonation) return;
    final state = context.read<AppState>();
    if (state.profileCompletion?.isComplete != true) {
      await _requireCompleteProfile(
        context,
        role: UserRole.provider,
        action: 'creating a donation',
      );
      return;
    }
    setState(() => _creatingDonation = true);

    ValueNotifier<String>? stage;
    NavigatorState? rootNavigator;
    var progressVisible = false;
    var operation = 'photo upload';
    try {
      final result = await showModalBottomSheet<_NewDonationInput>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        builder: (_) => _CreateDonationSheet(
          initialDraft: _donationDraft,
          testPhoto: widget.testDonationPhoto,
        ),
      );
      if (result == null || !mounted) return;
      _donationDraft = result;

      final photo = result.foodPhoto;
      final cachedPhotoUrl =
          photo != null && _uploadedDonationPhotoPath == photo.path
              ? _uploadedDonationPhotoUrl
              : null;
      stage = ValueNotifier<String>(cachedPhotoUrl == null
          ? 'Uploading photo'
          : 'Creating donation and finding matching NGOs');
      rootNavigator = Navigator.of(context, rootNavigator: true);
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DonationSubmissionDialog(stage: stage!),
      ));
      progressVisible = true;

      final preparedAt = DateTime.now();
      final expiresAt = preparedAt.add(Duration(hours: result.expiryHours));
      if (photo == null) {
        throw const ApiException(
            422, 'Choose a food photo before creating the donation.');
      }
      var foodImageUrl = cachedPhotoUrl;
      if (foodImageUrl == null) {
        foodImageUrl = await state.api.uploadDonationImage(photo);
        _uploadedDonationPhotoPath = photo.path;
        _uploadedDonationPhotoUrl = foodImageUrl;
      }
      stage.value = 'Creating donation and finding matching NGOs';
      operation = 'donation submission';
      final created = await state.api.createDonation({
        'food_name': result.foodName,
        'food_category': result.category,
        'veg_type': result.vegType,
        'quantity': result.quantityKg,
        'unit': 'kg',
        'servings': result.servings,
        'prepared_at': preparedAt.toUtc().toIso8601String(),
        'expiry_time': expiresAt.toUtc().toIso8601String(),
        'pickup_deadline': expiresAt.toUtc().toIso8601String(),
        'pickup_address': result.pickupAddress,
        if (result.latitude != null) 'latitude': result.latitude,
        if (result.longitude != null) 'longitude': result.longitude,
        'storage_condition': result.storageCondition,
        if (result.foodPreparedKg != null)
          'food_prepared_kg': result.foodPreparedKg,
        if (result.foodSoldKg != null) 'food_sold_kg': result.foodSoldKg,
        'food_image_url': foodImageUrl,
      });
      _donationDraft = null;
      _uploadedDonationPhotoPath = null;
      _uploadedDonationPhotoUrl = null;
      if (!mounted) return;
      final donation = Donation.fromBackend(created,
          referenceLatitude: state.userLatitude,
          referenceLongitude: state.userLongitude);

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
      stage.value = 'Refreshing your donation list';
      await _loadDonations();
      if (!mounted) return;

      final matchingValue = created['matching'];
      final matchingStatus =
          matchingValue is Map ? matchingValue['status']?.toString() : null;
      final matchingMessage = switch (matchingStatus) {
        'offered' => 'An offer was sent to the top-ranked matching NGO.',
        'no_candidates' =>
          'No matching NGOs are available for this donation yet.',
        'insufficient_data' =>
          'More matching information is needed before NGOs can be ranked.',
        'error' => 'Matching could not start and will be retried.',
        _ => 'Matching results will appear here when available.',
      };
      state.pushNotification(
        'Donation Listed',
        '"${donation.foodName}"'
            ' (${donation.quantityKg.toStringAsFixed(0)} kg) is listed as '
            'Available. $matchingMessage',
        NotificationCategory.donation,
      );
      final confirmationMessage = result.locationLookupFailed
          ? 'Donation listed, but its address could not be mapped. No location pin was saved.'
          : switch (matchingStatus) {
              'offered' =>
                'Donation listed. An offer was sent to the top-ranked matching NGO.',
              'no_candidates' =>
                'Donation listed, but no matching NGOs are available for it yet.',
              'insufficient_data' =>
                'Donation listed, but more matching information is needed.',
              'error' =>
                'Donation listed, but matching could not start and will be retried.',
              _ => 'Food safety check passed. Donation listed as Available.',
            };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: result.locationLookupFailed
              ? AppColors.of(context).textSecondary
              : AppColors.of(context).green,
          content: Text(confirmationMessage),
        ),
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.of(context).danger,
          content: Text(_donationSubmissionErrorMessage(
            error,
            operation: operation,
          )),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Donation submission failed: $error\n$stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        backgroundColor: Colors.red,
        content: Text(
          'The request could not be completed. Refresh your donations before retrying.',
        ),
      ));
    } finally {
      if (progressVisible &&
          rootNavigator != null &&
          rootNavigator.mounted &&
          rootNavigator.canPop()) {
        rootNavigator.pop();
      }
      stage?.dispose();
      if (mounted) setState(() => _creatingDonation = false);
    }
  }
}

class _DonationSubmissionDialog extends StatelessWidget {
  final ValueListenable<String> stage;

  const _DonationSubmissionDialog({required this.stage});

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Listing your donation'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const LinearProgressIndicator(),
              const SizedBox(height: AppSpacing.md),
              ValueListenableBuilder<String>(
                valueListenable: stage,
                builder: (context, value, _) => Text(value),
              ),
              const SizedBox(height: 6),
              const Text(
                'Please keep SAHAAY open. Progress is indeterminate while the server processes your request.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      );
}

/// Plain data carried back from the Create Donation sheet.
class _NewDonationInput {
  final String foodName;
  final String category;
  final String vegType;
  final double quantityKg;
  final int servings;
  final int expiryHours;
  final String pickupAddress;
  final String storageCondition; // backend value, not the display label
  final double? foodPreparedKg;
  final double? foodSoldKg;
  final File? foodPhoto;
  final double? latitude;
  final double? longitude;
  final bool locationLookupFailed;
  const _NewDonationInput({
    required this.foodName,
    required this.category,
    required this.vegType,
    required this.quantityKg,
    required this.servings,
    required this.expiryHours,
    required this.pickupAddress,
    required this.storageCondition,
    this.foodPreparedKg,
    this.foodSoldKg,
    this.foodPhoto,
    this.latitude,
    this.longitude,
    this.locationLookupFailed = false,
  });
}

String _formatDonationNumber(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();

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
              style:
                  TextStyle(fontWeight: FontWeight.w700, color: c.textPrimary)),
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
  final picked =
      await ImagePicker().pickImage(source: source, imageQuality: 80);
  return picked == null ? null : File(picked.path);
}

/// Test seam for the permission layer.
///
/// The donation sheet is library-private, so it cannot take an injected
/// [PermissionService] through its constructor. Instead production code reads
/// this overridable, exactly the way [pickFoodPhoto] is already test-driven.
/// Tests set it in `setUp` and clear it in `tearDown`; it is null in the app.
PermissionService? permissionServiceOverride;

/// Returns the override when a test installed one, otherwise the real service.
PermissionService activePermissionService() =>
    permissionServiceOverride ?? PermissionService();

/// Test seam for reading the device position, so widget tests never touch real
/// GPS hardware. Null in the app, which falls through to geolocator.
Future<({double latitude, double longitude})?> Function()?
    positionReaderOverride;

/// Reads the device position, honouring [positionReaderOverride] first.
Future<({double latitude, double longitude})?> readDevicePosition() async {
  final reader = positionReaderOverride;
  if (reader != null) return reader();
  try {
    final position = await Geolocator.getCurrentPosition();
    return (latitude: position.latitude, longitude: position.longitude);
  } catch (_) {
    // A failed fix must never crash the form or invent coordinates.
    return null;
  }
}

/// The real Create Donation form — validated fields, no canned data.
/// Presented as a bottom sheet so it feels lightweight from the dashboard.
class _CreateDonationSheet extends StatefulWidget {
  const _CreateDonationSheet({this.initialDraft, this.testPhoto});

  final _NewDonationInput? initialDraft;
  final File? testPhoto;

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
  String? _vegType;
  double _expiryHours = 4;
  String _storageCondition = _kStorageOptions.first.value;
  bool _submitting = false;
  File? _photo;
  String? _photoError;
  double? _pickupLatitude;
  double? _pickupLongitude;

  late final PermissionService _permissions = activePermissionService();

  @override
  void initState() {
    super.initState();
    final draft = widget.initialDraft;
    _foodNameController.text = draft?.foodName ?? '';
    _quantityController.text =
        draft == null ? '' : _formatDonationNumber(draft.quantityKg);
    _servingsController.text = draft == null ? '' : draft.servings.toString();
    _pickupAddressController.text = draft?.pickupAddress ?? '';
    _preparedKgController.text = draft?.foodPreparedKg == null
        ? ''
        : _formatDonationNumber(draft!.foodPreparedKg!);
    _soldKgController.text = draft?.foodSoldKg == null
        ? ''
        : _formatDonationNumber(draft!.foodSoldKg!);
    _category = draft?.category ?? _category;
    _vegType = draft?.vegType;
    _expiryHours = (draft?.expiryHours ?? _expiryHours).toDouble();
    _storageCondition = draft?.storageCondition ?? _storageCondition;
    _photo = draft?.foodPhoto ?? widget.testPhoto;
    _pickupLatitude = draft?.latitude;
    _pickupLongitude = draft?.longitude;
  }

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

    // Camera permission is requested only at the moment the provider actually
    // chooses "Take Photo", never at startup. Gallery selection does not need
    // it, so that path stays available whatever the camera answer is.
    if (source == ImageSource.camera) {
      final outcome = await _permissions.request(AppPermission.camera);
      if (!mounted) return;
      if (outcome != PermissionOutcome.granted) {
        await _handleCameraRefusal(outcome);
        return;
      }
    }

    try {
      final picked = await pickFoodPhoto(source);
      if (picked == null) return;
      if (!mounted) return;
      setState(() {
        _photo = picked;
        _photoError = null;
      });
    } catch (_) {
      // A camera that is absent, busy or broken must not crash the form.
      if (!mounted) return;
      await _handleCameraUnavailable(source);
    }
  }

  /// Explains the refusal and always keeps the gallery path available. When the
  /// permission is blocked, offers a route to OS Settings instead of silently
  /// failing.
  Future<void> _handleCameraRefusal(PermissionOutcome outcome) async {
    final message = PermissionCopy.deniedMessage(AppPermission.camera, outcome);
    final blocked = _permissions.needsSettings(outcome);
    final useGallery = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(PermissionCopy.cameraTitle),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          if (blocked)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Open Settings'),
            )
          else
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Choose from Gallery'),
            ),
        ],
      ),
    );
    if (useGallery == true && mounted) {
      await _pickFromGallery();
    } else if (blocked == true && mounted) {
      await _permissions.openAppSettings();
    }
  }

  /// Camera is permitted but the device could not open it. The gallery is
  /// offered instead, since the food photo is still required.
  Future<void> _handleCameraUnavailable(ImageSource source) async {
    if (source != ImageSource.camera) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.of(context).danger,
        content: const Text('Could not open photo library.'),
      ));
      return;
    }
    final useGallery = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Camera unavailable'),
        content: const Text(
            'Could not open the camera. You can choose a photo from your gallery instead.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Choose from Gallery'),
          ),
        ],
      ),
    );
    if (useGallery == true && mounted) {
      await _pickFromGallery();
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final picked = await pickFoodPhoto(ImageSource.gallery);
      if (picked == null || !mounted) return;
      setState(() {
        _photo = picked;
        _photoError = null;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.of(context).danger,
        content: const Text('Could not open photo library.'),
      ));
    }
  }

  bool _locating = false;

  /// Fills the pickup address from the device location.
  ///
  /// Handles every permission state without crashing and without fabricating
  /// coordinates: when location is unavailable the field is left untouched and
  /// the provider simply types an address instead.
  Future<void> _useCurrentLocation() async {
    if (_locating || !mounted) return;
    setState(() => _locating = true);
    try {
      final outcome = await _permissions.request(AppPermission.location);
      if (!mounted) return;

      if (outcome == PermissionOutcome.serviceDisabled) {
        // The permission is fine, the OS toggle is off: offer the real fix
        // rather than a permission dialog that would do nothing.
        setState(() => _locating = false);
        final open = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(PermissionCopy.locationTitle),
            content: const Text(PermissionCopy.locationServiceOff),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Not now'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Open Settings'),
              ),
            ],
          ),
        );
        if (open == true) await _permissions.openLocationSettings();
        return;
      }

      if (outcome != PermissionOutcome.granted) {
        setState(() => _locating = false);
        await _explainLocationRefusal(outcome);
        return;
      }

      final position = await _readPosition();
      if (!mounted) return;
      if (position == null) {
        setState(() => _locating = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: AppColors.of(context).danger,
          content: const Text(
              'Could not read your location. Enter the pickup address manually.'),
        ));
        return;
      }
      if (!coordinateIsUsable(position.latitude, position.longitude)) {
        setState(() => _locating = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Could not read a valid location. Enter the pickup address manually.'),
        ));
        return;
      }

      final resolvedAddress = await reverseGeocodeCoordinates(
        position.latitude,
        position.longitude,
      );
      if (!mounted) return;
      setState(() {
        _pickupLatitude = position.latitude;
        _pickupLongitude = position.longitude;
        _pickupAddressController.text =
            resolvedAddress?.address ?? 'Address unavailable';
        _locating = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _locating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.of(context).danger,
        content: const Text(
            'Could not read your location. Enter the pickup address manually.'),
      ));
    }
  }

  /// Seam so tests never touch real GPS hardware.
  Future<({double latitude, double longitude})?> _readPosition() =>
      readDevicePosition();

  Future<void> _explainLocationRefusal(PermissionOutcome outcome) async {
    final blocked = _permissions.needsSettings(outcome);
    final action = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(PermissionCopy.locationTitle),
        content: Text(PermissionCopy.locationReason),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(blocked ? 'Not now' : 'Enter manually'),
          ),
          if (blocked)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Open Settings'),
            ),
        ],
      ),
    );
    if (action == true) await _permissions.openAppSettings();
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
    // Geocode the pickup address; failure must not block an address-only donation.
    final appState = context.read<AppState>();
    var locationLookupFailed = false;
    ({double latitude, double longitude})? geoResult;
    if (_pickupLatitude != null && _pickupLongitude != null) {
      geoResult = (
        latitude: _pickupLatitude!,
        longitude: _pickupLongitude!,
      );
    } else {
      try {
        geoResult = await appState.api
            .geocodeAddress(_pickupAddressController.text.trim());
      } on PlatformException {
        locationLookupFailed = true;
      } on MissingPluginException {
        locationLookupFailed = true;
      } catch (error, stackTrace) {
        debugPrint('Pickup address lookup failed: $error\n$stackTrace');
        if (!mounted) return;
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
            'Could not check this pickup address. Review it and try again.',
          ),
        ));
        return;
      }
    }
    final pickupLatitude = geoResult?.latitude;
    final pickupLongitude = geoResult?.longitude;
    if (!mounted) return;
    Navigator.of(context).pop(_NewDonationInput(
      foodName: _foodNameController.text.trim(),
      category: _category,
      vegType: _vegType!,
      quantityKg: double.tryParse(_quantityController.text.trim()) ?? 0,
      servings: int.tryParse(_servingsController.text.trim()) ?? 0,
      expiryHours: _expiryHours.round(),
      pickupAddress: _pickupAddressController.text.trim(),
      storageCondition: _storageCondition,
      foodPreparedKg: prepared,
      foodSoldKg: sold,
      foodPhoto: _photo,
      latitude: pickupLatitude,
      longitude: pickupLongitude,
      locationLookupFailed: locationLookupFailed,
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
                  key: const ValueKey('donation-food-type'),
                  initialValue: _vegType,
                  decoration: const InputDecoration(
                    labelText: 'Food type',
                    hintText: 'Select the dietary type',
                  ),
                  items: _kDonationFoodTypes.entries
                      .map((entry) => DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ))
                      .toList(),
                  onChanged: (value) => setState(() => _vegType = value),
                  validator: (value) =>
                      value == null ? 'Required for NGO matching' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String>(
                  value: _storageCondition,
                  decoration: const InputDecoration(
                      labelText: 'Storage Condition',
                      hintText: 'How is it stored?'),
                  items: _kStorageOptions
                      .map((o) => DropdownMenuItem(
                          value: o.value, child: Text(o.label)))
                      .toList(),
                  onChanged: (v) => setState(
                      () => _storageCondition = v ?? _storageCondition),
                ),
                const SizedBox(height: AppSpacing.md),
                AppInputField(
                  label: 'Pickup Address',
                  controller: _pickupAddressController,
                  prefixIcon: Icons.location_on_outlined,
                  onChanged: (_) {
                    if (_pickupLatitude == null && _pickupLongitude == null) {
                      return;
                    }
                    setState(() {
                      _pickupLatitude = null;
                      _pickupLongitude = null;
                    });
                  },
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: AppSpacing.sm),
                // Location is requested here, at the point a provider actually
                // needs it, rather than on launch. Declining is fine: the
                // address can still be typed by hand, so nothing is blocked.
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _locating ? null : _useCurrentLocation,
                    icon: _locating
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.my_location, size: 18),
                    label: const Text('Use my current location'),
                  ),
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
  final DailyFoodEntry? dailyEntry;
  final Future<void> Function()? onRefreshPrediction;
  final bool refreshingPrediction;
  final String? predictionRefreshError;

  /// Null while the real answer is still loading, which suppresses the prompt so
  /// it never flashes for a provider who has already answered.
  final VehicleAvailability? vehicleAvailability;
  final Future<void> Function(VehicleAvailability)? onVehicleAnswer;
  final bool savingVehicle;
  final bool creatingDonation;

  const _ProviderHomeTab(
      {required this.donations,
      required this.onCreateDonation,
      this.dailyEntry,
      this.onRefreshPrediction,
      this.refreshingPrediction = false,
      this.predictionRefreshError,
      this.vehicleAvailability,
      this.onVehicleAnswer,
      this.savingVehicle = false,
      this.creatingDonation = false});

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
            imageUrl: state.currentProfileImageUrl,
            onNotificationTap: () =>
                _openNotifications(context, UserRole.provider),
            onProfileTap: () {},
          ),
        ),
        if (state.profileCompletion case final completion?
            when shouldShowProfileProgress(completion))
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
              child: ProfileCompletionCard(
                role: UserRole.provider,
                completion: completion,
              ),
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
              // Transport capability prompt. A non-blocking card, so it cannot
              // reappear as a duplicate dialog on rebuild, and it never blocks
              // creating a donation or logging out. Suppressed until the real
              // value has loaded so it cannot flash for someone who already
              // answered.
              if (vehicleAvailability != null && onVehicleAnswer != null)
                VehicleAvailabilityCard(
                  value: vehicleAvailability!,
                  onAnswer: onVehicleAnswer!,
                  saving: savingVehicle,
                  role: VehicleRole.provider,
                ),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                  label: 'CREATE NEW DONATION',
                  icon: Icons.add,
                  isLoading: creatingDonation,
                  onPressed: onCreateDonation),
              const SizedBox(height: AppSpacing.lg),
              SurplusPredictionCard(
                entry: dailyEntry,
                onRefresh: onRefreshPrediction,
                refreshing: refreshingPrediction,
                refreshError: predictionRefreshError,
              ),
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
  final List<Map<String, dynamic>> claims;

  /// Re-reads the provider's donations from the backend after a handover is
  /// verified, so the completed status is reflected without a manual refresh.
  final Future<void> Function()? onRefresh;
  const _ProviderDonationsTab({
    required this.donations,
    this.claims = const [],
    this.onRefresh,
  });

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
                // A claim exists once the status has left "Available"; that is
                // the donation whose pickup can be confirmed with a code.
                final awaitingHandover =
                    donation.status == DonationStatus.claimed ||
                        donation.status == DonationStatus.inTransit;
                final hasClaimDetails = awaitingHandover ||
                    donation.status == DonationStatus.delivered;
                final claim = claims
                    .where(
                        (row) => row['donation_id']?.toString() == donation.id)
                    .firstOrNull;
                final coordinationValue = claim?['transport_coordination'];
                final coordination = coordinationValue is Map
                    ? Map<String, dynamic>.from(coordinationValue)
                    : const <String, dynamic>{};
                return DonationCard(
                  donation: donation,
                  onTap: hasClaimDetails
                      ? () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ProviderClaimedDonationScreen(
                                donation: donation,
                              ),
                            ),
                          )
                      : () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  ProviderDonationMatchDetailsScreen(
                                donation: donation,
                              ),
                            ),
                          ),
                  trailingAction: (available || awaitingHandover)
                      ? Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (awaitingHandover)
                                if (claim?['id'] != null)
                                  TransportCoordinationCard(
                                    claimId: claim!['id'].toString(),
                                    role: 'provider',
                                    initialState: coordination,
                                    delivery: claim['delivery'] is Map
                                        ? Map<String, dynamic>.from(
                                            claim['delivery'] as Map)
                                        : null,
                                  ),
                              if (awaitingHandover)
                                _VerifyHandoverAction(
                                    donation: donation, onVerified: onRefresh),
                              if (available)
                                _DonationAiActions(donation: donation),
                            ],
                          ),
                        )
                      : null,
                );
              },
            ),
    );
  }
}

class ProviderDonationMatchDetailsScreen extends StatefulWidget {
  final Donation donation;

  const ProviderDonationMatchDetailsScreen({
    super.key,
    required this.donation,
  });

  @override
  State<ProviderDonationMatchDetailsScreen> createState() =>
      _ProviderDonationMatchDetailsScreenState();
}

class _ProviderDonationMatchDetailsScreenState
    extends State<ProviderDonationMatchDetailsScreen> {
  Map<String, dynamic>? _offersResult;
  String? _offersError;
  bool _loading = true;
  bool _checkingExpiry = false;
  bool _savingFoodType = false;
  String? _foodTypeToSave;
  String? _foodTypeSaveError;

  bool get _hasActivePendingOffer {
    final offer = _offersResult?['current_offer'];
    return offer is Map && offer['status'] == 'pending';
  }

  bool get _needsFoodTypeCorrection {
    final reason = _offersResult?['matching_reason']?.toString().toLowerCase();
    return _offersResult?['matching_state'] == 'insufficient_data' &&
        reason?.contains('dietary type') == true;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _offersResult = null;
      _offersError = null;
    });
    final api = context.read<AppState>().api;
    try {
      try {
        final result = await api.getDonationOffers(widget.donation.id);
        if (mounted) {
          setState(() => _offersResult = result);
        }
      } on ApiException catch (error) {
        if (mounted) {
          setState(() => _offersError = _aiFeatureErrorMessage(
                error,
                fallback: 'Sequential offer status is temporarily unavailable.',
              ));
        }
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _checkExpiry() async {
    setState(() => _checkingExpiry = true);
    try {
      final result = await context
          .read<AppState>()
          .api
          .checkRankedOfferEscalation(widget.donation.id);
      if (!mounted) return;
      final status = result['status']?.toString();
      final message = switch (status) {
        'not_due' =>
          'The current NGO offer is still within its five-minute response window.',
        'timed_out' when result['changed'] != true =>
          'The offer status was already updated. Refresh to see the latest status.',
        'timed_out' when result['next_offer_active'] == true =>
          'The previous offer expired. SAHAAY contacted the next eligible NGO.',
        'timed_out' when result['exhausted'] == true =>
          'The offer expired. No more ranked NGOs are available.',
        'timed_out' =>
          'The offer status changed. Refresh to see the latest match.',
        'accepted' => 'This donation has already been accepted.',
        'no_active_offer' =>
          'There is no active ranked offer to escalate right now.',
        'expired' => 'This donation has expired and can no longer be offered.',
        _ => 'The offer status was checked.',
      };
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_aiFeatureErrorMessage(
            error,
            fallback: 'Offer status is temporarily unavailable.',
          )),
        ),
      );
    } finally {
      if (mounted) setState(() => _checkingExpiry = false);
    }
  }

  Future<void> _saveFoodTypeAndRetry() async {
    final foodType = _foodTypeToSave;
    if (foodType == null || _savingFoodType) return;
    setState(() {
      _savingFoodType = true;
      _foodTypeSaveError = null;
    });
    try {
      await context
          .read<AppState>()
          .api
          .updateDonationFoodType(widget.donation.id, foodType);
      if (!mounted) return;
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _foodTypeSaveError = _aiFeatureErrorMessage(
            error,
            fallback: 'Could not save the food type. Please retry.',
          ));
    } finally {
      if (mounted) setState(() => _savingFoodType = false);
    }
  }

  String _matchingEmptyStateMessage() {
    final reason = _offersResult?['matching_reason']?.toString();
    if (reason != null && reason.isNotEmpty) return reason;
    return switch (_offersResult?['matching_state']) {
      'no_matching_profiles' =>
        'No completed NGO profiles are available for matching yet.',
      'no_verified_ngos' =>
        'No completed NGO profiles are available for matching yet.',
      'not_started' =>
        'No ranked offer has been saved for this donation yet. Matching uses the saved donation and NGO profile details.',
      'insufficient_data' =>
        'Matching needs more donation details. Refresh matching after updating them.',
      'no_candidates' =>
        'No NGOs currently meet this donation’s compatibility requirements.',
      'exhausted' =>
        'All ranked NGO offers have expired or been declined. No further eligible NGOs remain in this saved ranking.',
      'closed' => 'This donation is no longer available for matching.',
      'accepted' => 'An NGO has accepted this donation.',
      _ => 'No matching NGOs are available for this donation.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final donation = widget.donation;
    final c = AppColors.of(context);
    final predictions = donation.surplusPrediction;
    final persisted = _offersResult?['ranked_candidates'];
    final savedRanked = persisted is List
        ? persisted.whereType<Map>().map((row) {
            final candidate = Map<String, dynamic>.from(row);
            final scoreDetailsValue = candidate['score_details'];
            final scoreDetails = scoreDetailsValue is Map
                ? Map<String, dynamic>.from(scoreDetailsValue)
                : const <String, dynamic>{};
            final ngoValue = candidate['ngo'];
            final ngo = ngoValue is Map
                ? Map<String, dynamic>.from(ngoValue)
                : const <String, dynamic>{};
            return <String, dynamic>{
              'rank': candidate['match_rank'],
              'match_rank': candidate['match_rank'],
              'ai_rank': candidate['ai_rank'],
              'final_score': candidate['final_score'],
              'distance_km': scoreDetails['distance_km'],
              'distance_source': scoreDetails['distance_source'],
              'distance_score': scoreDetails['distance_score'],
              'quantity_fit_score': scoreDetails['quantity_fit_score'],
              'dietary_compatibility_score':
                  scoreDetails['dietary_compatibility_score'],
              'pickup_time_feasibility_score':
                  scoreDetails['pickup_time_feasibility_score'],
              'restaurant_reliability_score':
                  scoreDetails['restaurant_reliability_score'],
              'ngo_name': ngo['organization_name'] ?? 'Eligible NGO',
              'ngo': ngo,
            };
          }).toList()
        : <Map<String, dynamic>>[];
    savedRanked.sort((a, b) {
      final aRank = a['match_rank'];
      final bRank = b['match_rank'];
      return (aRank is num ? aRank : 1 << 30)
          .compareTo(bRank is num ? bRank : 1 << 30);
    });
    final displayedRankings = savedRanked;
    final usingSavedRanking = savedRanked.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Donation details'),
        actions: [
          IconButton(
            tooltip: 'Refresh matching',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                if (donation.foodImageUrl?.isNotEmpty == true)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    child: Image.network(
                      donation.foodImageUrl!,
                      height: 190,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                if (donation.foodImageUrl?.isNotEmpty != true)
                  const Card(
                    child: SizedBox(
                      height: 64,
                      child: Center(child: Text('Donation photo unavailable')),
                    ),
                  ),
                Text(donation.foodName,
                    style: Theme.of(context).textTheme.headlineSmall),
                if (donation.description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(donation.description,
                      style: TextStyle(color: c.textSecondary)),
                ],
                const SizedBox(height: AppSpacing.md),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Column(
                      children: [
                        _detailRow(context, Icons.category_outlined, 'Category',
                            donation.category),
                        _detailRow(
                          context,
                          Icons.scale_outlined,
                          'Quantity',
                          '${donation.quantity.toStringAsFixed(1)} ${donation.quantityUnit}',
                        ),
                        _detailRow(context, Icons.groups_outlined, 'Servings',
                            '${donation.servings}'),
                        if (donation.vegType.isNotEmpty)
                          _detailRow(context, Icons.restaurant_outlined,
                              'Food type', donation.vegType),
                        _detailRow(context, Icons.eco_outlined, 'Freshness',
                            donation.freshnessLabel),
                        if (donation.expiryLabel.isNotEmpty)
                          _detailRow(context, Icons.schedule_outlined,
                              'Pickup deadline', donation.expiryLabel),
                        if (donation.foodExpiryLabel?.isNotEmpty == true)
                          _detailRow(context, Icons.event_busy_outlined,
                              'Food expiry', donation.foodExpiryLabel!),
                        _readableAddressRow(context, donation),
                      ],
                    ),
                  ),
                ),
                if (predictions != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('AI surplus prediction',
                              style: TextStyle(fontWeight: FontWeight.w800)),
                          if (predictions['predicted_surplus'] is num)
                            Text(
                              'Predicted surplus: ${(predictions['predicted_surplus'] as num).toStringAsFixed(1)} kg',
                            ),
                          if (predictions['planned_quantity'] != null)
                            Text(
                              'Planned quantity: ${predictions['planned_quantity']}',
                            ),
                          if (predictions['recommendation']
                                  ?.toString()
                                  .isNotEmpty ==
                              true)
                            Text(
                              'Recommendation: ${predictions['recommendation']}',
                            ),
                          if (predictions['prediction_date'] != null)
                            Text(
                              'Prediction date: ${predictions['prediction_date']}',
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                SahaayGoogleMap(
                  height: 170,
                  latitude: donation.latitude,
                  longitude: donation.longitude,
                  markerTitle: donation.foodName,
                  markerSnippet:
                      readableAddressOrUnavailable(donation.providerAddress),
                ),
                const SizedBox(height: AppSpacing.lg),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Eligible NGOs',
                        style: Theme.of(context).textTheme.titleLarge),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton.icon(
                        onPressed: _checkingExpiry || !_hasActivePendingOffer
                            ? null
                            : _checkExpiry,
                        icon: _checkingExpiry
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.autorenew, size: 16),
                        label: const Text('Escalate'),
                      ),
                    ),
                  ],
                ),
                if (_offersResult != null && !_hasActivePendingOffer)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Text(
                      'Escalation is available after a ranked NGO has an active pending offer.',
                      style: TextStyle(color: c.textSecondary),
                    ),
                  ),
                if (_offersError != null)
                  Text(_offersError!, style: TextStyle(color: c.danger)),
                if (_offersResult?['refresh_warning'] is String &&
                    (_offersResult!['refresh_warning'] as String).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Text(
                      _offersResult!['refresh_warning'] as String,
                      style: TextStyle(color: c.textSecondary),
                    ),
                  ),
                if (_needsFoodTypeCorrection) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Choose the donation food type',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          const Text(
                            'A dietary type is required to check NGO compatibility. Select the correct value; SAHAAY will then retry matching.',
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          DropdownButtonFormField<String>(
                            key:
                                const ValueKey('donation-food-type-correction'),
                            initialValue: _foodTypeToSave,
                            decoration: const InputDecoration(
                              labelText: 'Food type',
                            ),
                            items: _kDonationFoodTypes.entries
                                .map((entry) => DropdownMenuItem(
                                      value: entry.key,
                                      child: Text(entry.value),
                                    ))
                                .toList(),
                            onChanged: _savingFoodType
                                ? null
                                : (value) =>
                                    setState(() => _foodTypeToSave = value),
                          ),
                          if (_foodTypeSaveError != null) ...[
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              _foodTypeSaveError!,
                              style: TextStyle(color: c.danger),
                            ),
                          ],
                          const SizedBox(height: AppSpacing.sm),
                          FilledButton(
                            onPressed:
                                _savingFoodType || _foodTypeToSave == null
                                    ? null
                                    : _saveFoodTypeAndRetry,
                            child: Text(_savingFoodType
                                ? 'Saving and matching…'
                                : 'Save food type and retry'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (usingSavedRanking)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Showing the authoritative ranking saved by the backend.',
                    ),
                  ),
                if (displayedRankings.isEmpty)
                  Text(
                    _matchingEmptyStateMessage(),
                    style: TextStyle(color: c.textSecondary),
                  )
                else
                  for (final item in displayedRankings) ...[
                    InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      onTap: () => _showNgoFactors(
                        context,
                        item,
                        live: !usingSavedRanking,
                      ),
                      child: _RankedNgoTile(item: item),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                if (_offersResult?['matching_state'] != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _ProviderOfferStatus(
                    matchingState: _offersResult!['matching_state'].toString(),
                    currentOffer: _offersResult!['current_offer'] is Map
                        ? Map<String, dynamic>.from(
                            _offersResult!['current_offer'] as Map)
                        : null,
                  ),
                ],
              ],
            ),
    );
  }

  Widget _detailRow(
      BuildContext context, IconData icon, String label, String value) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: c.textSecondary),
          const SizedBox(width: 10),
          Expanded(
              child: Text(label, style: TextStyle(color: c.textSecondary))),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.end,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _readableAddressRow(BuildContext context, Donation donation) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(Icons.location_on_outlined, size: 18, color: c.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Pickup address',
                style: TextStyle(color: c.textSecondary)),
          ),
          Flexible(
            child: ReadableAddressText(
              address: donation.providerAddress,
              latitude: donation.latitude,
              longitude: donation.longitude,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  void _showNgoFactors(
    BuildContext context,
    Map<String, dynamic> item, {
    required bool live,
  }) {
    final ngoValue = item['ngo'];
    final ngo = ngoValue is Map
        ? Map<String, dynamic>.from(ngoValue)
        : const <String, dynamic>{};
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item['ngo_name']?.toString() ?? 'Eligible NGO'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(matchScoreLabel(item['final_score'] is num
                  ? item['final_score'] as num
                  : null)),
              const SizedBox(height: 6),
              Text(matchingDistanceLabel(
                item['distance_km'] is num ? item['distance_km'] as num : null,
                item['distance_source'],
              )),
              Text(live
                  ? 'Eligibility was checked by the backend for this refresh.'
                  : 'This is a saved candidate; current eligibility was not confirmed.'),
              for (final factor in [
                ('Distance score', 'distance_score'),
                ('Quantity fit', 'quantity_fit_score'),
                ('Food compatibility', 'dietary_compatibility_score'),
                ('Pickup-time fit', 'pickup_time_feasibility_score'),
                ('Provider reliability', 'restaurant_reliability_score'),
              ])
                if (item[factor.$2] is num)
                  Text(
                    '${factor.$1}: ${(item[factor.$2] as num).toStringAsFixed(0)} / 100',
                  ),
              if (ngo['max_capacity_kg'] != null)
                Text('Maximum donation weight: ${ngo['max_capacity_kg']} kg'),
              if (ngo['food_capacity'] != null)
                Text('People served per day: ${ngo['food_capacity']}'),
              if (ngo['preferred_food_types'] is List)
                Text(
                  'Accepted food types: ${(ngo['preferred_food_types'] as List).join(', ')}',
                ),
              if (ngo['available_from'] != null && ngo['available_to'] != null)
                Text(
                  'Availability: ${ngo['available_from']}–${ngo['available_to']}',
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// Shared post-claim facts for all participant roles. Data is rendered only
/// from persisted donation/profile/claim rows; absent optional fields stay
/// explicitly unavailable.
class ClaimedDonationFacts extends StatelessWidget {
  final Donation donation;
  final Map<String, dynamic>? provider;
  final Map<String, dynamic>? ngo;
  final Map<String, dynamic>? delivery;
  final Map<String, dynamic>? transportCoordination;

  const ClaimedDonationFacts({
    super.key,
    required this.donation,
    this.provider,
    this.ngo,
    this.delivery,
    this.transportCoordination,
  });

  String _text(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? 'Not provided' : text;
  }

  Future<void> _openLocation(
    BuildContext context, {
    double? latitude,
    double? longitude,
    String? address,
  }) async {
    final mapUri = googleMapsUriForLocation(
      latitude: latitude,
      longitude: longitude,
      address: address,
    );
    if (mapUri == null) return;
    try {
      final opened = await launchUrl(
        mapUri,
        mode: LaunchMode.externalApplication,
      );
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the map location.')),
        );
      }
    } on PlatformException catch (error) {
      debugPrint('Could not open saved map location: $error');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the map location.')),
        );
      }
    } on MissingPluginException catch (error) {
      debugPrint('Map launcher plugin unavailable: $error');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Map opening is not available.')),
        );
      }
    }
  }

  Future<void> _dial(BuildContext context, String? phone) async {
    final uri = dialerUriForPhone(phone);
    if (uri == null) return;
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the phone dialer.')),
        );
      }
    } on PlatformException catch (error) {
      debugPrint('Could not open phone dialer: $error');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the phone dialer.')),
        );
      }
    }
  }

  Widget _fact(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(color: AppColors.of(context).textSecondary),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: Text(value, textAlign: TextAlign.end),
            ),
          ],
        ),
      );

  Widget _phone(BuildContext context, String label, String? phone) {
    final uri = dialerUriForPhone(phone);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(color: AppColors.of(context).textSecondary)),
          ),
          if (uri == null)
            const Text('Not provided')
          else
            TextButton.icon(
              onPressed: () => _dial(context, phone),
              icon: const Icon(Icons.phone_outlined, size: 16),
              label: Text(phone!.trim()),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final providerDetails = provider ?? const <String, dynamic>{};
    final ngoDetails = ngo ?? const <String, dynamic>{};
    final deliveryDetails = delivery ?? const <String, dynamic>{};
    final pickup = _addressWithCity(
      donation.providerAddress ?? providerDetails['address'],
      providerDetails['city'],
    );
    final destination =
        _addressWithCity(ngoDetails['address'], ngoDetails['city']);
    final ngoLat = (ngoDetails['latitude'] as num?)?.toDouble();
    final ngoLng = (ngoDetails['longitude'] as num?)?.toDouble();
    final points = <SahaayMapPoint>[
      if (donation.latitude != null && donation.longitude != null)
        SahaayMapPoint(
          latitude: donation.latitude!,
          longitude: donation.longitude!,
          title: 'Pickup',
          snippet: pickup,
        ),
      if (ngoLat != null && ngoLng != null)
        SahaayMapPoint(
          latitude: ngoLat,
          longitude: ngoLng,
          title: 'Drop-off',
          snippet: destination,
          markerHue: SahaayMapPoint.destinationHue,
        ),
    ];
    final coordination = transportCoordination ?? const <String, dynamic>{};
    final volunteer = deliveryDetails['volunteer'];
    final volunteerDetails =
        volunteer is Map ? Map<String, dynamic>.from(volunteer) : const {};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (donation.foodImageUrl?.isNotEmpty == true)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              donation.foodImageUrl!,
              height: 190,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(
                height: 80,
                child: Center(child: Text('Donation photo unavailable')),
              ),
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(donation.foodName,
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                _fact(context, 'Description', _text(donation.description)),
                _fact(context, 'Category', _text(donation.category)),
                _fact(
                  context,
                  'Quantity',
                  '${donation.quantity.toStringAsFixed(1)} ${donation.quantityUnit} • ${donation.servings} servings',
                ),
                _fact(context, 'Food type', _text(donation.vegType)),
                _fact(context, 'Freshness', donation.freshnessLabel),
                _fact(
                  context,
                  'Prepared',
                  donation.preparedAt == null
                      ? 'Not provided'
                      : _dateTimeLabel(donation.preparedAt!),
                ),
                _fact(
                  context,
                  'Expires',
                  donation.foodExpiryLabel ?? 'Not provided',
                ),
                _fact(
                    context,
                    'Pickup deadline',
                    donation.expiryLabel.isEmpty
                        ? 'Not provided'
                        : donation.expiryLabel),
                _fact(
                  context,
                  'Donation created',
                  donation.createdAt == null
                      ? 'Not provided'
                      : _dateTimeLabel(donation.createdAt!),
                ),
                _fact(context, 'Donation status',
                    donationStatusLabel(donation.status)),
                _fact(context, 'Claim status', _text(donation.claimStatus)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        SahaayGoogleMap(
          height: 190,
          points: points,
          markerTitle: donation.foodName,
          markerSnippet: readableAddressOrUnavailable(pickup),
          onMarkerInfoWindowTap: _openGoogleMaps,
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () => _openLocation(
                context,
                latitude: donation.latitude,
                longitude: donation.longitude,
                address: pickup,
              ),
              icon: const Icon(Icons.my_location_outlined),
              label: const Text('Open pickup in Maps'),
            ),
            if (ngoLat != null && ngoLng != null ||
                destination?.isNotEmpty == true)
              TextButton.icon(
                onPressed: () => _openLocation(
                  context,
                  latitude: ngoLat,
                  longitude: ngoLng,
                  address: destination,
                ),
                icon: const Icon(Icons.location_on_outlined),
                label: const Text('Open drop-off in Maps'),
              ),
          ],
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Provider / restaurant',
                    style: Theme.of(context).textTheme.titleMedium),
                _fact(
                  context,
                  'Name',
                  _text(providerDetails['organization_name'] ??
                      donation.providerName),
                ),
                _fact(
                  context,
                  'Pickup address',
                  readableAddressOrUnavailable(pickup),
                ),
                _phone(
                  context,
                  'Contact',
                  providerDetails['phone']?.toString() ??
                      donation.providerContactNumber,
                ),
                const Divider(),
                Text('Receiving NGO',
                    style: Theme.of(context).textTheme.titleMedium),
                _fact(
                  context,
                  'Name',
                  _text(ngoDetails['organization_name']),
                ),
                _fact(
                  context,
                  'Drop-off address',
                  readableAddressOrUnavailable(destination),
                ),
                _phone(context, 'Contact', ngoDetails['phone']?.toString()),
                if (coordination.isNotEmpty) ...[
                  const Divider(),
                  _fact(
                    context,
                    'Transport arrangement',
                    transportCoordinationStatusLabel(coordination['status']),
                  ),
                  if (coordination['responsible_role'] == 'volunteer') ...[
                    _fact(context, 'Responsible person',
                        _text(volunteerDetails['full_name'])),
                    _phone(context, 'Assigned contact',
                        volunteerDetails['phone']?.toString()),
                  ],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class TransportCoordinationCard extends StatefulWidget {
  final String claimId;
  final String role;
  final Map<String, dynamic>? initialState;
  final Map<String, dynamic>? delivery;

  const TransportCoordinationCard({
    super.key,
    required this.claimId,
    required this.role,
    this.initialState,
    this.delivery,
  });

  @override
  State<TransportCoordinationCard> createState() =>
      _TransportCoordinationCardState();
}

class _TransportCoordinationCardState extends State<TransportCoordinationCard> {
  Map<String, dynamic>? _state;
  bool _loading = true;
  bool _sending = false;
  String? _error;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _state =
        widget.initialState?.isNotEmpty == true ? widget.initialState : null;
    _load();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) {
        if (mounted && !_sending && !_loading) _load();
      },
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TransportCoordinationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialState != widget.initialState &&
        widget.initialState?.isNotEmpty == true) {
      _state = widget.initialState;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final coordination = await context
          .read<AppState>()
          .api
          .getTransportCoordination(widget.claimId);
      if (!mounted) return;
      setState(() {
        _state = coordination;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message.isEmpty
            ? 'Transport coordination is not available yet.'
            : error.message;
        _loading = false;
      });
    }
  }

  Future<void> _respond(String response) async {
    String? captainName;
    String? captainPhone;
    if (response == 'yes') {
      final nameController = TextEditingController();
      final phoneController = TextEditingController();
      final details = await showDialog<({String name, String phone})>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Transport contact'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Captain name'),
              ),
              TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Mobile number'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop((
                name: nameController.text.trim(),
                phone: phoneController.text.trim(),
              )),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      nameController.dispose();
      phoneController.dispose();
      if (details == null || !mounted) return;
      captainName = details.name;
      captainPhone = normalizeIndianMobileNumber(details.phone);
      if (captainName.isEmpty || captainPhone == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Enter the captain name and a valid 10-digit Indian mobile number.',
            ),
          ),
        );
        return;
      }
    }

    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final coordination =
          await context.read<AppState>().api.respondToTransportCoordination(
                widget.claimId,
                response: response,
                captainName: captainName,
                captainPhone: captainPhone,
              );
      if (!mounted) return;
      setState(() => _state = coordination);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _responseLabel(Object? value) {
    switch (value) {
      case 'yes':
        return 'Will handle transport';
      case 'no':
        return 'Cannot handle transport';
      default:
        return 'Response pending';
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state ?? const <String, dynamic>{};
    final role = widget.role;
    final otherRole = role == 'provider' ? 'ngo' : 'provider';
    final ownResponse = state['${role}_response'];
    final otherResponse = state['${otherRole}_response'];
    final status = state['status']?.toString();
    final responsible = state['responsible_role']?.toString();
    final responsibleLabel = switch (responsible) {
      'provider' => 'Provider delivery',
      'ngo' => 'NGO pickup',
      'volunteer' => 'Volunteer delivery',
      _ => null,
    };
    final captainName = state['${responsible}_captain_name']?.toString();
    final captainPhone = state['${responsible}_captain_phone']?.toString();
    final delivery = widget.delivery ?? const <String, dynamic>{};
    final volunteerValue = delivery['volunteer'];
    final volunteer = volunteerValue is Map
        ? Map<String, dynamic>.from(volunteerValue)
        : const <String, dynamic>{};
    final displayName = responsible == 'volunteer'
        ? volunteer['full_name']?.toString()
        : captainName;
    final displayPhone = responsible == 'volunteer'
        ? volunteer['phone']?.toString()
        : captainPhone;
    final prompt = role == 'ngo'
        ? 'Are you going to pick up the donation?'
        : 'Are you going to deliver the donation?';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Delivery coordination',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_loading && _state == null)
              const LinearProgressIndicator()
            else if (_error != null && _state == null)
              Row(
                children: [
                  Expanded(child: Text(_error!)),
                  IconButton(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Retry',
                  ),
                ],
              )
            else ...[
              Text('Your response: ${_responseLabel(ownResponse)}'),
              Text('$otherRole: ${_responseLabel(otherResponse)}'),
              if (responsibleLabel != null) ...[
                Text('Arrangement: $responsibleLabel'),
                if (displayName?.trim().isNotEmpty == true)
                  Text('Captain / volunteer: ${displayName!.trim()}'),
                if (dialerUriForPhone(displayPhone) case final uri?)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final opened = await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        );
                        if (!opened && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Could not open the dialer.')),
                          );
                        }
                      },
                      icon: const Icon(Icons.phone_outlined),
                      label: Text(displayPhone!),
                    ),
                  ),
              ],
              if (status == 'searching_for_volunteers') ...[
                const SizedBox(height: 8),
                const Row(
                  children: [
                    SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Expanded(child: Text('Searching for volunteers')),
                  ],
                ),
              ] else if (status == 'volunteer_assigned' &&
                  responsibleLabel == null)
                const Text('A volunteer has accepted this delivery task.'),
              if (responsible == null) ...[
                const SizedBox(height: 8),
                if (ownResponse == null)
                  Text(prompt,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                if (ownResponse == null)
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: _sending ? null : () => _respond('yes'),
                        child: const Text('Yes'),
                      ),
                      OutlinedButton(
                        onPressed: _sending ? null : () => _respond('no'),
                        child: const Text('No'),
                      ),
                    ],
                  ),
              ],
            ],
            if (_sending)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
            if (_error != null && _state != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: AppColors.of(context).danger),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Provider-owned view of an accepted donation and its real claim/NGO details.
/// The API resolves claims only for donations owned by the authenticated user.
class ProviderClaimedDonationScreen extends StatefulWidget {
  final Donation donation;

  const ProviderClaimedDonationScreen({super.key, required this.donation});

  @override
  State<ProviderClaimedDonationScreen> createState() =>
      _ProviderClaimedDonationScreenState();
}

class _ProviderClaimedDonationScreenState
    extends State<ProviderClaimedDonationScreen> {
  Map<String, dynamic>? _claim;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadClaim();
  }

  Future<void> _loadClaim() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final claims = await context.read<AppState>().api.getProviderClaims();
      final matchingClaim = claims
          .whereType<Map>()
          .map(
            (row) => Map<String, dynamic>.from(row),
          )
          .where((row) => row['donation_id']?.toString() == widget.donation.id);
      if (!mounted) return;
      setState(() {
        _claim = matchingClaim.isEmpty ? null : matchingClaim.first;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _apiErrorMessage(
          e,
          fallback: 'Could not load the claim details.',
        );
        _loading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('Could not load provider claim details: $error\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the claim details. Check your connection.';
        _loading = false;
      });
    }
  }

  String _claimStatusLabel(Object? status) {
    switch (status) {
      case 'pending':
        return 'Awaiting handover';
      case 'accepted':
        return 'Accepted';
      case 'rejected':
        return 'Declined';
      case 'cancelled':
        return 'Cancelled';
      case 'completed':
        return 'Completed';
      default:
        return 'Status unavailable';
    }
  }

  @override
  Widget build(BuildContext context) {
    final donation = widget.donation;
    final claimDonationValue = _claim?['donation'];
    final claimDonation = claimDonationValue is Map
        ? Donation.fromBackend(
            Map<String, dynamic>.from(claimDonationValue)
              ..['claim_status'] = _claim?['status'],
            includePrivateContacts: true,
          )
        : donation;
    final claimNgo = _claim?['ngo'];
    final ngo = claimNgo is Map
        ? Map<String, dynamic>.from(claimNgo)
        : const <String, dynamic>{};
    final providerValue = _claim?['provider'];
    final provider = providerValue is Map
        ? Map<String, dynamic>.from(providerValue)
        : const <String, dynamic>{};
    final deliveryValue = _claim?['delivery'];
    final delivery = deliveryValue is Map
        ? Map<String, dynamic>.from(deliveryValue)
        : const <String, dynamic>{};
    final coordinationValue = _claim?['transport_coordination'];
    final coordination = coordinationValue is Map
        ? Map<String, dynamic>.from(coordinationValue)
        : const <String, dynamic>{};

    return Scaffold(
      appBar: AppBar(title: const Text('Donation details')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          ClaimedDonationFacts(
            donation: claimDonation,
            provider: provider,
            ngo: ngo,
            delivery: delivery,
            transportCoordination: coordination,
          ),
          const SizedBox(height: AppSpacing.md),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_error!),
                TextButton.icon(
                  onPressed: _loadClaim,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            )
          else if (_claim == null)
            const Text('Claim details are not available yet.')
          else ...[
            Text('Claim status: ${_claimStatusLabel(_claim!['status'])}'),
            if (_claim!['id'] != null)
              TransportCoordinationCard(
                claimId: _claim!['id'].toString(),
                role: 'provider',
                initialState: coordination,
              ),
            _VerifyHandoverAction(
              donation: claimDonation,
              onVerified: _loadClaim,
            ),
          ],
        ],
      ),
    );
  }
}

/// Opens the provider-side handover confirmation flow for a donation whose
/// claim is waiting on pickup. The code is entered by the provider at handover.
class _VerifyHandoverAction extends StatelessWidget {
  final Donation donation;
  final Future<void> Function()? onVerified;
  const _VerifyHandoverAction({required this.donation, this.onVerified});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        height: 34,
        child: OutlinedButton.icon(
          onPressed: () async {
            final verified = await Navigator.of(context).push<bool>(
              MaterialPageRoute(
                  builder: (_) =>
                      ProviderHandoverVerifyScreen(donation: donation)),
            );
            if (verified == true && onVerified != null) {
              await onVerified!();
            }
          },
          icon: const Icon(Icons.verified_outlined, size: 16),
          label: const Text('Verify Handover',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}

/// Provider-side handover confirmation. The provider enters the one-time code
/// shown by the receiving NGO (or the delivering volunteer) at pickup; the
/// backend validates it and completes the donation. Failure states mirror the
/// backend: a wrong code reports the remaining attempts, an expired code asks
/// for a fresh one, and a locked code reports too many attempts.
class ProviderHandoverVerifyScreen extends StatefulWidget {
  final Donation donation;
  const ProviderHandoverVerifyScreen({super.key, required this.donation});

  @override
  State<ProviderHandoverVerifyScreen> createState() =>
      _ProviderHandoverVerifyScreenState();
}

class _ProviderHandoverVerifyScreenState
    extends State<ProviderHandoverVerifyScreen> {
  final _codeController = TextEditingController();
  bool _verifying = false;
  bool _verified = false;
  String? _error;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the handover code.');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final result = await context
          .read<AppState>()
          .api
          .verifyHandoverCode(widget.donation.id, code);
      if (!mounted) return;
      setState(() {
        _verified = result['handover_verified'] == true ||
            result['already_verified'] == true;
        _verifying = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message.isNotEmpty
            ? e.message
            : 'That handover code is not correct. Please try again.';
        _verifying = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final d = widget.donation;
    return Scaffold(
      appBar: AppBar(title: const Text('Verify Handover')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(d.foodName, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('${d.quantityKg.toStringAsFixed(0)} kg • ${d.servings} servings',
              style: TextStyle(color: c.textSecondary)),
          const SizedBox(height: AppSpacing.lg),
          if (_verified) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(children: [
                  Icon(Icons.verified, color: c.green),
                  const SizedBox(width: 8),
                  const Expanded(
                      child: Text('Handover verified successfully. The '
                          'donation is complete.')),
                ]),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            PrimaryButton(
                label: 'DONE',
                onPressed: () => Navigator.of(context).pop(true)),
          ] else ...[
            Text(
              'Enter the one-time code provided by the receiving NGO to '
              'confirm the physical handover.',
              style: TextStyle(fontSize: 13, color: c.textSecondary),
            ),
            const SizedBox(height: 16),
            AppInputField(
              label: 'Handover code',
              controller: _codeController,
              keyboardType: TextInputType.number,
              prefixIcon: Icons.lock_outline,
              helperText: _error,
            ),
            const SizedBox(height: 12),
            PrimaryButton(
                label: 'VERIFY HANDOVER',
                onPressed: _verifying ? null : _verify,
                isLoading: _verifying),
          ],
        ]),
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
  bool _downloading = false;

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _matchNgos() async {
    if (_matching) return;
    setState(() => _matching = true);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProviderDonationMatchDetailsScreen(
          donation: widget.donation,
        ),
      ),
    );
    if (mounted) setState(() => _matching = false);
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
      final saved = await saveAcknowledgmentPdf(widget.donation.id, bytes);
      if (!mounted) return;
      _snack('Acknowledgment PDF saved to ${saved.location}');
    } on ApiException catch (e) {
      if (!mounted) return;
      _snack(_aiFeatureErrorMessage(e,
          fallback: 'Acknowledgment generation is temporarily unavailable.'));
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  /// The owning provider downloads the exact same persisted receipt the NGO
  /// receives. Distinct from generate: it never re-runs the AI service.
  Future<void> _downloadAcknowledgment() async {
    setState(() => _downloading = true);
    try {
      final bytes = await context
          .read<AppState>()
          .api
          .downloadAcknowledgment(widget.donation.id);
      if (!mounted) return;
      final saved = await saveAcknowledgmentPdf(widget.donation.id, bytes);
      if (!mounted) return;
      _snack('Receipt saved to ${saved.location}');
    } on ApiException catch (e) {
      if (!mounted) return;
      _snack(_aiFeatureErrorMessage(e,
          fallback: 'The receipt is not available yet.'));
    } finally {
      if (mounted) setState(() => _downloading = false);
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
        if (completed)
          SizedBox(
            height: 34,
            child: OutlinedButton.icon(
              onPressed: _downloading ? null : _downloadAcknowledgment,
              icon: _downloading
                  ? const SizedBox(
                      height: 12,
                      width: 12,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download_outlined, size: 16),
              label: const Text('Download Receipt',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ),
      ],
    );
  }
}

class _ProviderOfferStatus extends StatelessWidget {
  final String matchingState;
  final Map<String, dynamic>? currentOffer;

  const _ProviderOfferStatus({
    required this.matchingState,
    required this.currentOffer,
  });

  String _label() {
    if (matchingState == 'accepted') {
      return 'An NGO has accepted this donation.';
    }
    if (matchingState == 'exhausted') {
      return 'All eligible ranked NGOs have been contacted.';
    }
    if (matchingState == 'closed') {
      return 'Matching is closed for this donation.';
    }
    if (matchingState != 'active') {
      return 'No active sequential offer is recorded.';
    }
    if (currentOffer == null || currentOffer!['status'] != 'pending') {
      return 'The ranked offer is being updated.';
    }
    final rank = currentOffer!['candidate_rank'];
    final rankLabel = rank is int && rank > 0 ? ' #$rank' : '';
    final deadline =
        DateTime.tryParse(currentOffer!['offer_expires_at']?.toString() ?? '');
    if (deadline == null) {
      return 'A five-minute offer is active for ranked NGO$rankLabel; its deadline is unavailable.';
    }
    final local = deadline.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = local.hour < 12 ? 'AM' : 'PM';
    return 'Five-minute offer sent to ranked NGO$rankLabel. Respond by '
        '${local.month}/${local.day} at $hour:$minute $period.';
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.of(context).surfaceAlt,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(_label(), style: const TextStyle(fontSize: 12)),
      );
}

class _RankedNgoTile extends StatelessWidget {
  final Map<String, dynamic> item;
  const _RankedNgoTile({required this.item});

  /// Pairwise logistics status computed by the backend from BOTH the provider's
  /// and the NGO's own vehicle answers.
  ///
  /// Falls back to [VehicleCompatibility.unknown] when the key is missing, which
  /// is the honest reading: nothing is claimed about transport.
  VehicleCompatibility get _compatibility =>
      VehicleCompatibility.fromBackend(item['vehicle_compatibility']);

  /// True only when the backend confirmed a volunteer is required. Derived from
  /// the capability rather than re-derived here, so `unknown` can never be
  /// mistaken for a volunteer requirement.
  bool get _volunteerRequired => _compatibility.needsVolunteer;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final distance = item['distance_km'];
    final finalScore = item['final_score'];
    final rank = item['match_rank'] ?? item['rank'];
    final ngo = item['ngo'];
    final ngoMap =
        ngo is Map ? Map<String, dynamic>.from(ngo) : const <String, dynamic>{};
    final ngoAddress = ngoMap['address']?.toString();
    final ngoCity = ngoMap['city']?.toString();
    String factorScore(String label, dynamic value) =>
        value is num && value.isFinite && value >= 0 && value <= 100
            ? '$label ${value.toStringAsFixed(0)}%'
            : '';
    final factorLabels = [
      factorScore('Distance', item['distance_score']),
      factorScore('Quantity', item['quantity_fit_score']),
      factorScore('Food', item['dietary_compatibility_score']),
      factorScore('Pickup time', item['pickup_time_feasibility_score']),
      factorScore('Reliability', item['restaurant_reliability_score']),
    ].where((value) => value.isNotEmpty).join(' · ');
    final compatibility = _compatibility;
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
                    matchingDistanceLabel(distance is num ? distance : null,
                        item['distance_source']),
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                  ),
                  const SizedBox(height: 3),
                  ReadableAddressText(
                    address: ngoAddress == null || ngoAddress.trim().isEmpty
                        ? (ngoCity == null || ngoCity.trim().isEmpty
                            ? null
                            : ngoCity)
                        : ngoCity == null || ngoCity.trim().isEmpty
                            ? ngoAddress
                            : '$ngoAddress, $ngoCity',
                    latitude: _coordinateFromMap(ngoMap, 'latitude', 90),
                    longitude: _coordinateFromMap(ngoMap, 'longitude', 180),
                    style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                  ),
                  const SizedBox(height: 6),
                  // Logistics capability, not a match-quality claim: this
                  // says who can move the food, never "best AI match".
                  LogisticsStatusBadge(
                      compatibility: compatibility, compact: true),
                  if (_volunteerRequired) ...[
                    const SizedBox(height: 4),
                    Text(
                      compatibility.detail,
                      style: TextStyle(
                        fontSize: 11,
                        color: c.textSecondary,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                  if (factorLabels.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Factors /100: $factorLabels',
                      style: TextStyle(fontSize: 10.5, color: c.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  matchScoreLabel(finalScore is num ? finalScore : null),
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                      color: c.bluePrimary),
                ),
                Text(
                    rank is int && rank > 0
                        ? 'Matching rank #$rank'
                        : 'Rank unavailable',
                    style: TextStyle(fontSize: 10.5, color: c.textSecondary)),
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
          ImpactCardGrid(cards: [
            ImpactCard(
                emoji: '🌱',
                value: '${totalKg.toStringAsFixed(0)} kg',
                label: 'Food Saved'),
            ImpactCard(emoji: '🍱', value: '$meals', label: 'Meals Supported'),
            ImpactCard(
                emoji: '💙', value: '$completed', label: 'Donations Completed'),
            const ImpactCard(emoji: '⭐', value: '—', label: 'NGO Rating'),
          ]),
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
// NGO VEHICLE AVAILABILITY
// =============================================================================

/// The NGO's answer to "do you currently have a vehicle available for food
/// pickup?".
///
/// [unanswered] is deliberately distinct from [no]: the first means the NGO
/// has not been asked yet, the second is an authoritative "no vehicle". Keeping
/// them separate preserves the tri-state the backend stores.
enum VehicleAvailability {
  unanswered,
  yes,
  no;

  /// Wire value for `ngos.vehicle_available`: null == not answered.
  bool? get backendValue => switch (this) {
        VehicleAvailability.unanswered => null,
        VehicleAvailability.yes => true,
        VehicleAvailability.no => false,
      };

  static VehicleAvailability fromBackend(Object? raw) => switch (raw) {
        true => VehicleAvailability.yes,
        false => VehicleAvailability.no,
        _ => VehicleAvailability.unanswered,
      };

  String get label => switch (this) {
        VehicleAvailability.unanswered => 'Not answered yet',
        VehicleAvailability.yes => 'Yes, I have a vehicle',
        VehicleAvailability.no => "No, I don't",
      };

  String get shortLabel => switch (this) {
        VehicleAvailability.unanswered => 'Not set',
        VehicleAvailability.yes => 'Available',
        VehicleAvailability.no => 'No vehicle',
      };
}

/// Whether a specific donation↔NGO pair can be completed without a volunteer.
///
/// Computed by the backend (app/services/vehicle_logistics.py) from the
/// PROVIDER's and the NGO's own tri-state answers, and surfaced here so the UI
/// can explain the pairing. This is a logistics capability statement, never a
/// claim about AI match quality.
enum VehicleCompatibility {
  /// The provider has a vehicle and can bridge the gap to the NGO.
  providerTransport,

  /// The NGO has a vehicle and can collect from the provider.
  ngoTransport,

  /// Both sides have transport, so either can support the pickup.
  bothTransport,

  /// Neither side can transport: a volunteer is needed to bridge the pickup.
  /// The NGO is still eligible and claimable.
  volunteerRequired,

  /// At least one side has not answered, so capability is unknown. Deliberately
  /// NOT treated as "no vehicle" and never escalated to volunteerRequired.
  unknown;

  /// Wire value from the matching response.
  String get wireValue => switch (this) {
        VehicleCompatibility.providerTransport => 'provider_transport',
        VehicleCompatibility.ngoTransport => 'ngo_transport',
        VehicleCompatibility.bothTransport => 'both_transport',
        VehicleCompatibility.volunteerRequired => 'volunteer_required',
        VehicleCompatibility.unknown => 'unknown',
      };

  /// Parses a `vehicle_compatibility` value from the backend. An absent or
  /// unrecognised value falls back to [unknown], which is the safe reading:
  /// capability is simply not known.
  static VehicleCompatibility fromBackend(Object? raw) => switch (raw) {
        'provider_transport' => VehicleCompatibility.providerTransport,
        'ngo_transport' => VehicleCompatibility.ngoTransport,
        'both_transport' => VehicleCompatibility.bothTransport,
        'volunteer_required' => VehicleCompatibility.volunteerRequired,
        _ => VehicleCompatibility.unknown,
      };

  /// Concise status shown under a matched NGO. Phrased as who can move the
  /// food, never as a match-quality claim.
  String get label => switch (this) {
        VehicleCompatibility.providerTransport => 'Provider can transport',
        VehicleCompatibility.ngoTransport => 'NGO can transport',
        VehicleCompatibility.bothTransport => 'Both have transport',
        VehicleCompatibility.volunteerRequired =>
          'Volunteer transport required',
        VehicleCompatibility.unknown => 'Transport availability unknown',
      };

  String get detail => switch (this) {
        VehicleCompatibility.providerTransport =>
          'You have a vehicle, so you can deliver this food to the NGO.',
        VehicleCompatibility.ngoTransport =>
          'This NGO has a vehicle and can collect the food from you.',
        VehicleCompatibility.bothTransport =>
          'You and this NGO both have transport, so pickup is flexible.',
        VehicleCompatibility.volunteerRequired =>
          'Neither you nor this NGO has a vehicle. A volunteer is needed to transport this food.',
        VehicleCompatibility.unknown =>
          'Vehicle information is missing on one side, so transport cannot be confirmed yet.',
      };

  /// True only for a confirmed third-party dependency. `unknown` is NOT a
  /// volunteer requirement, so it must not return true here.
  bool get needsVolunteer => this == VehicleCompatibility.volunteerRequired;

  /// True only when at least one side is *known* to have a vehicle.
  /// `unknown` returns false on purpose: "we have not asked yet" must never be
  /// read as "transport is arranged".
  bool get hasUsableVehicle => switch (this) {
        VehicleCompatibility.providerTransport ||
        VehicleCompatibility.ngoTransport ||
        VehicleCompatibility.bothTransport =>
          true,
        VehicleCompatibility.unknown ||
        VehicleCompatibility.volunteerRequired =>
          false,
      };

  IconData get icon => switch (this) {
        VehicleCompatibility.providerTransport => Icons.directions_car_outlined,
        VehicleCompatibility.ngoTransport => Icons.local_shipping_outlined,
        VehicleCompatibility.bothTransport => Icons.alt_route_outlined,
        VehicleCompatibility.volunteerRequired =>
          Icons.volunteer_activism_outlined,
        VehicleCompatibility.unknown => Icons.help_outline,
      };
}

/// Which side of the logistics pair is being asked about vehicle availability.
///
/// Both roles answer the same underlying question, but the wording differs:
/// a provider transports food TO an NGO, an NGO collects food FROM a provider.
enum VehicleRole { provider, ngo }

/// Copy for the vehicle prompt, grouped so the wording stays consistent and
/// assertable in tests.
class VehicleAvailabilityCopy {
  const VehicleAvailabilityCopy._();

  static const String title = 'Vehicle Availability';

  static String question(VehicleRole role) => switch (role) {
        VehicleRole.provider =>
          'Do you currently have a vehicle available for transporting donated food?',
        VehicleRole.ngo =>
          'Do you currently have a vehicle available for food pickup?',
      };

  static String unansweredBody(VehicleRole role) => switch (role) {
        VehicleRole.provider =>
          'Let us know if you can transport food today. Matching uses this to work out whether the pickup can actually happen.',
        VehicleRole.ngo =>
          'Let providers know if you can collect food today. Matching uses this to work out whether the pickup can actually happen.',
      };

  static const String setBody =
      'Your answer helps work out who can transport each donation.';

  static const String yesLabel = 'Yes, I have a vehicle';
  static const String noLabel = "No, I don't";
  static const String clearLabel = 'Clear my answer';
}

/// Persistent, non-blocking prompt shown on the NGO dashboard until answered.
///
/// A card rather than a modal dialog, on purpose:
///   * the NGO can always open the dashboard and every tab,
///   * it cannot reappear as a duplicate dialog on rebuild,
///   * it stays visible until answered, then disappears,
///   * it never interferes with auth or logout.
class VehicleAvailabilityCard extends StatelessWidget {
  final VehicleAvailability value;
  final Future<void> Function(VehicleAvailability) onAnswer;
  final bool saving;
  final VehicleRole role;

  const VehicleAvailabilityCard({
    super.key,
    required this.value,
    required this.onAnswer,
    this.saving = false,
    this.role = VehicleRole.ngo,
  });

  @override
  Widget build(BuildContext context) {
    if (value != VehicleAvailability.unanswered) {
      return const SizedBox.shrink();
    }
    final c = AppColors.of(context);

    return Card(
      margin: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.local_shipping_outlined, color: c.bluePrimary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    VehicleAvailabilityCopy.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              VehicleAvailabilityCopy.question(role),
              style: TextStyle(fontSize: 14, color: c.textPrimary),
            ),
            const SizedBox(height: 4),
            Text(
              VehicleAvailabilityCopy.unansweredBody(role),
              style: TextStyle(fontSize: 12, color: c.textSecondary),
            ),
            const SizedBox(height: AppSpacing.lg),
            PrimaryButton(
              label: VehicleAvailabilityCopy.yesLabel,
              icon: Icons.check_circle_outline,
              onPressed:
                  saving ? null : () => onAnswer(VehicleAvailability.yes),
            ),
            const SizedBox(height: AppSpacing.sm),
            SecondaryButton(
              label: VehicleAvailabilityCopy.noLabel,
              icon: Icons.cancel_outlined,
              onPressed: saving ? null : () => onAnswer(VehicleAvailability.no),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reads `vehicle_available` out of a `GET /profile` response.
///
/// The role join (`providers(*)` / `ngos(*)`) comes back from Supabase as a LIST
/// of rows, so both the list form and a bare object are accepted. Anything
/// unexpected reads as null, which correctly means "not answered".
Object? vehicleFromProfile(Map<String, dynamic> profile) {
  final section = profile['profile'];
  if (section is List) {
    if (section.isEmpty || section.first is! Map) return null;
    return (section.first as Map)['vehicle_available'];
  }
  if (section is Map) return section['vehicle_available'];
  return null;
}

/// Settings row that always shows the current answer and lets the user change it
/// later, including clearing it back to unanswered.
class VehicleAvailabilityTile extends StatelessWidget {
  final VehicleAvailability value;
  final Future<void> Function(VehicleAvailability) onAnswer;
  final bool saving;
  final VehicleRole role;

  const VehicleAvailabilityTile({
    super.key,
    required this.value,
    required this.onAnswer,
    this.saving = false,
    this.role = VehicleRole.ngo,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final icon = switch (value) {
      VehicleAvailability.yes => Icons.local_shipping_outlined,
      VehicleAvailability.no => Icons.no_transfer_outlined,
      VehicleAvailability.unanswered => Icons.help_outline,
    };

    return ListTile(
      leading: Icon(icon, color: c.bluePrimary),
      title: const Text('Vehicle availability'),
      subtitle: Text(
        value == VehicleAvailability.unanswered
            ? VehicleAvailabilityCopy.question(role)
            : VehicleAvailabilityCopy.setBody,
        style: TextStyle(fontSize: 12, color: c.textSecondary),
      ),
      trailing: saving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Text(
              value.shortLabel,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
      onTap: saving
          ? null
          : () => showVehicleAvailabilitySheet(context, value, onAnswer, role),
    );
  }
}

/// Bottom sheet for changing an already-answered value.
Future<void> showVehicleAvailabilitySheet(
  BuildContext context,
  VehicleAvailability current,
  Future<void> Function(VehicleAvailability) onAnswer, [
  VehicleRole role = VehicleRole.ngo,
]) async {
  final c = AppColors.of(context);
  final choice = await showModalBottomSheet<VehicleAvailability>(
    context: context,
    backgroundColor: c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: AppSpacing.md),
          Text(
            VehicleAvailabilityCopy.title,
            style: TextStyle(fontWeight: FontWeight.w700, color: c.textPrimary),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Text(
              VehicleAvailabilityCopy.question(role),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: c.textSecondary),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _VehicleChoice(
            label: VehicleAvailabilityCopy.yesLabel,
            icon: Icons.check_circle_outline,
            selected: current == VehicleAvailability.yes,
            onTap: () =>
                Navigator.of(sheetContext).pop(VehicleAvailability.yes),
          ),
          _VehicleChoice(
            label: VehicleAvailabilityCopy.noLabel,
            icon: Icons.cancel_outlined,
            selected: current == VehicleAvailability.no,
            onTap: () => Navigator.of(sheetContext).pop(VehicleAvailability.no),
          ),
          if (current != VehicleAvailability.unanswered)
            _VehicleChoice(
              label: VehicleAvailabilityCopy.clearLabel,
              icon: Icons.help_outline,
              selected: false,
              onTap: () => Navigator.of(sheetContext)
                  .pop(VehicleAvailability.unanswered),
            ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    ),
  );

  if (choice != null && choice != current) {
    await onAnswer(choice);
  }
}

class _VehicleChoice extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _VehicleChoice({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: selected ? Icon(Icons.check, color: c.bluePrimary) : null,
      onTap: onTap,
    );
  }
}

/// Compact logistics line shown under a matched NGO.
///
/// Deliberately worded as "who can move the food" and never as a match-quality
/// claim, because this is a deterministic capability statement rather than
/// something the AI model produced. A volunteer requirement is visually louder
/// because it is the one state that needs a third party to act.
class LogisticsStatusBadge extends StatelessWidget {
  final VehicleCompatibility compatibility;
  final bool compact;

  const LogisticsStatusBadge({
    super.key,
    required this.compatibility,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final needsVolunteer = compatibility.needsVolunteer;
    final unknown = compatibility == VehicleCompatibility.unknown;
    final color = needsVolunteer
        ? c.warning
        : unknown
            ? c.textSecondary
            : c.green;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(compatibility.icon, size: compact ? 12 : 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              compatibility.label,
              style: TextStyle(
                fontSize: compact ? 11 : 11.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
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
  List<Map<String, dynamic>> _claimRows = [];
  bool _loading = true;
  String? _error;
  bool _claimsLoading = true;
  String? _claimsError;
  final List<Map<String, dynamic>> _ngoOffers = [];
  bool _offersLoading = true;
  bool _offersLoaded = false;
  String? _offersError;
  String? _respondingOfferId;
  Timer? _offersRefreshTimer;
  ProfileCompletion? _observedProfileCompletion;
  bool _profileCompletionInitialized = false;

  /// Tri-state vehicle answer. Starts unanswered so the prompt is shown until
  /// the real value has been loaded, rather than flashing a wrong value.
  VehicleAvailability _vehicle = VehicleAvailability.unanswered;
  bool _vehicleLoaded = false;
  bool _savingVehicle = false;

  @override
  void initState() {
    super.initState();
    _loadNearby();
    _loadClaims();
    _loadNgoOffers();
    _loadVehicle();
    _offersRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_offersLoading && _respondingOfferId == null) {
        _loadNgoOffers();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final completion = Provider.of<AppState>(context).profileCompletion;
    if (!identical(completion, _observedProfileCompletion)) {
      _observedProfileCompletion = completion;
      if (completion != null && _profileCompletionInitialized) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _offersLoaded && !_offersLoading) _loadNgoOffers();
        });
      }
      if (completion != null) _profileCompletionInitialized = true;
    }
  }

  @override
  void dispose() {
    _offersRefreshTimer?.cancel();
    super.dispose();
  }

  /// Reads the real stored answer. A failure leaves the state unanswered so the
  /// prompt stays visible instead of hiding behind a failed read.
  Future<void> _loadVehicle() async {
    try {
      final state = context.read<AppState>();
      final profile = await state.api.getProfile();
      state.updateProfileCompletionFromResponse(profile);
      final parsed =
          VehicleAvailability.fromBackend(_ngoVehicleFromProfile(profile));
      if (!mounted) return;
      setState(() {
        _vehicle = parsed;
        _vehicleLoaded = true;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _vehicle = VehicleAvailability.unanswered;
        _vehicleLoaded = true;
      });
    }
  }

  /// Digs `vehicle_available` out of a GET /profile response.
  ///
  /// `profile` is the role join (`ngos(*)`), which Supabase returns as a LIST
  /// of rows, so both the list form and a bare object are accepted. Anything
  /// unexpected reads as null, which correctly means "not answered" and keeps
  /// the prompt visible.
  static Object? _ngoVehicleFromProfile(Map<String, dynamic> profile) =>
      vehicleFromProfile(profile);

  /// Persists the answer, then updates local state only after the backend has
  /// confirmed it, so a rejected write never looks saved.
  Future<void> _answerVehicle(VehicleAvailability choice) async {
    if (_savingVehicle) return;
    setState(() => _savingVehicle = true);
    try {
      final result = await context
          .read<AppState>()
          .api
          .setNgoVehicleAvailability(choice.backendValue);
      if (!mounted) return;
      setState(() {
        _vehicle = VehicleAvailability.fromBackend(
            result['vehicle_available'] ?? choice.backendValue);
        _savingVehicle = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _savingVehicle = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(_apiErrorMessage(e, fallback: 'Could not save your answer.')),
      ));
    } catch (error, stackTrace) {
      debugPrint(
          'Could not save NGO vehicle availability: $error\n$stackTrace');
      if (!mounted) return;
      setState(() => _savingVehicle = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Could not save your answer. Check your connection and try again.'),
      ));
    }
  }

  Future<void> _loadNearby() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = context.read<AppState>();
      final raw = await state.api.getDonations();
      final list = [
        for (final item in raw)
          Donation.fromBackend(item is Map<String, dynamic> ? item : {},
              referenceLatitude: state.userLatitude,
              referenceLongitude: state.userLongitude),
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
        _error =
            _apiErrorMessage(e, fallback: 'Could not load nearby donations.');
        _loading = false;
      });
    }
  }

  Future<void> _loadClaims() async {
    if (mounted) {
      setState(() {
        _claimsLoading = true;
        _claimsError = null;
      });
    }
    try {
      final state = context.read<AppState>();
      final rows = await state.api.getClaims();
      final claims = <Donation>[];
      final claimRows = rows
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
      for (final value in rows) {
        if (value is! Map) continue;
        final claim = Map<String, dynamic>.from(value);
        final donationValue = claim['donation'];
        if (donationValue is! Map) continue;
        final donationJson = Map<String, dynamic>.from(donationValue)
          ..['claim_status'] = claim['status'];
        claims.add(Donation.fromBackend(
          donationJson,
          referenceLatitude: state.userLatitude,
          referenceLongitude: state.userLongitude,
          includePrivateContacts: true,
        ));
      }
      if (!mounted) return;
      setState(() {
        _claimed
          ..clear()
          ..addAll(claims);
        _claimRows = claimRows;
        _claimsLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _claimsError =
            _apiErrorMessage(e, fallback: 'Could not load your saved claims.');
        _claimsLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('Could not load NGO claims: $error\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _claimsError =
            'Could not load your saved claims. Check your connection and retry.';
        _claimsLoading = false;
      });
    }
  }

  Future<void> _loadNgoOffers() async {
    setState(() {
      _offersLoading = true;
      _offersError = null;
    });
    try {
      final rows = await context.read<AppState>().api.getNgoDonationOffers();
      final offers = [
        for (final row in rows)
          if (row is Map) Map<String, dynamic>.from(row),
      ];
      if (!mounted) return;
      setState(() {
        _ngoOffers
          ..clear()
          ..addAll(offers);
        _offersLoading = false;
        _offersLoaded = true;
      });
    } on ApiException catch (e) {
      debugPrint('NGO offers request failed http_status=${e.statusCode}');
      if (!mounted) return;
      setState(() {
        _offersError = _apiErrorMessage(e,
            fallback: 'Could not load your donation offers.');
        _offersLoading = false;
        _offersLoaded = true;
      });
    } catch (error, stackTrace) {
      debugPrint(
          'Could not load NGO donation offers error_type=${error.runtimeType}');
      if (!mounted) return;
      setState(() {
        _offersError =
            'Could not load your donation offers. Check your connection and retry.';
        _offersLoading = false;
        _offersLoaded = true;
      });
    }
  }

  Future<void> _respondToNgoOffer(String offerId, String decision) async {
    if (_respondingOfferId != null) return;
    if (decision == 'accepted') {
      final complete = await _requireCompleteProfile(
        context,
        role: UserRole.ngo,
        action: 'accepting a donation offer',
      );
      if (!mounted || !complete) return;
    }
    setState(() => _respondingOfferId = offerId);
    try {
      final result = await context
          .read<AppState>()
          .api
          .respondToDonationOffer(offerId, decision);
      if (!mounted) return;
      final changed = result['changed'] == true;
      final status = result['status']?.toString();
      if (!changed) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(status == 'timed_out'
              ? 'This offer expired before your response was received.'
              : 'This offer is no longer available. Its latest status is ${status ?? 'unknown'}.'),
        ));
      } else if (decision == 'accepted') {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Offer accepted. The donation is now in My Claims.'),
        ));
        await _loadClaims();
        await _loadNearby();
      } else if (status == 'timed_out') {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'The offer expired. The next eligible NGO may now be contacted.'),
        ));
      } else if (result['exhausted'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Offer declined. There are no remaining ranked NGOs.'),
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Offer declined. The next ranked NGO is being contacted.'),
        ));
      }
      await _loadNgoOffers();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_apiErrorMessage(e,
            fallback: 'Could not respond to this offer. Please retry.')),
      ));
    } catch (error, stackTrace) {
      debugPrint('Could not respond to NGO offer: $error\n$stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Could not respond to this offer. Check your connection and retry.'),
      ));
    } finally {
      if (mounted) setState(() => _respondingOfferId = null);
    }
  }

  Future<void> _claim(Donation d) async {
    final complete = await _requireCompleteProfile(
      context,
      role: UserRole.ngo,
      action: 'claiming a donation',
    );
    if (!mounted || !complete) return;
    await context.read<AppState>().api.createClaim({
      'donation_id': d.id,
      'requested_quantity': d.quantityKg,
      'notes': null,
    });
    if (!mounted) return;
    await _loadClaims();
    await _loadNearby();
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
      pageAt(
          0,
          _NgoHomeTab(
            nearby: _nearby,
            claimed: _claimed,
            onClaim: _claim,
            vehicle: _vehicle,
            vehicleLoaded: _vehicleLoaded,
            savingVehicle: _savingVehicle,
            onVehicleAnswer: _answerVehicle,
            offers: _ngoOffers,
            offersLoading: _offersLoading,
            offersError: _offersError,
            respondingOfferId: _respondingOfferId,
            onOffersRefresh: _loadNgoOffers,
            onOfferRespond: _respondToNgoOffer,
          )),
      pageAt(1, _NgoFindFoodTab(nearby: _nearby, onClaim: _claim)),
      pageAt(
          2,
          _NgoClaimsTab(
            claimed: _claimed,
            claimRows: _claimRows,
            loading: _claimsLoading,
            error: _claimsError,
            onRetry: _loadClaims,
          )),
      pageAt(3, _NgoImpactTab(claimed: _claimed)),
      ProfileTab(
        role: UserRole.ngo,
        name: state.currentOrgLabel,
        imageUrl: state.currentProfileImageUrl,
        vehicleAvailability: _vehicle,
        onVehicleAnswer: _answerVehicle,
        savingVehicle: _savingVehicle,
      ),
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

class _NgoOffersSection extends StatelessWidget {
  final List<Map<String, dynamic>> offers;
  final bool loading;
  final String? error;
  final String? respondingOfferId;
  final Future<void> Function() onRefresh;
  final Future<void> Function(String offerId, String decision) onRespond;

  const _NgoOffersSection({
    required this.offers,
    required this.loading,
    required this.error,
    required this.respondingOfferId,
    required this.onRefresh,
    required this.onRespond,
  });

  DateTime? _deadline(Map<String, dynamic> offer) {
    final raw = offer['offer_expires_at'];
    if (raw is! String) return null;
    return DateTime.tryParse(raw);
  }

  String _deadlineLabel(DateTime deadline) {
    final local = deadline.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = local.hour < 12 ? 'AM' : 'PM';
    return '${local.month}/${local.day} at $hour:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Donation Offers',
                      style:
                          TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                IconButton(
                  tooltip: 'Refresh offers',
                  onPressed: loading ? null : onRefresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(AppSpacing.md),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (error != null)
              Row(
                children: [
                  Expanded(
                    child:
                        Text(error!, style: TextStyle(color: c.textSecondary)),
                  ),
                  TextButton(onPressed: onRefresh, child: const Text('Retry')),
                ],
              )
            else if (offers.isEmpty)
              Text('No ranked donation offers are available yet.',
                  style: TextStyle(color: c.textSecondary))
            else
              for (final offer in offers.take(5)) ...[
                if (offer != offers.first) const Divider(height: 20),
                _NgoOfferTile(
                  offer: offer,
                  responding: respondingOfferId == offer['id'],
                  anotherOfferResponding: respondingOfferId != null &&
                      respondingOfferId != offer['id'],
                  deadline: _deadline(offer),
                  deadlineLabel: _deadline(offer) == null
                      ? null
                      : _deadlineLabel(_deadline(offer)!),
                  onRespond: onRespond,
                ),
              ],
          ],
        ),
      ),
    );
  }
}

class _NgoOfferTile extends StatelessWidget {
  final Map<String, dynamic> offer;
  final bool responding;
  final bool anotherOfferResponding;
  final DateTime? deadline;
  final String? deadlineLabel;
  final Future<void> Function(String offerId, String decision) onRespond;

  const _NgoOfferTile({
    required this.offer,
    required this.responding,
    required this.anotherOfferResponding,
    required this.deadline,
    required this.deadlineLabel,
    required this.onRespond,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final donationValue = offer['donation'];
    final donation = donationValue is Map
        ? Map<String, dynamic>.from(donationValue)
        : const <String, dynamic>{};
    final candidateValue = offer['ranked_candidate'];
    final candidate = candidateValue is Map
        ? Map<String, dynamic>.from(candidateValue)
        : const <String, dynamic>{};
    final foodName = donation['food_name']?.toString() ?? 'Food donation';
    final category = donation['food_category']?.toString();
    final quantity = donation['quantity'];
    final unit = donation['unit']?.toString();
    final address = donation['pickup_address']?.toString().trim();
    final status = offer['status']?.toString() ?? 'unknown';
    final score = candidate['final_score'];
    final scoreDetailsValue = candidate['score_details'];
    final scoreDetails = scoreDetailsValue is Map
        ? Map<String, dynamic>.from(scoreDetailsValue)
        : const <String, dynamic>{};
    final id = offer['id']?.toString() ?? '';
    final isPending = status == 'pending';
    final isBeforeDeadline =
        deadline != null && DateTime.now().isBefore(deadline!);
    final canRespond = isPending && isBeforeDeadline && id.isNotEmpty;
    final scoreLabel = matchScoreLabel(score is num ? score : null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(foodName,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        const SizedBox(height: 4),
        if (category != null && category.isNotEmpty)
          Text(category, style: TextStyle(color: c.textSecondary)),
        if (quantity is num)
          Text(
            '${quantity.toStringAsFixed(quantity % 1 == 0 ? 0 : 1)}'
            '${unit == null || unit.isEmpty ? '' : ' $unit'}',
            style: TextStyle(color: c.textSecondary),
          ),
        if (address != null && address.isNotEmpty)
          Text('Pickup: $address', style: TextStyle(color: c.textSecondary))
        else
          Text('Pickup address unavailable',
              style: TextStyle(color: c.textSecondary)),
        const SizedBox(height: 5),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            Text(scoreLabel,
                style: TextStyle(
                    color: c.bluePrimary, fontWeight: FontWeight.w700)),
            Text(
              matchingDistanceLabel(
                scoreDetails['distance_km'] is num
                    ? scoreDetails['distance_km'] as num
                    : null,
                scoreDetails['distance_source'],
              ),
              style: TextStyle(color: c.textSecondary),
            ),
            Text('Rank #${offer['candidate_rank'] ?? '—'}',
                style: TextStyle(color: c.textSecondary)),
            Text(
              isPending && deadline == null
                  ? 'Offer deadline unavailable'
                  : isPending && !isBeforeDeadline
                      ? 'Offer deadline passed'
                      : isPending
                          ? 'Respond by ${deadlineLabel ?? 'deadline unavailable'}'
                          : 'Offer ${status.replaceAll('_', ' ')}',
              style: TextStyle(color: c.textSecondary),
            ),
          ],
        ),
        if (canRespond) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: responding || anotherOfferResponding
                      ? null
                      : () => onRespond(id, 'declined'),
                  child: const Text('Decline'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: responding || anotherOfferResponding
                      ? null
                      : () => onRespond(id, 'accepted'),
                  child: responding
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Accept offer'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _NgoHomeTab extends StatelessWidget {
  final List<Donation> nearby;
  final List<Donation> claimed;
  final Future<void> Function(Donation) onClaim;
  final List<Map<String, dynamic>> offers;
  final bool offersLoading;
  final String? offersError;
  final String? respondingOfferId;
  final Future<void> Function() onOffersRefresh;
  final Future<void> Function(String offerId, String decision) onOfferRespond;
  final VehicleAvailability vehicle;
  final bool vehicleLoaded;
  final bool savingVehicle;
  final Future<void> Function(VehicleAvailability) onVehicleAnswer;
  const _NgoHomeTab(
      {required this.nearby,
      required this.claimed,
      required this.onClaim,
      required this.offers,
      required this.offersLoading,
      required this.offersError,
      required this.respondingOfferId,
      required this.onOffersRefresh,
      required this.onOfferRespond,
      required this.vehicle,
      required this.vehicleLoaded,
      required this.savingVehicle,
      required this.onVehicleAnswer});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final completion = state.profileCompletion;
    final available =
        nearby.where((d) => d.status == DonationStatus.available).toList();
    Map<String, dynamic>? activeOffer;
    for (final offer in offers) {
      if (offer['status'] == 'pending' &&
          offer['donation'] is Map &&
          offer['ranked_candidate'] is Map) {
        activeOffer = offer;
        break;
      }
    }
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
            imageUrl: state.currentProfileImageUrl,
            onNotificationTap: () => _openNotifications(context, UserRole.ngo),
            onProfileTap: () {},
          ),
        ),
        if (completion != null && shouldShowProfileProgress(completion))
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
              child: ProfileCompletionCard(
                role: UserRole.ngo,
                completion: completion,
              ),
            ),
          ),
        // Persistent until answered. Hidden only while the real value is still
        // loading, so the prompt never flashes for an NGO that already
        // answered. It never gates the dashboard: every tab stays reachable.
        if (vehicleLoaded)
          SliverToBoxAdapter(
            child: VehicleAvailabilityCard(
              value: vehicle,
              saving: savingVehicle,
              onAnswer: onVehicleAnswer,
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
            child: _NgoOffersSection(
              offers: offers,
              loading: offersLoading,
              error: offersError,
              respondingOfferId: respondingOfferId,
              onRefresh: onOffersRefresh,
              onRespond: onOfferRespond,
            ),
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
            ]),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader(title: 'Food Available Near You'),
                const SizedBox(height: 10),
                SahaayGoogleMap(
                  points: ngoHomeMapPoints(
                    available,
                    ngoPoint: state.ngoMapPoint,
                  ),
                  height: 200,
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              MatchScoreCard(offer: activeOffer),
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
                                  await _claimDonation(context, d);
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

  /// Confirms with the user and reports success only after the backend creates
  /// the pending claim. A pending request is not a claimed donation.
  Future<void> _claimDonation(BuildContext context, Donation d) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Claim'),
        content: Text('Claim "${d.foodName}"'
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
    if (confirmed != true || !context.mounted) return;
    try {
      await onClaim(d);
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
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text(
        'Claim request submitted. The donation will be marked claimed after acceptance.',
      ),
    ));
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
  final List<Map<String, dynamic>> claimRows;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  const _NgoClaimsTab({
    required this.claimed,
    this.claimRows = const [],
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text('My Claims'), actions: const [ThemeToggleButton()]),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(error!),
                      const SizedBox(height: 12),
                      SecondaryButton(
                          label: 'RETRY',
                          icon: Icons.refresh,
                          onPressed: onRetry),
                    ],
                  ),
                )
              : claimed.isEmpty
                  ? const Center(
                      child: EmptyState(
                          icon: Icons.assignment_outlined,
                          message:
                              'No active claims yet. Claim a donation from Find Food.'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      itemCount: claimed.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final donation = claimed[i];
                        final claim = claimRows
                            .where((row) =>
                                row['donation_id']?.toString() == donation.id)
                            .firstOrNull;
                        return _ClaimSummaryCard(
                          donation: donation,
                          claim: claim,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ClaimedDonationDashboard(
                                donation: donation,
                              ),
                            ),
                          ),
                        );
                      },
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
  final Map<String, dynamic>? claim;
  final VoidCallback onTap;
  const _ClaimSummaryCard({
    required this.donation,
    required this.onTap,
    this.claim,
  });

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
              ReadableAddressText(
                address: donation.providerAddress,
                latitude: donation.latitude,
                longitude: donation.longitude,
                style: TextStyle(color: c.textSecondary, fontSize: 12),
              ),
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
              if (claim?['id'] != null &&
                  claim?['status'] != 'completed' &&
                  claim?['status'] != 'cancelled' &&
                  claim?['status'] != 'rejected') ...[
                const SizedBox(height: 8),
                TransportCoordinationCard(
                  claimId: claim!['id'].toString(),
                  role: 'ngo',
                  initialState: claim?['transport_coordination'] is Map
                      ? Map<String, dynamic>.from(
                          claim!['transport_coordination'] as Map)
                      : null,
                  delivery: claim?['delivery'] is Map
                      ? Map<String, dynamic>.from(claim!['delivery'] as Map)
                      : null,
                ),
              ],
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
          ImpactCardGrid(cards: [
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
            const ImpactCard(emoji: '⭐', value: '—', label: 'Provider Rating'),
          ]),
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
            SahaayGoogleMap(
              height: 140,
              latitude: donation.latitude,
              longitude: donation.longitude,
              markerTitle: donation.foodName,
              markerSnippet:
                  readableAddressOrUnavailable(donation.providerAddress),
              onMarkerInfoWindowTap: _openGoogleMaps,
            ),
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
                  _detailRow(
                    context,
                    Icons.near_me_outlined,
                    'Distance',
                    straightLineDistanceLabel(donation.distanceKm) ??
                        'Distance unavailable',
                  ),
                  if (donation.expiryLabel.isNotEmpty)
                    _detailRow(context, Icons.schedule_outlined, 'Deadline',
                        donation.expiryLabel),
                  _detailRow(context, Icons.eco_outlined, 'Freshness',
                      donation.freshnessLabel),
                  _readableAddressRow(context, donation),
                ]),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            MatchScoreCard(offer: null),
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
                              fallback:
                                  'Could not claim this donation. Please try again.'))),
                    );
                    return;
                  }
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text(
                      'Claim request submitted. The donation will be marked claimed after acceptance.',
                    ),
                  ));
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

  Widget _readableAddressRow(BuildContext context, Donation donation) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(Icons.location_on_outlined, size: 18, color: c.textSecondary),
        const SizedBox(width: 10),
        Expanded(
            child: Text('Pickup Address',
                style: TextStyle(color: c.textSecondary))),
        Expanded(
          flex: 2,
          child: ReadableAddressText(
            address: donation.providerAddress,
            latitude: donation.latitude,
            longitude: donation.longitude,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
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
  // The handover lifecycle is owned by the backend now: this screen loads the
  // real state, mints a code on demand, and uploads the proof photo. The code's
  // plaintext only exists right after generation — the server keeps a hash, so
  // it can never be read back.
  final _otpInputController = TextEditingController();
  String? _otpError;

  bool _loading = true;
  String? _loadError;
  bool _handoverVerified = false;
  String? _verifiedAt;
  String? _photoUrl; // server-persisted proof photo
  bool _hasActiveCode = false;
  bool _receiptReady = false;
  Map<String, dynamic>? _claim;

  String? _code; // plaintext, only immediately after a fresh generation
  String? _codeExpiresAt;
  bool _generatingCode = false;

  bool get _activeCodeNotExpired {
    if (!_hasActiveCode) return false;
    final expiry = DateTime.tryParse(_codeExpiresAt ?? '');
    return expiry == null || expiry.isAfter(DateTime.now());
  }

  bool get _activeCodeUnavailable => _code == null && _activeCodeNotExpired;

  File? _photo; // locally picked, pre-upload
  bool _uploadingPhoto = false;
  bool _verifying = false;
  bool _downloadingReceipt = false;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  @override
  void dispose() {
    _otpInputController.dispose();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// The backend returns precise 400/410/429/409 messages (wrong code, expired,
  /// locked). Surface them verbatim so the user knows what to do next.
  String _handoverError(ApiException e, String fallback) =>
      e.message.isNotEmpty ? e.message : fallback;

  Future<void> _loadState() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final state = await context
          .read<AppState>()
          .api
          .getHandoverState(widget.donation.id);
      if (!mounted) return;
      setState(() {
        _handoverVerified = state['handover_verified'] == true;
        _verifiedAt = state['handover_verified_at']?.toString();
        _photoUrl = state['handover_photo_url']?.toString();
        _hasActiveCode = state['has_active_code'] == true;
        _codeExpiresAt = state['handover_code_expires_at']?.toString();
        _receiptReady = state['receipt_ready'] == true;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = _handoverError(
            e, 'Could not load the handover status. Please try again.');
        _loading = false;
      });
    }
    try {
      final claims = await context.read<AppState>().api.getClaims();
      final match = claims
          .whereType<Map>()
          .map(
            (row) => Map<String, dynamic>.from(row),
          )
          .where((row) => row['donation_id']?.toString() == widget.donation.id);
      if (mounted) {
        setState(() => _claim = match.isEmpty ? null : match.first);
      }
    } on ApiException catch (error) {
      debugPrint('Could not refresh NGO claim details: ${error.message}');
    }
  }

  Future<void> _generateCode() async {
    setState(() => _generatingCode = true);
    try {
      final result = await context
          .read<AppState>()
          .api
          .generateHandoverCode(widget.donation.id);
      if (!mounted) return;
      setState(() {
        _code = result['handover_code']?.toString();
        _codeExpiresAt = result['expires_at']?.toString();
        _hasActiveCode = _code != null && _code!.isNotEmpty;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      _snack(_handoverError(
          e, 'Could not generate a handover code. Please try again.'));
    } finally {
      if (mounted) setState(() => _generatingCode = false);
    }
  }

  Future<void> _pickAndUploadPhoto() async {
    File picked;
    try {
      final result = await ImagePicker()
          .pickImage(source: ImageSource.gallery, imageQuality: 80);
      if (result == null) return;
      picked = File(result.path);
      setState(() => _photo = picked);
    } catch (e) {
      if (!mounted) return;
      _snack('Could not open the photo library.');
      return;
    }
    if (!mounted) return;
    setState(() => _uploadingPhoto = true);
    try {
      final url = await context
          .read<AppState>()
          .api
          .uploadHandoverPhoto(widget.donation.id, picked);
      if (!mounted) return;
      setState(() => _photoUrl = url);
      _snack('Handover photo saved.');
    } on ApiException catch (e) {
      if (!mounted) return;
      _snack(_handoverError(
          e, 'Handover photo could not be saved. Please try again.'));
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  Future<void> _confirmHandover() async {
    final entered = _otpInputController.text.trim();
    if (entered.isEmpty) {
      setState(() => _otpError = 'Enter the handover code to confirm.');
      return;
    }
    setState(() {
      _verifying = true;
      _otpError = null;
    });
    try {
      final result = await context
          .read<AppState>()
          .api
          .verifyHandoverCode(widget.donation.id, entered);
      if (!mounted) return;
      setState(() {
        _handoverVerified = result['handover_verified'] == true ||
            result['already_verified'] == true;
        _verifiedAt = result['handover_verified_at']?.toString() ?? _verifiedAt;
        _photoUrl = result['handover_photo_url']?.toString() ?? _photoUrl;
        _receiptReady = _receiptReady || result['acknowledgment_ready'] == true;
        _hasActiveCode = false;
        _code = null;
        _codeExpiresAt = null;
        _otpInputController.clear();
      });
      _snack('Handover verified successfully.');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _otpError = _handoverError(
          e, 'That handover code is not correct. Please try again.'));
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  /// Downloads the exact acknowledgment receipt the provider receives. The
  /// backend authorizes the NGO by its real claim on this donation, so both
  /// parties end up with the same persisted document.
  Future<void> _downloadReceipt() async {
    setState(() => _downloadingReceipt = true);
    try {
      final bytes = await context
          .read<AppState>()
          .api
          .downloadAcknowledgment(widget.donation.id);
      if (!mounted) return;
      final saved = await saveAcknowledgmentPdf(widget.donation.id, bytes);
      if (!mounted) return;
      _snack('Receipt saved to ${saved.location}');
    } on ApiException catch (e) {
      if (!mounted) return;
      _snack(_handoverError(e, 'The receipt is not available yet.'));
    } finally {
      if (mounted) setState(() => _downloadingReceipt = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.donation;
    final c = AppColors.of(context);
    final donationValue = _claim?['donation'];
    final detailsDonation = donationValue is Map
        ? Donation.fromBackend(
            Map<String, dynamic>.from(donationValue)
              ..['claim_status'] = _claim?['status'],
            includePrivateContacts: true,
          )
        : d;
    final providerValue = _claim?['provider'];
    final provider = providerValue is Map
        ? Map<String, dynamic>.from(providerValue)
        : const <String, dynamic>{};
    final ngoValue = _claim?['ngo'];
    final ngo = ngoValue is Map
        ? Map<String, dynamic>.from(ngoValue)
        : const <String, dynamic>{};
    final deliveryValue = _claim?['delivery'];
    final delivery = deliveryValue is Map
        ? Map<String, dynamic>.from(deliveryValue)
        : const <String, dynamic>{};
    final coordinationValue = _claim?['transport_coordination'];
    final coordination = coordinationValue is Map
        ? Map<String, dynamic>.from(coordinationValue)
        : const <String, dynamic>{};

    return Scaffold(
      appBar: AppBar(title: const Text('Claimed Donation')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClaimedDonationFacts(
              donation: detailsDonation,
              provider: provider,
              ngo: ngo,
              delivery: delivery,
              transportCoordination: coordination,
            ),
            const SizedBox(height: AppSpacing.lg),
            if (_claim?['id'] != null)
              TransportCoordinationCard(
                claimId: _claim!['id'].toString(),
                role: 'ngo',
                initialState: coordination,
                delivery: delivery,
              ),
            const SizedBox(height: AppSpacing.lg),
            const SizedBox(height: AppSpacing.lg),
            const SectionHeader(title: 'Handover Verification'),
            const SizedBox(height: 10),
            _buildHandoverCard(context, c),
            const SizedBox(height: AppSpacing.lg),
            const SectionHeader(title: 'Handover Photo'),
            const SizedBox(height: 10),
            _buildPhotoCard(context, c),
          ],
        ),
      ),
    );
  }

  String? _verifiedLabel() {
    final raw = _verifiedAt;
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    return parsed == null ? null : _timeLabel(parsed.toLocal());
  }

  Widget _buildHandoverCard(BuildContext context, AppColors c) {
    if (_loading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Row(children: [
            SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Expanded(child: Text('Loading handover status…')),
          ]),
        ),
      );
    }
    if (_loadError != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.error_outline, color: c.danger),
              const SizedBox(width: 8),
              Expanded(child: Text(_loadError!)),
            ]),
            const SizedBox(height: 12),
            SecondaryButton(
                label: 'RETRY', icon: Icons.refresh, onPressed: _loadState),
          ]),
        ),
      );
    }
    if (_handoverVerified) {
      final verified = _verifiedLabel();
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.verified, color: c.green),
              const SizedBox(width: 8),
              const Expanded(child: Text('Handover verified successfully.')),
            ]),
            if (verified != null) ...[
              const SizedBox(height: 6),
              Text('Verified at $verified',
                  style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
            ],
            const SizedBox(height: 12),
            if (_receiptReady)
              SecondaryButton(
                label: 'DOWNLOAD RECEIPT',
                icon: Icons.download_outlined,
                onPressed: _downloadingReceipt ? null : _downloadReceipt,
                isLoading: _downloadingReceipt,
              )
            else
              Text('Your completion receipt is being prepared.',
                  style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
          ]),
        ),
      );
    }

    final expiresLabel = _codeExpiresAt == null
        ? null
        : _timeLabel(
            DateTime.tryParse(_codeExpiresAt!)?.toLocal() ?? DateTime.now());
    final activeCodeExpiry = DateTime.tryParse(_codeExpiresAt ?? '')?.toLocal();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'Generate a one-time code and share it with the provider at '
            'pickup. The handover is completed by '
            'entering the code below.',
            style: TextStyle(fontSize: 12.5, color: c.textSecondary),
          ),
          const SizedBox(height: 12),
          if (_code != null && _activeCodeNotExpired) ...[
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(12)),
                child: Text(_code!,
                    style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 8)),
              ),
            ),
            if (expiresLabel != null) ...[
              const SizedBox(height: 6),
              Center(
                child: Text('Expires at $expiresLabel',
                    style: TextStyle(fontSize: 12, color: c.textSecondary)),
              ),
            ],
            const SizedBox(height: 12),
          ] else if (_activeCodeUnavailable) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: c.surfaceAlt, borderRadius: BorderRadius.circular(12)),
              child: Text(
                activeCodeExpiry == null
                    ? 'A code is active but cannot be recovered after leaving '
                        'this screen. Refresh status and wait for it to expire '
                        'before generating another.'
                    : 'A code is active until '
                        '${_timeLabel(activeCodeExpiry)}. It cannot be '
                        'recovered after leaving this screen; wait for expiry '
                        'before generating another.',
                style: TextStyle(fontSize: 12, color: c.textSecondary),
              ),
            ),
            TextButton.icon(
              onPressed: _loading ? null : _loadState,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh code status'),
            ),
            const SizedBox(height: 12),
          ],
          SecondaryButton(
            label: _activeCodeUnavailable
                ? 'WAIT FOR CODE EXPIRY'
                : _code != null && _activeCodeNotExpired
                    ? 'CODE ACTIVE'
                    : _hasActiveCode
                        ? 'GENERATE NEW CODE'
                        : 'GENERATE HANDOVER CODE',
            icon: Icons.password_outlined,
            onPressed:
                _generatingCode || _activeCodeNotExpired ? null : _generateCode,
            isLoading: _generatingCode,
          ),
          const SizedBox(height: 14),
          AppInputField(
            label: 'Enter handover code',
            controller: _otpInputController,
            keyboardType: TextInputType.number,
            prefixIcon: Icons.lock_outline,
            helperText: _otpError,
          ),
          const SizedBox(height: 12),
          PrimaryButton(
              label: 'VERIFY & CONFIRM HANDOVER',
              onPressed: _verifying ? null : _confirmHandover),
        ]),
      ),
    );
  }

  Widget _buildPhotoCard(BuildContext context, AppColors c) {
    final hasServer = _photoUrl != null && _photoUrl!.isNotEmpty;
    final Widget image;
    if (hasServer) {
      image = Image.network(
        _photoUrl!,
        height: 180,
        width: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _photoPlaceholder(c),
      );
    } else if (_photo != null) {
      image = Image.file(_photo!,
          height: 180, width: double.infinity, fit: BoxFit.cover);
    } else {
      image = _photoPlaceholder(c);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: image,
      ),
      const SizedBox(height: 10),
      SecondaryButton(
        label: hasServer
            ? 'REPLACE PHOTO'
            : (_photo == null ? 'ADD HANDOVER PHOTO' : 'UPLOAD PHOTO'),
        icon: Icons.add_a_photo_outlined,
        onPressed: _uploadingPhoto ? null : _pickAndUploadPhoto,
        isLoading: _uploadingPhoto,
      ),
    ]);
  }

  Widget _photoPlaceholder(AppColors c) => Container(
        height: 120,
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.border),
        ),
        child: Center(
            child: Icon(Icons.photo_camera_outlined,
                size: 32, color: c.textSecondary.withOpacity(0.6))),
      );
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
  // Real open transport tasks from the backend, not invented data. A task only
  // exists here when the provider and the claiming NGO both reported no vehicle
  // and a real volunteer has not accepted it yet.
  final List<VolunteerTransportTask> _transportTasks = [];
  final List<DeliveryOpportunity> _myDeliveries = [];
  bool _loading = true;
  String? _error;
  final Set<String> _accepting = {};

  @override
  void initState() {
    super.initState();
    _loadProfileCompletion();
    _loadDeliveries();
  }

  Future<void> _loadProfileCompletion() async {
    try {
      final state = context.read<AppState>();
      final profile = await state.api.getProfile();
      state.updateProfileCompletionFromResponse(profile);
    } on ApiException {
      // The volunteer dashboard remains usable when the optional profile
      // progress read is unavailable.
    }
  }

  Future<void> _loadDeliveries() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final state = context.read<AppState>();
    final api = state.api;
    // The two lists are independent, so one failing must not hide the other.
    final mine = await _loadPart(api.getDeliveries);
    final tasks = await _loadPart(api.getVolunteerTransportTasks);
    if (!mounted) return;
    if (mine == null && tasks == null) {
      setState(() {
        _error = 'Could not load your deliveries. Please try again.';
        _loading = false;
      });
      return;
    }
    setState(() {
      if (mine != null) {
        _myDeliveries
          ..clear()
          ..addAll([
            for (final item in mine)
              DeliveryOpportunity.fromBackend(
                  item is Map<String, dynamic> ? item : {},
                  viewerLatitude: state.userLatitude,
                  viewerLongitude: state.userLongitude),
          ]);
      }
      if (tasks != null) {
        _transportTasks
          ..clear()
          ..addAll([
            for (final item in tasks)
              VolunteerTransportTask.fromBackend(
                  item is Map<String, dynamic> ? item : {}),
          ]);
      }
      _loading = false;
    });
  }

  /// Runs one read, returning null when it failed instead of throwing, so a
  /// single failing endpoint cannot blank the whole dashboard.
  Future<List<dynamic>?> _loadPart(
      Future<List<dynamic>> Function() call) async {
    try {
      return await call();
    } on ApiException {
      return null;
    }
  }

  /// A real volunteer accepts the task. The backend takes the volunteer identity
  /// from the Firebase token, and rejects the call if somebody else already
  /// accepted it, so this is a genuine hand-off rather than a local fiction.
  Future<void> _acceptTask(VolunteerTransportTask task) async {
    if (_accepting.contains(task.id) || task.id.isEmpty) return;
    setState(() => _accepting.add(task.id));
    try {
      await context.read<AppState>().api.acceptVolunteerTransportTask(task.id);
      if (!mounted) return;
      setState(() {
        _transportTasks.removeWhere((t) => t.id == task.id);
        _accepting.remove(task.id);
      });
      if (!mounted) return;
      // Re-read so the volunteer's own delivery list reflects the new work.
      await _loadDeliveries();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _accepting.remove(task.id));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            _apiErrorMessage(e, fallback: 'Could not accept this delivery.')),
      ));
    }
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
              transportTasks: _transportTasks,
              accepting: _accepting,
              myDeliveries: _myDeliveries,
              onAcceptTask: _acceptTask,
              onRefresh: _loadDeliveries)),
      pageAt(1, _VolunteerDeliveriesTab(myDeliveries: _myDeliveries)),
      pageAt(2, _VolunteerImpactTab(myDeliveries: _myDeliveries)),
      NotificationsScreen(role: UserRole.volunteer, embedded: true),
      ProfileTab(
          role: UserRole.volunteer,
          name: state.currentName,
          imageUrl: state.currentProfileImageUrl),
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
  final List<VolunteerTransportTask> transportTasks;
  final Set<String> accepting;
  final List<DeliveryOpportunity> myDeliveries;
  final Future<void> Function(VolunteerTransportTask) onAcceptTask;
  final Future<void> Function() onRefresh;
  const _VolunteerHomeTab(
      {required this.transportTasks,
      required this.accepting,
      required this.myDeliveries,
      required this.onAcceptTask,
      required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final completed = myDeliveries
        .where((o) => o.status == DeliveryStatus.delivered)
        .toList();
    final distanceCovered =
        completed.fold<double>(0, (sum, o) => sum + (o.distanceKm ?? 0));
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: DashboardHeader(
            greeting: 'Hi, ${state.currentName} 👋',
            subtitle: 'Ready to make an impact today?',
            roleLabel: 'VOLUNTEER (OPTIONAL ROLE)',
            imageUrl: state.currentProfileImageUrl,
            onNotificationTap: () =>
                _openNotifications(context, UserRole.volunteer),
            onProfileTap: () {},
          ),
        ),
        if (state.profileCompletion case final completion?
            when shouldShowProfileProgress(completion))
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
              child: ProfileCompletionCard(
                role: UserRole.volunteer,
                completion: completion,
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Row(children: [
                Expanded(
                    child: StatCard(
                        label: 'Transport Needed',
                        value: '${transportTasks.length}',
                        icon: Icons.volunteer_activism_outlined,
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
              const SectionHeader(title: 'Volunteer Transport Required'),
              const SizedBox(height: 4),
              Builder(builder: (context) {
                final c = AppColors.of(context);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'Both organizations declined to transport these donations, so a volunteer is needed.',
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                  ),
                );
              }),
              if (transportTasks.isEmpty)
                const EmptyState(
                    icon: Icons.volunteer_activism_outlined,
                    message:
                        'No donations currently need volunteer transport. Thank you for checking!')
              else
                ...transportTasks.map((task) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _TransportTaskCard(
                        task: task,
                        accepting: accepting.contains(task.id),
                        onAccept: () => onAcceptTask(task),
                      ),
                    )),
            ]),
          ),
        ),
      ],
    );
  }
}

/// One open volunteer transport task, showing only facts the backend actually
/// has. A missing quantity or address is labelled as unknown rather than filled
/// in, because inventing pickup details would send a volunteer to the wrong place.
class _TransportTaskCard extends StatelessWidget {
  final VolunteerTransportTask task;
  final bool accepting;
  final VoidCallback onAccept;

  const _TransportTaskCard(
      {required this.task, required this.accepting, required this.onAccept});

  Future<void> _openLocation(
    BuildContext context,
    double? latitude,
    double? longitude,
    String? address,
  ) async {
    final uri = googleMapsUriForLocation(
      latitude: latitude,
      longitude: longitude,
      address: address,
    );
    if (uri == null) return;
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the map location.')),
      );
    }
  }

  Widget _contact(BuildContext context, String label, String? phone) {
    final uri = dialerUriForPhone(phone);
    return Row(
      children: [
        Expanded(child: Text(label)),
        if (uri == null)
          const Text('Not provided')
        else
          TextButton.icon(
            onPressed: () async {
              final opened =
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
              if (!opened && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Could not open the dialer.')),
                );
              }
            },
            icon: const Icon(Icons.phone_outlined, size: 16),
            label: Text(phone!.trim()),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final quantity = task.quantityLabel;
    final deadline = task.pickupDeadline;
    final points = <SahaayMapPoint>[
      if (task.pickupLatitude != null && task.pickupLongitude != null)
        SahaayMapPoint(
          latitude: task.pickupLatitude!,
          longitude: task.pickupLongitude!,
          title: 'Pickup',
          snippet: task.pickupAddress,
        ),
      if (task.dropoffLatitude != null && task.dropoffLongitude != null)
        SahaayMapPoint(
          latitude: task.dropoffLatitude!,
          longitude: task.dropoffLongitude!,
          title: 'Drop-off',
          snippet: task.deliveryAddress,
          markerHue: SahaayMapPoint.destinationHue,
        ),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (task.foodImageUrl?.isNotEmpty == true)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  task.foodImageUrl!,
                  width: double.infinity,
                  height: 170,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    height: 72,
                    child: Center(child: Text('Donation photo unavailable')),
                  ),
                ),
              ),
            Row(children: [
              Expanded(
                child: Text(
                  task.foodName ?? 'Food donation',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const LogisticsStatusBadge(
                compatibility: VehicleCompatibility.volunteerRequired,
                compact: true,
              ),
            ]),
            const SizedBox(height: 10),
            _TransportFact(
              icon: Icons.scale_outlined,
              label: quantity ?? 'Quantity not recorded',
            ),
            _TransportFact(
              icon: Icons.category_outlined,
              label: task.category?.trim().isNotEmpty == true
                  ? task.category!
                  : 'Food category not recorded',
            ),
            if (task.description?.trim().isNotEmpty == true)
              _TransportFact(
                icon: Icons.notes_outlined,
                label: task.description!,
              ),
            _TransportFact(
              icon: Icons.eco_outlined,
              label:
                  'Freshness: ${task.freshness?.trim().isNotEmpty == true ? task.freshness : 'Not available'}',
            ),
            _TransportFact(
              icon: Icons.info_outline,
              label:
                  'Food type: ${task.vegType?.trim().isNotEmpty == true ? task.vegType : 'Not provided'}',
            ),
            if (task.preparedAt != null)
              _TransportFact(
                icon: Icons.restaurant_outlined,
                label: 'Prepared ${_dateTimeLabel(task.preparedAt!)}',
              ),
            if (task.expiresAt != null)
              _TransportFact(
                icon: Icons.event_outlined,
                label: 'Expires ${_dateTimeLabel(task.expiresAt!)}',
              ),
            if (task.createdAt != null)
              _TransportFact(
                icon: Icons.schedule_outlined,
                label: 'Donation created ${_dateTimeLabel(task.createdAt!)}',
              ),
            _TransportFact(
              icon: Icons.assignment_outlined,
              label:
                  'Donation status: ${task.donationStatus ?? 'Not available'} • Claim status: ${task.claimStatus ?? 'Not available'}',
            ),
            const SizedBox(height: 6),
            _TransportFact(
              icon: Icons.storefront_outlined,
              label: task.providerName ?? 'Provider not recorded',
            ),
            const SizedBox(height: 6),
            _TransportFact(
              icon: Icons.my_location_outlined,
              label:
                  'Pickup: ${readableAddressOrUnavailable(task.providerAddress ?? task.pickupAddress)}',
            ),
            const SizedBox(height: 6),
            _TransportFact(
              icon: Icons.volunteer_activism_outlined,
              label: task.ngoName == null
                  ? 'Destination NGO not recorded'
                  : 'Deliver to: ${task.ngoName}',
            ),
            _TransportFact(
              icon: Icons.location_on_outlined,
              label:
                  'Drop-off: ${readableAddressOrUnavailable(task.ngoAddress ?? task.deliveryAddress)}',
            ),
            const SizedBox(height: 6),
            _TransportFact(
              icon: Icons.schedule_outlined,
              label: deadline == null
                  ? 'Pickup deadline not recorded'
                  : 'Pickup by ${_timeLabel(deadline)}',
            ),
            if (points.isNotEmpty) ...[
              const SizedBox(height: 10),
              SahaayGoogleMap(
                height: 180,
                points: points,
                onMarkerInfoWindowTap: _openGoogleMaps,
              ),
            ],
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => _openLocation(
                    context,
                    task.pickupLatitude,
                    task.pickupLongitude,
                    task.providerAddress ?? task.pickupAddress,
                  ),
                  icon: const Icon(Icons.my_location_outlined),
                  label: const Text('Pickup map'),
                ),
                TextButton.icon(
                  onPressed: () => _openLocation(
                    context,
                    task.dropoffLatitude,
                    task.dropoffLongitude,
                    task.ngoAddress ?? task.deliveryAddress,
                  ),
                  icon: const Icon(Icons.location_on_outlined),
                  label: const Text('Destination map'),
                ),
              ],
            ),
            _contact(context, 'Provider contact', task.providerPhone),
            _contact(context, 'NGO contact', task.ngoPhone),
            const SizedBox(height: AppSpacing.md),
            PrimaryButton(
              label: accepting ? 'Accepting…' : 'Accept this delivery',
              icon: Icons.volunteer_activism_outlined,
              onPressed: accepting ? null : onAccept,
            ),
          ],
        ),
      ),
    );
  }
}

class _TransportFact extends StatelessWidget {
  final IconData icon;
  final String label;

  const _TransportFact({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: c.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: c.textSecondary),
          ),
        ),
      ],
    );
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
            content: Text(_apiErrorMessage(e,
                fallback:
                    'Could not update the delivery status. Please try again.'))),
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
            if (o.donation != null)
              ClaimedDonationFacts(
                donation: o.donation!,
                provider: o.provider,
                ngo: o.ngo,
                delivery: <String, dynamic>{'volunteer': o.volunteer},
                transportCoordination: o.coordination,
              )
            else ...[
              Text('${o.quantityKg.toStringAsFixed(0)} kg ${o.foodName}',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              StatusChip(
                  label: deliveryStatusLabel(o.status), color: c.bluePrimary),
              const SizedBox(height: AppSpacing.lg),
              SahaayGoogleMap(
                height: 150,
                latitude: o.latitude,
                longitude: o.longitude,
                markerTitle: o.foodName,
                markerSnippet: o.providerName,
                onMarkerInfoWindowTap: _openGoogleMaps,
              ),
              const SizedBox(height: AppSpacing.lg),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(children: [
                    _row(context, Icons.storefront_outlined, 'Provider',
                        o.providerName),
                    _row(context, Icons.apartment_outlined, 'NGO Destination',
                        o.ngoName),
                    _row(
                      context,
                      Icons.near_me_outlined,
                      'Distance',
                      straightLineDistanceLabel(o.distanceKm) ??
                          'Distance unavailable',
                    ),
                    _row(context, Icons.schedule_outlined, 'Deadline',
                        o.deadline),
                  ]),
                ),
              ),
            ],
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
        completed.fold<double>(0, (sum, o) => sum + (o.distanceKm ?? 0));
    final kgDelivered =
        completed.fold<double>(0, (sum, o) => sum + o.quantityKg);

    return Scaffold(
      appBar: AppBar(
          title: const Text('Impact & Rewards'),
          actions: const [ThemeToggleButton()]),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          ImpactCardGrid(cards: [
            ImpactCard(
                emoji: '🚚', value: '${completed.length}', label: 'Deliveries'),
            ImpactCard(
                emoji: '📦',
                value: '${kgDelivered.toStringAsFixed(0)} kg',
                label: 'Food Delivered'),
            ImpactCard(
                emoji: '📍',
                value: '${distanceCovered.toStringAsFixed(0)} km',
                label: 'Distance Covered'),
            const ImpactCard(emoji: '⭐', value: '—', label: 'Reliability'),
          ]),
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
  return value
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
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
        _summary = AdminSummary.fromBackend(results[0] is Map<String, dynamic>
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
        _error = _apiErrorMessage(e,
            fallback: 'Could not load the admin dashboard.');
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
    final state = context.watch<AppState>();
    return Scaffold(
      body: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverToBoxAdapter(
            child: DashboardHeader(
              greeting: 'Admin Console',
              subtitle: 'Platform-wide activity & analytics',
              roleLabel: 'ADMIN',
              imageUrl: state.currentProfileImageUrl,
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
                  color: c.surfaceAlt, borderRadius: BorderRadius.circular(12)),
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
                      value: '${_adminKgLabel(a.totalFoodRedistributedKg)} kg',
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
        Expanded(child: Text(label, style: TextStyle(color: c.textSecondary))),
        Text(value,
            style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 16,
                color: c.textPrimary)),
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
        return api.getAdminUsers(
            role: _roleFilter, page: page, pageSize: _pageSize);
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
        _error = _apiErrorMessage(e,
            fallback: 'Could not load ${widget.resource.label}.');
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
          return _AdminResourceTile(resource: widget.resource, item: _items[i]);
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
        return '$city • Capacity $capacity people/day';
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
        return (
          verified ? 'Verified' : 'Unverified',
          verified ? AppColors.of(context).green : AppColors.of(context).warning
        );
      case AdminResource.ngos:
        return null;
      case AdminResource.volunteers:
        final status = item['availability_status']?.toString() ?? '';
        return (_titleCase(status), _adminStatusColor(context, status));
      case AdminResource.donations:
        final status = item['status']?.toString() ?? '';
        final donationStatus = _donationStatusFromBackend(status);
        return (
          donationStatusLabel(donationStatus),
          donationStatusColor(donationStatus, context)
        );
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
                        style:
                            TextStyle(color: c.textSecondary, fontSize: 12.5)),
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

class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  bool _loading = true;
  String? _error;
  List<LeaderboardEntry> _entries = const [];

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
      final raw = await context.read<AppState>().api.getLeaderboard();
      if (!mounted) return;
      setState(() {
        _entries = raw
            .whereType<Map<String, dynamic>>()
            .map(LeaderboardEntry.fromBackend)
            .toList(growable: false);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _apiErrorMessage(e,
            fallback: 'Could not load the public leaderboard.');
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
    final c = AppColors.of(context);
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
          Expanded(child: _body(c)),
        ],
      ),
    );
  }

  Widget _body(AppColors c) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 40, color: c.textSecondary),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              SecondaryButton(
                  label: 'Retry', icon: Icons.refresh, onPressed: _load),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return const EmptyState(
        icon: Icons.leaderboard_outlined,
        message:
            'No organizations are on the public leaderboard yet. It fills up as opted-in providers and NGOs complete real donations.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final e = _entries[i];
        final typeLabel = e.type == 'ngo' ? 'NGO' : 'Provider';
        final cityLabel = e.city.isEmpty ? 'City not set' : e.city;
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor:
                  i == 0 ? c.green.withOpacity(0.15) : c.surfaceAlt,
              child: Text('#${e.rank}',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: i == 0 ? c.green : c.textPrimary)),
            ),
            title: Text(e.name,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(
                '$typeLabel • $cityLabel • ${e.kgRedistributed.toStringAsFixed(1)} kg redistributed'),
            trailing: Text('${e.mealsRescued} meals',
                style: TextStyle(
                    fontWeight: FontWeight.w800, color: c.bluePrimary)),
          ),
        );
      },
    );
  }
}

// =============================================================================
// NOTIFICATIONS (shared across roles)
// =============================================================================

NotificationCategory _notificationCategoryFromType(String? t) =>
    notificationCategoryForType(t);

class NotificationsScreen extends StatefulWidget {
  final UserRole role;
  final bool
      embedded; // true when used as a bottom-nav tab (no back button needed)

  /// Injected in tests so no real platform channel is touched.
  final PermissionService? permissions;
  const NotificationsScreen(
      {super.key, required this.role, this.embedded = false, this.permissions});

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

  /// Null means "not evaluated yet" (or dismissed), which hides the banner.
  PermissionOutcome? _notificationOutcome;
  bool _notificationPromptDismissed = false;

  late final PermissionService _permissions =
      widget.permissions ?? PermissionService();

  @override
  void initState() {
    super.initState();
    _load();
    _checkNotificationPermission();
  }

  /// Reads the current permission state WITHOUT prompting. The OS dialog is
  /// only ever triggered by an explicit "Allow" tap, so the app never nags
  /// and never prompts on the splash screen.
  Future<void> _checkNotificationPermission() async {
    try {
      final outcome = await _permissions.status(AppPermission.notifications);
      if (!mounted) return;
      setState(() {
        // Granted (or not required on this OS) means nothing to offer.
        _notificationOutcome = (outcome == PermissionOutcome.granted ||
                outcome == PermissionOutcome.notRequired)
            ? null
            : outcome;
      });
    } catch (_) {
      // Permission status is never a reason to break the screen.
    }
  }

  Future<void> _requestNotificationPermission() async {
    final outcome = await _permissions.request(AppPermission.notifications);
    if (!mounted) return;
    setState(() {
      _notificationOutcome =
          outcome == PermissionOutcome.granted ? null : outcome;
      _notificationPromptDismissed = outcome != PermissionOutcome.granted;
    });
    if (outcome == PermissionOutcome.permanentlyDenied ||
        outcome == PermissionOutcome.restricted) {
      await _permissions.openAppSettings();
    }
    if (outcome == PermissionOutcome.granted && mounted) {
      await context.read<AppState>().refreshFcmTokenRegistration();
    }
  }

  void _dismissNotificationPrompt() {
    setState(() {
      _notificationPromptDismissed = true;
      _notificationOutcome = null;
    });
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
              relatedDonationId: item['related_donation_id']?.toString(),
              title: safeNotificationCopy(
                item['title']?.toString(),
                item['message']?.toString(),
              ).title,
              body: safeNotificationCopy(
                item['title']?.toString(),
                item['message']?.toString(),
              ).body,
              time: _fromIsoTime(item['created_at']),
              category: _notificationCategoryFromType(item['type']?.toString()),
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

  Future<void> _openNotification(AppNotificationItem item) async {
    await _markRead(item);
    final donationId = item.relatedDonationId;
    if (donationId == null || donationId.isEmpty || !mounted) return;
    try {
      final api = context.read<AppState>().api;
      final rawClaims = widget.role == UserRole.provider
          ? await api.getProviderClaims()
          : widget.role == UserRole.ngo
              ? await api.getClaims()
              : const <dynamic>[];
      for (final raw in rawClaims) {
        if (raw is! Map || raw['donation_id']?.toString() != donationId) {
          continue;
        }
        final claim = Map<String, dynamic>.from(raw);
        final donationValue = claim['donation'];
        if (donationValue is! Map || !mounted) return;
        final donation = Donation.fromBackend(
          Map<String, dynamic>.from(donationValue),
          includePrivateContacts: true,
        );
        final page = widget.role == UserRole.provider
            ? ProviderClaimedDonationScreen(donation: donation)
            : ClaimedDonationDashboard(donation: donation);
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => page),
        );
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('This donation is no longer available.')),
        );
      }
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_apiErrorMessage(
            error,
            fallback: 'Could not open this donation. Please try again.',
          )),
        ),
      );
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
              _failed
                  ? 'Could not load notifications.'
                  : 'No notifications yet.',
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
          onTap: () => _openNotification(items[i]),
        ),
      );
    }

    // Permission is offered here, inside the notification flow the user
    // deliberately opened, never on the splash screen. It is a dismissible
    // banner and the list stays fully usable either way, so declining costs
    // nothing: in-app notifications continue to work.
    final showBanner =
        _notificationOutcome != null && !_notificationPromptDismissed;
    final withBanner = !showBanner
        ? body
        : Column(
            children: [
              _NotificationPermissionBanner(
                outcome: _notificationOutcome!,
                onAllow: _requestNotificationPermission,
                onDismiss: _dismissNotificationPrompt,
              ),
              Expanded(child: body),
            ],
          );

    if (widget.embedded) {
      return Scaffold(
          appBar: AppBar(
              title: const Text('Notifications'),
              automaticallyImplyLeading: false,
              actions: const [ThemeToggleButton()]),
          body: withBanner);
    }
    return Scaffold(
        appBar: AppBar(title: const Text('Notifications')), body: withBanner);
  }
}

/// Non-blocking notification permission offer shown inside the notifications
/// screen. Dismissible and never re-prompts the OS dialog on its own.
class _NotificationPermissionBanner extends StatelessWidget {
  final PermissionOutcome outcome;
  final VoidCallback onAllow;
  final VoidCallback onDismiss;

  const _NotificationPermissionBanner({
    required this.outcome,
    required this.onAllow,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final blocked = outcome == PermissionOutcome.permanentlyDenied ||
        outcome == PermissionOutcome.restricted;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.bluePrimary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.notifications_active_outlined, color: c.bluePrimary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(PermissionCopy.notificationsTitle,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              IconButton(
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            PermissionCopy.deniedMessage(AppPermission.notifications, outcome),
            style: TextStyle(fontSize: 12, color: c.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              PrimaryButton(
                label: blocked ? 'Open Settings' : 'Allow',
                icon: blocked ? Icons.settings_outlined : Icons.check,
                onPressed: onAllow,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SHARED PROFILE TAB
// =============================================================================

class ProfileTab extends StatelessWidget {
  final UserRole role;
  final String name;

  /// Provider and NGO only. Null for volunteer / admin, which keeps the vehicle
  /// controls out of those settings entirely.
  final VehicleAvailability? vehicleAvailability;
  final Future<void> Function(VehicleAvailability)? onVehicleAnswer;
  final bool savingVehicle;
  final String? imageUrl;

  const ProfileTab({
    super.key,
    required this.role,
    required this.name,
    this.vehicleAvailability,
    this.onVehicleAnswer,
    this.savingVehicle = false,
    this.imageUrl,
  });

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
    final state = context.watch<AppState>();
    final completion = state.profileCompletion;
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
                SahaayAvatar(
                    radius: 28,
                    imageUrl: imageUrl,
                    fallbackText: name.isNotEmpty ? name : '?',
                    backgroundColor: c.bluePrimary.withOpacity(0.12),
                    foregroundColor: c.bluePrimary),
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
          if (completion != null && shouldShowProfileProgress(completion)) ...[
            const SizedBox(height: AppSpacing.md),
            ProfileCompletionCard(
              role: role,
              completion: completion,
            ),
          ],
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
                      builder: (_) => SettingsScreen(
                          role: role,
                          name: name,
                          vehicleAvailability: vehicleAvailability,
                          onVehicleAnswer: onVehicleAnswer,
                          savingVehicle: savingVehicle)))),
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
  final VehicleAvailability? vehicleAvailability;
  final Future<void> Function(VehicleAvailability)? onVehicleAnswer;
  final bool savingVehicle;
  const SettingsScreen({
    super.key,
    required this.role,
    required this.name,
    this.vehicleAvailability,
    this.onVehicleAnswer,
    this.savingVehicle = false,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Local, genuine app preferences (not backend/user data) — safe to keep
  // as real, functional toggles even before a backend exists.
  bool _donationAlerts = true;
  bool _matchingAlerts = true;
  bool _rewardAlerts = true;

  /// In-flight guard for the leaderboard-visibility toggle (which persists to
  /// the backend, unlike the local-only notification preference switches).
  bool _savingLeaderboard = false;

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

  /// Persists the public-leaderboard visibility to the backend. Unlike the
  /// notification switches (genuine local-only preferences), this one writes
  /// `users.leaderboard_public`, so it must round-trip the server.
  Future<void> _setLeaderboardVisible(bool value) async {
    setState(() => _savingLeaderboard = true);
    try {
      await context.read<AppState>().setLeaderboardPublic(value);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(value
              ? 'Your organization is now visible on the public leaderboard.'
              : 'Your organization is now hidden from the public leaderboard.')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_apiErrorMessage(e,
              fallback: 'Could not update leaderboard visibility.'))));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Could not update leaderboard visibility. Please try again.')));
    } finally {
      if (mounted) setState(() => _savingLeaderboard = false);
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
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => EditProfileScreen(role: widget.role),
                  ),
                ),
              ),
              // Provider and NGO: the durable place to change the answer later.
              // Shown for every state, including answered, so the current value
              // is always visible and editable.
              if (widget.vehicleAvailability != null &&
                  widget.onVehicleAnswer != null) ...[
                const Divider(height: 1),
                VehicleAvailabilityTile(
                  value: widget.vehicleAvailability!,
                  saving: widget.savingVehicle,
                  onAnswer: widget.onVehicleAnswer!,
                  role: widget.role == UserRole.provider
                      ? VehicleRole.provider
                      : VehicleRole.ngo,
                ),
              ],
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
              subtitle: const Text(
                  'Only opted-in organizations with real completed donations appear.'),
              value: state.leaderboardPublic,
              onChanged: _savingLeaderboard ? null : _setLeaderboardVisible,
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
// EDIT PROFILE
// =============================================================================

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key, required this.role});
  final UserRole role;
  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _organization = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController();
  final _description = TextEditingController();
  final _registration = TextEditingController();
  final _googleReviewUrl = TextEditingController();
  final _maxDonationCapacityKg = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _photoUrl;
  File? _pendingPhoto;
  String? _availableFrom;
  String? _availableTo;
  final Set<String> _ngoFoodTypes = {};
  final Set<String> _ngoDietaryPreferences = {};
  bool? _ngoVehicleAvailable;
  bool _ngoVehicleChanged = false;

  // The signed-in organization's real coordinates. Null until a location was
  // actually stored or picked — never invented.
  double? _latitude;
  double? _longitude;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _organization.dispose();
    _address.dispose();
    _city.dispose();
    _description.dispose();
    _registration.dispose();
    _googleReviewUrl.dispose();
    _maxDonationCapacityKg.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await context.read<AppState>().api.getProfile();
      final roleProfile = _roleProfileMap(profile['profile']);
      if (!mounted) return;
      setState(() {
        _name.text = profile['full_name']?.toString() ?? '';
        _phone.text = profile['phone']?.toString() ?? '';
        _organization.text = roleProfile['organization_name']?.toString() ?? '';
        _address.text = roleProfile['address']?.toString() ?? '';
        _city.text = roleProfile['city']?.toString() ?? '';
        _description.text = roleProfile['description']?.toString() ?? '';
        _registration.text =
            roleProfile['registration_number']?.toString() ?? '';
        _googleReviewUrl.text =
            roleProfile['google_review_url']?.toString() ?? '';
        _latitude = _coordinateFromMap(roleProfile, 'latitude', 90);
        _longitude = _coordinateFromMap(roleProfile, 'longitude', 180);
        _availableFrom = roleProfile['available_from']?.toString();
        _availableTo = roleProfile['available_to']?.toString();
        _ngoFoodTypes
          ..clear()
          ..addAll(
            (roleProfile['preferred_food_types'] as List? ?? const [])
                .whereType<String>(),
          );
        _ngoDietaryPreferences
          ..clear()
          ..addAll(
            (roleProfile['dietary_preferences'] as List? ?? const [])
                .whereType<String>(),
          );
        _ngoVehicleAvailable = roleProfile['vehicle_available'] is bool
            ? roleProfile['vehicle_available'] as bool
            : null;
        _ngoVehicleChanged = false;
        final capacityKg = roleProfile['max_capacity_kg'];
        _maxDonationCapacityKg.text = capacityKg?.toString() ?? '';
        _photoUrl = profile['profile_image_url']?.toString();
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error =
            _apiErrorMessage(error, fallback: 'Could not load your profile.');
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your profile. Please try again.';
        _loading = false;
      });
    }
  }

  /// Opens SAHAAY's one location picker, seeded with the stored location when
  /// one exists, and adopts whatever real place was chosen.
  Future<void> _chooseLocation() async {
    final result = await showLocationPicker(
      context,
      title: 'Set your location',
      latitude: _latitude,
      longitude: _longitude,
      address: _address.text.trim(),
    );
    if (result == null || !mounted) return;
    if (!result.hasCoordinates) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Choose a real map pin with coordinates for matching.'),
        ),
      );
      return;
    }
    setState(() {
      _latitude = result.latitude;
      _longitude = result.longitude;
      _address.text = result.address;
      if (result.city != null && result.city!.trim().isNotEmpty) {
        _city.text = result.city!;
      } else if (result.addressIsCoordinates) {
        _city.text = '';
      }
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (widget.role == UserRole.ngo) {
      if ((_latitude == null) != (_longitude == null)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Set both map coordinates together.'),
          ),
        );
        return;
      }
      if ((_availableFrom == null) != (_availableTo == null) ||
          (_availableFrom != null && _availableFrom == _availableTo)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Set two different operating hours, or clear both.'),
          ),
        );
        return;
      }
      final capacityText = _maxDonationCapacityKg.text.trim();
      final maxDonationCapacityKg =
          capacityText.isEmpty ? null : double.tryParse(capacityText);
      if (capacityText.isNotEmpty &&
          (maxDonationCapacityKg == null ||
              !maxDonationCapacityKg.isFinite ||
              maxDonationCapacityKg <= 0)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enter a positive food weight in kilograms.'),
          ),
        );
        return;
      }
    }
    setState(() => _saving = true);
    final payload = <String, dynamic>{
      'full_name': _name.text.trim(),
      'phone': _phone.text.trim(),
    };
    if (widget.role == UserRole.provider || widget.role == UserRole.ngo) {
      final values = <String, dynamic>{
        'organization_name': _organization.text.trim(),
        'address': _address.text.trim(),
        'city': _city.text.trim(),
        'description': _description.text.trim(),
        if (_latitude != null) 'latitude': _latitude,
        if (_longitude != null) 'longitude': _longitude,
        'google_review_url': _googleReviewUrl.text.trim().isEmpty
            ? null
            : _googleReviewUrl.text.trim(),
      };
      if (widget.role == UserRole.ngo) {
        values['registration_number'] = _registration.text.trim();
        values['available_from'] = _availableFrom;
        values['available_to'] = _availableTo;
        values['latitude'] = _latitude;
        values['longitude'] = _longitude;
        values['max_capacity_kg'] = _maxDonationCapacityKg.text.trim().isEmpty
            ? null
            : double.parse(_maxDonationCapacityKg.text.trim());
        values['preferred_food_types'] =
            _ngoFoodTypes.isEmpty ? null : _ngoFoodTypes.toList();
        values['dietary_preferences'] = _ngoDietaryPreferences.isEmpty
            ? null
            : _ngoDietaryPreferences.toList();
        if (_ngoVehicleChanged) {
          values['vehicle_available'] = _ngoVehicleAvailable;
        }
        payload['ngo'] = values;
      } else {
        payload['provider'] = values;
      }
    }
    try {
      await context.read<AppState>().api.updateProfile(payload);
      await context.read<AppState>().refreshProfile();
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(_apiErrorMessage(error,
                fallback: 'Could not save your profile.'))),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Could not save your profile. Please try again.')),
      );
    }
  }

  Future<void> _choosePhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Profile photo')),
          ListTile(
            title: const Text('Take Photo'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            title: const Text('Choose from Gallery'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source == null) return;
    // Downscale on capture so a multi-MB phone photo never trips the backend's
    // 5 MB cap (the food/handover pickers already pass imageQuality).
    final image =
        await ImagePicker().pickImage(source: source, imageQuality: 80);
    if (image != null && mounted) {
      setState(() => _pendingPhoto = File(image.path));
    }
  }

  Future<void> _uploadPhoto() async {
    final photo = _pendingPhoto;
    if (photo == null) return;
    setState(() => _saving = true);
    try {
      final url = await context.read<AppState>().api.uploadProfilePhoto(photo);
      await context.read<AppState>().refreshProfile();
      if (!mounted) return;
      setState(() {
        _photoUrl = url;
        _pendingPhoto = null;
        _saving = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      // Surface the real reason (route/validation/size) instead of hiding it.
      final message = error is ApiException && error.message.trim().isNotEmpty
          ? error.message
          : 'Could not upload the profile photo. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  Widget _field(TextEditingController controller, String label,
      {int maxLines = 1, TextInputType? keyboardType}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        textInputAction:
            maxLines == 1 ? TextInputAction.next : TextInputAction.newline,
        decoration: InputDecoration(labelText: label),
        validator: switch (label) {
          'Full name' => (value) =>
              value == null || value.trim().isEmpty ? 'Enter your name.' : null,
          _ => null,
        },
      ),
    );
  }

  Widget _avatarInitial() {
    final label = _organization.text.trim().isNotEmpty
        ? _organization.text.trim()
        : _name.text.trim();
    final initial = label.isEmpty ? '?' : label[0].toUpperCase();
    return Text(initial,
        style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(title: const Text('Edit Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Text(_error!, textAlign: TextAlign.center),
                    ),
                    TextButton(
                        onPressed: _loadProfile, child: const Text('Retry')),
                  ]),
                )
              : SafeArea(
                  child: LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: EdgeInsets.fromLTRB(
                          AppSpacing.lg,
                          AppSpacing.lg,
                          AppSpacing.lg,
                          AppSpacing.lg +
                              MediaQuery.viewInsetsOf(context).bottom),
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(minHeight: constraints.maxHeight),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Center(
                                child: CircleAvatar(
                                  radius: 42,
                                  backgroundColor: c.surfaceAlt,
                                  backgroundImage: _pendingPhoto == null
                                      ? null
                                      : FileImage(_pendingPhoto!),
                                  child: _pendingPhoto != null
                                      ? null
                                      : (_photoUrl == null || _photoUrl!.isEmpty
                                          ? _avatarInitial()
                                          : ClipOval(
                                              child: Image.network(
                                                _photoUrl!,
                                                width: 84,
                                                height: 84,
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) =>
                                                    _avatarInitial(),
                                              ),
                                            )),
                                ),
                              ),
                              if (_pendingPhoto != null) ...[
                                const Center(
                                    child: Text('Preview — not saved yet')),
                                OutlinedButton(
                                  onPressed: _saving ? null : _uploadPhoto,
                                  child: const Text('UPLOAD PHOTO'),
                                ),
                                TextButton(
                                  onPressed: _saving
                                      ? null
                                      : () =>
                                          setState(() => _pendingPhoto = null),
                                  child: const Text('Cancel'),
                                ),
                              ],
                              OutlinedButton(
                                onPressed: _saving ? null : _choosePhoto,
                                child: const Text('CHANGE PHOTO'),
                              ),
                              const SizedBox(height: AppSpacing.md),
                              _field(_name, 'Full name'),
                              _field(_phone, 'Phone number',
                                  keyboardType: TextInputType.phone),
                              if (widget.role == UserRole.provider ||
                                  widget.role == UserRole.ngo) ...[
                                _field(_organization, 'Organization name'),
                                _field(_address, 'Address', maxLines: 2),
                                _field(_city, 'City'),
                                if (widget.role == UserRole.ngo)
                                  _field(_registration, 'Registration number'),
                                if (widget.role == UserRole.ngo) ...[
                                  Text(
                                    _latitude == null ||
                                            _availableFrom == null ||
                                            _availableTo == null ||
                                            _maxDonationCapacityKg.text
                                                .trim()
                                                .isEmpty ||
                                            _ngoFoodTypes.isEmpty ||
                                            _ngoDietaryPreferences.isEmpty
                                        ? 'Complete your profile details to appear in matching results.'
                                        : 'Matching location, hours, food preferences, and capacity are set.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: _latitude == null ||
                                                  _availableFrom == null ||
                                                  _availableTo == null ||
                                                  _maxDonationCapacityKg.text
                                                      .trim()
                                                      .isEmpty ||
                                                  _ngoFoodTypes.isEmpty ||
                                                  _ngoDietaryPreferences.isEmpty
                                              ? c.danger
                                              : c.green,
                                        ),
                                  ),
                                  const SizedBox(height: AppSpacing.md),
                                  AppInputField(
                                    label: 'Maximum donation amount (kg)',
                                    controller: _maxDonationCapacityKg,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true),
                                    prefixIcon: Icons.scale_outlined,
                                    validator: (value) {
                                      final capacity =
                                          double.tryParse(value?.trim() ?? '');
                                      return (value?.trim().isNotEmpty ??
                                                  false) &&
                                              (capacity == null ||
                                                  !capacity.isFinite ||
                                                  capacity <= 0)
                                          ? 'Enter a positive food weight in kilograms, or leave blank.'
                                          : null;
                                    },
                                  ),
                                  const SizedBox(height: AppSpacing.sm),
                                  Text(
                                    'This is the maximum weight for one donation, separate from people served each day.',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: AppSpacing.md),
                                  OperatingHoursFields(
                                    requiredForMatching: false,
                                    value: (
                                      from: _availableFrom,
                                      to: _availableTo,
                                    ),
                                    onChanged: (hours) => setState(() {
                                      _availableFrom = hours.from;
                                      _availableTo = hours.to;
                                    }),
                                  ),
                                  const SizedBox(height: AppSpacing.md),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'Preferred food categories',
                                      style:
                                          Theme.of(context).textTheme.bodyLarge,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: _kFoodCategories.map((category) {
                                      final selected =
                                          _ngoFoodTypes.contains(category);
                                      return FilterChip(
                                        label: Text(category),
                                        selected: selected,
                                        onSelected: (value) => setState(() {
                                          if (value) {
                                            _ngoFoodTypes.add(category);
                                          } else {
                                            _ngoFoodTypes.remove(category);
                                          }
                                        }),
                                      );
                                    }).toList(),
                                  ),
                                  const SizedBox(height: AppSpacing.md),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'Dietary types accepted',
                                      style:
                                          Theme.of(context).textTheme.bodyLarge,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: _kDietaryPreferenceLabels.entries
                                        .map((entry) {
                                      final selected = _ngoDietaryPreferences
                                          .contains(entry.key);
                                      return FilterChip(
                                        label: Text(entry.value),
                                        selected: selected,
                                        onSelected: (value) => setState(() {
                                          if (value) {
                                            _ngoDietaryPreferences
                                                .add(entry.key);
                                          } else {
                                            _ngoDietaryPreferences
                                                .remove(entry.key);
                                          }
                                        }),
                                      );
                                    }).toList(),
                                  ),
                                  const SizedBox(height: AppSpacing.md),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'Vehicle availability',
                                      style:
                                          Theme.of(context).textTheme.bodyLarge,
                                    ),
                                  ),
                                  Wrap(
                                    spacing: 8,
                                    children: <(bool?, String)>[
                                      (null, 'Not answered'),
                                      (true, 'Available'),
                                      (false, 'Unavailable'),
                                    ].map((choice) {
                                      return ChoiceChip(
                                        label: Text(choice.$2),
                                        selected:
                                            _ngoVehicleAvailable == choice.$1,
                                        onSelected: (selected) {
                                          if (!selected) return;
                                          setState(() {
                                            _ngoVehicleAvailable = choice.$1;
                                            _ngoVehicleChanged = true;
                                          });
                                        },
                                      );
                                    }).toList(),
                                  ),
                                  const SizedBox(height: AppSpacing.md),
                                ],
                                _field(_description, 'Description',
                                    maxLines: 4),
                                _field(_googleReviewUrl,
                                    'Official Google Maps listing / review link'),
                                const Padding(
                                  padding:
                                      EdgeInsets.only(bottom: AppSpacing.md),
                                  child: Text(
                                    'Paste the share link for your official Google Maps listing. Reviews open in Google Maps and must reflect genuine experiences.',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _saving ? null : _chooseLocation,
                                  icon: const Icon(Icons.map_outlined),
                                  label: Text(_latitude == null
                                      ? 'Choose location on map (needed for matching)'
                                      : 'Location chosen — tap to change'),
                                ),
                                const SizedBox(height: AppSpacing.md),
                              ],
                              PrimaryButton(
                                label: 'SAVE CHANGES',
                                isLoading: _saving,
                                onPressed: _saving ? null : _save,
                              ),
                              const SizedBox(height: AppSpacing.lg),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
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
