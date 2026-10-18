/// Address resolution for SAHAAY's location picker.
///
/// Reverse geocoding (coordinates -> readable address) runs through the
/// platform Geocoder supplied by the `geocoding` package. That path does not
/// need a Google API key, so nothing secret reaches Dart here either.
///
/// Every entry point is overridable so tests never touch the network or the
/// platform channel.
library;

import 'package:geocoding/geocoding.dart';

/// A resolved address plus the city it belongs to (null when the placemark
/// carries none, which is honest — not every reverse geocode yields a city).
typedef PlaceAddress = ({String address, String? city});

/// Test seam. Null in the app, which falls through to the platform Geocoder.
typedef ReverseGeocoder = Future<PlaceAddress?> Function(
    double latitude, double longitude);

ReverseGeocoder? reverseGeocoderOverride;

final Map<String, Future<PlaceAddress?>> _reverseGeocodeCache = {};
final RegExp _coordinatePairPattern = RegExp(
  r'^[+-]?(?:\d+(?:\.\d+)?|\.\d+)\s*,\s*[+-]?(?:\d+(?:\.\d+)?|\.\d+)$',
);

/// Returns a human-readable stored address or an honest fallback for blank and
/// legacy coordinate-pair values.
String readableAddressOrUnavailable(String? value) {
  final address = value?.trim() ?? '';
  if (address.isEmpty || _coordinatePairPattern.hasMatch(address)) {
    return 'Address unavailable';
  }
  return address;
}

/// Builds one readable, comma-separated address line from a placemark.
///
/// Parts that Google did not return are simply skipped, so the result never
/// contains ", ,". Returns '' when nothing at all is available — callers treat
/// that as "address unknown" rather than inventing one.
String formatPlacemarkAddress(Placemark placemark) {
  final thoroughfare =
      _joinNonEmpty([placemark.subThoroughfare, placemark.thoroughfare]);
  final streetLine =
      _joinNonEmpty([thoroughfare, placemark.subLocality], separator: ', ');
  final city = placemarkCity(placemark);
  final region = _joinNonEmpty(
      [placemark.administrativeArea, placemark.postalCode]);
  final address = _joinNonEmpty(
      [streetLine, city, region, placemark.country],
      separator: ', ');
  if (address.isNotEmpty) return address;
  // A placemark with no structured parts sometimes still has a place name.
  return _clean(placemark.name);
}

/// The locality-level name, which is what SAHAAY stores as "city".
String? placemarkCity(Placemark placemark) =>
    _clean(placemark.locality).isNotEmpty
        ? _clean(placemark.locality)
        : (_clean(placemark.subAdministrativeArea).isNotEmpty
            ? _clean(placemark.subAdministrativeArea)
            : null);

/// Resolves coordinates into a readable address, honouring
/// [reverseGeocoderOverride] first.
///
/// Returns null when the platform has no answer (offline, no Geocoder, or an
/// out-of-range coordinate) so the picker can say the address is unavailable
/// instead of storing a fabricated one.
Future<PlaceAddress?> reverseGeocodeCoordinates(
  double latitude,
  double longitude,
) async {
  final override = reverseGeocoderOverride;
  if (override != null) return override(latitude, longitude);
  if (!latitude.isFinite ||
      !longitude.isFinite ||
      latitude < -90 ||
      latitude > 90 ||
      longitude < -180 ||
      longitude > 180) {
    return null;
  }
  final cacheKey =
      '${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}';
  final lookup = _reverseGeocodeCache.putIfAbsent(cacheKey, () async {
    try {
      final placemarks =
          await Geocoding().placemarkFromCoordinates(latitude, longitude);
      if (placemarks.isEmpty) return null;
      final placemark = placemarks.first;
      final address = formatPlacemarkAddress(placemark);
      if (address.isEmpty) return null;
      return (address: address, city: placemarkCity(placemark));
    } catch (_) {
      return null;
    }
  });
  final result = await lookup;
  if (result == null && identical(_reverseGeocodeCache[cacheKey], lookup)) {
    _reverseGeocodeCache.remove(cacheKey);
  }
  return result;
}

String _clean(String? value) => (value ?? '').trim();

String _joinNonEmpty(List<String?> values, {String separator = ' '}) => values
    .map(_clean)
    .where((value) => value.isNotEmpty)
    .join(separator);
