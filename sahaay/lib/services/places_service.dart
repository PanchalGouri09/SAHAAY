/// Real Google Places autocomplete for SAHAAY's location picker.
///
/// The API key never appears in Dart. It is injected into `AndroidManifest.xml`
/// by the Secrets Gradle Plugin from the gitignored `android/secrets.properties`
/// (key `MAPS_API_KEY`) and read back at runtime by the native Places bridge
/// (`android/app/src/main/kotlin/com/example/sahaay/PlacesChannel.kt`), which
/// talks to the official **Places SDK for Android** over a method channel.
///
/// Nothing in this file, or in any test that uses it, performs a network call:
/// tests install a fake [PlacesGateway] through [placesGatewayOverride].
library;

import 'package:flutter/services.dart';

/// The method channel shared with the native Places bridge.
const MethodChannel placesMethodChannel = MethodChannel('sahaay/places');

/// One autocomplete prediction returned by the Places SDK.
class PlaceSuggestion {
  const PlaceSuggestion({
    required this.placeId,
    required this.primaryText,
    required this.secondaryText,
    required this.fullText,
  });

  final String placeId;
  final String primaryText;
  final String secondaryText;
  final String fullText;

  /// True when the prediction carries enough to be shown. An empty id cannot
  /// be resolved later, so it is filtered out rather than rendered.
  bool get isUsable => placeId.trim().isNotEmpty;

  @override
  String toString() => fullText;
}

/// A resolved place: the real coordinates plus the readable address Google
/// returned for it. Both coordinates are required — a place that cannot be
/// placed on the map is not a usable selection.
class PlaceDetails {
  const PlaceDetails({
    required this.placeId,
    required this.latitude,
    required this.longitude,
    required this.address,
    this.name,
  });

  final String placeId;
  final double latitude;
  final double longitude;
  final String address;
  final String? name;

  bool get hasUsableCoordinates =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;
}

/// Raised when the Places bridge reports a failure (SDK not configured, the
/// Places API rejected the request, the device is offline, …).
///
/// The message is deliberately user-readable: it is surfaced verbatim in the
/// search field's error state, so it never contains stack traces or keys.
class PlacesException implements Exception {
  const PlacesException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

/// Platform seam. Production uses the method channel; tests install a fake.
abstract class PlacesGateway {
  /// Starts a fresh Google Places billing session.
  ///
  /// Callers invoke this once per picker open so the subsequent detail lookup
  /// is billed inside the same autocomplete session. Implementations that do
  /// not bill by session (test fakes) may simply return.
  Future<void> newSession();

  /// Real Google Places Autocomplete for [query].
  ///
  /// Returns an empty list for an empty/blank query (no request is made) and
  /// an empty list when Google simply has no matches. A genuine failure
  /// throws [PlacesException] so the UI can say so honestly.
  Future<List<PlaceSuggestion>> autocomplete(
    String query, {
    String? sessionToken,
  });

  /// Resolves one suggestion into coordinates and a readable address.
  Future<PlaceDetails?> placeDetails(String placeId);
}

/// Method-channel implementation backed by the native Places SDK bridge.
class MethodChannelPlacesGateway implements PlacesGateway {
  const MethodChannelPlacesGateway();

  @override
  Future<void> newSession() async {
    try {
      await placesMethodChannel.invokeMethod<void>('newSession');
    } on MissingPluginException {
      // No native bridge (e.g. running on the host machine): the session is
      // simply never started, which costs nothing because no queries follow.
    } on PlatformException {
      // Session tokens only affect billing grouping — never worth failing over.
    }
  }

  @override
  Future<List<PlaceSuggestion>> autocomplete(
    String query, {
    String? sessionToken,
  }) async {
    if (query.trim().isEmpty) return const <PlaceSuggestion>[];
    final Object? raw;
    try {
      raw = await placesMethodChannel.invokeMethod<Object?>('autocomplete', {
        'query': query.trim(),
        if (sessionToken != null && sessionToken.isNotEmpty)
          'sessionToken': sessionToken,
      });
    } on PlatformException catch (e) {
      throw PlacesException(
        e.message?.trim().isNotEmpty == true
            ? e.message!.trim()
            : 'Place search is unavailable right now.',
        code: e.code,
      );
    } on MissingPluginException {
      throw const PlacesException(
          'Place search is not available on this device.');
    }
    return parseAutocompleteResponse(raw);
  }

  @override
  Future<PlaceDetails?> placeDetails(String placeId) async {
    if (placeId.trim().isEmpty) return null;
    final Object? raw;
    try {
      raw = await placesMethodChannel
          .invokeMethod<Object?>('placeDetails', {'placeId': placeId.trim()});
    } on PlatformException catch (e) {
      throw PlacesException(
        e.message?.trim().isNotEmpty == true
            ? e.message!.trim()
            : 'Could not look up that place.',
        code: e.code,
      );
    } on MissingPluginException {
      throw const PlacesException(
          'Place lookup is not available on this device.');
    }
    return parsePlaceDetailsResponse(raw);
  }
}

/// Test seam. Null in the app, which falls through to the native bridge.
PlacesGateway? placesGatewayOverride;

/// Returns the override when a test installed one, otherwise the real bridge.
PlacesGateway activePlacesGateway() =>
    placesGatewayOverride ?? const MethodChannelPlacesGateway();

/// Pure decoder for an autocomplete response, so the parsing is unit-testable
/// without a platform channel or network.
List<PlaceSuggestion> parseAutocompleteResponse(Object? raw) {
  if (raw is! Map) return const <PlaceSuggestion>[];
  final predictions = raw['predictions'];
  if (predictions is! List) return const <PlaceSuggestion>[];
  final suggestions = <PlaceSuggestion>[];
  for (final item in predictions) {
    if (item is! Map) continue;
    final placeId = _text(item['placeId']);
    final primary = _text(item['primaryText']);
    final secondary = _text(item['secondaryText']);
    final full = _text(item['fullText']);
    final resolvedPrimary =
        primary.isNotEmpty ? primary : (full.isNotEmpty ? full : placeId);
    final suggestion = PlaceSuggestion(
      placeId: placeId,
      primaryText: resolvedPrimary,
      secondaryText: secondary,
      fullText: full.isNotEmpty
          ? full
          : secondary.isNotEmpty
              ? '$resolvedPrimary, $secondary'
              : resolvedPrimary,
    );
    if (suggestion.isUsable) suggestions.add(suggestion);
  }
  return suggestions;
}

/// Pure decoder for a place-details response. Returns null when the payload
/// has no usable coordinates — never a fabricated point.
PlaceDetails? parsePlaceDetailsResponse(Object? raw) {
  if (raw is! Map) return null;
  final latitude = _number(raw['latitude']);
  final longitude = _number(raw['longitude']);
  if (latitude == null || longitude == null) return null;
  final details = PlaceDetails(
    placeId: _text(raw['placeId']),
    latitude: latitude,
    longitude: longitude,
    address: _text(raw['address']),
    name: raw['name'] == null ? null : _text(raw['name']),
  );
  return details.hasUsableCoordinates &&
          details.address.trim().isNotEmpty
      ? details
      : null;
}

String _text(Object? value) => value?.toString().trim() ?? '';

double? _number(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}
