/// Deterministic straight-line (great-circle) distance between two WGS-84
/// points.
///
/// This is deliberately NOT road distance: SAHAAY does not call the Distance
/// Matrix or Routes APIs, and nothing here pretends to know a route. Anything
/// displayed from these helpers must be labelled as a straight-line distance.
///
/// Every argument is allowed to be null because a missing coordinate is a
/// normal, honest state in SAHAAY (a provider never dropped a pin, a legacy
/// delivery row predates the coordinate columns). When ANY coordinate is
/// missing or out of range the result is null rather than 0 — a 0 km distance
/// would read as "right here", which is a lie.
library;

import 'dart:math' as math;

/// Mean radius of the Earth in kilometres (IUGG).
const double _earthRadiusKm = 6371.0088;

const double _degreesToRadians = math.pi / 180.0;

bool _valid(double? value, double limit) =>
    value != null && value.isFinite && value.abs() <= limit;

/// True when both points are real, finite, in-range WGS-84 coordinates.
bool coordinatesAreUsable(
  double? latitudeA,
  double? longitudeA,
  double? latitudeB,
  double? longitudeB,
) =>
    _valid(latitudeA, 90) &&
    _valid(longitudeA, 180) &&
    _valid(latitudeB, 90) &&
    _valid(longitudeB, 180);

/// A single coordinate is real, finite and in range for its axis.
bool coordinateIsUsable(double? latitude, double? longitude) =>
    coordinatesAreUsable(latitude, longitude, latitude, longitude);

/// Straight-line distance in kilometres, or null when either point is missing
/// or out of range.
///
/// Haversine — accurate to well under 1 % anywhere on Earth, which is plenty
/// for "how far away is this pickup" and needs no network call.
double? haversineKm(
  double? latitudeA,
  double? longitudeA,
  double? latitudeB,
  double? longitudeB,
) {
  if (!coordinatesAreUsable(latitudeA, longitudeA, latitudeB, longitudeB)) {
    return null;
  }
  final latA = latitudeA! * _degreesToRadians;
  final latB = latitudeB! * _degreesToRadians;
  final deltaLat = (latitudeB - latitudeA) * _degreesToRadians;
  final deltaLng = (longitudeB! - longitudeA!) * _degreesToRadians;

  final sinLat = math.sin(deltaLat / 2);
  final sinLng = math.sin(deltaLng / 2);
  final a = sinLat * sinLat +
      math.cos(latA) * math.cos(latB) * sinLng * sinLng;
  final c = 2 * math.asin(math.sqrt(a.clamp(0.0, 1.0)));
  final distance = _earthRadiusKm * c;
  return distance.isFinite ? distance : null;
}

/// Human label for a straight-line distance, never claiming road distance.
///
/// Returns null (so callers can show an honest "—") when the distance is
/// unknown.
String? straightLineDistanceLabel(double? distanceKm) {
  if (distanceKm == null || !distanceKm.isFinite || distanceKm < 0) return null;
  if (distanceKm < 1) return '${(distanceKm * 1000).round()} m straight-line';
  return '${distanceKm.toStringAsFixed(1)} km straight-line';
}

/// Formats a matching-engine distance without confusing road and straight-line
/// measurements. Unknown sources are never guessed.
String matchingDistanceLabel(num? distanceKm, Object? source) {
  if (distanceKm == null ||
      !distanceKm.isFinite ||
      distanceKm < 0 ||
      (source != 'road' && source != 'straight_line')) {
    return 'Distance unavailable';
  }
  final value = distanceKm.toDouble();
  final amount = value < 1
      ? '${(value * 1000).round()} m'
      : '${value.toStringAsFixed(1)} km';
  final kind = source == 'road' ? 'driving' : 'straight-line';
  return '$amount $kind';
}

/// Match-engine scores are normalized to the 0–100 scale. Missing or invalid
/// values are unavailable, never clipped into a plausible-looking score.
String matchScoreLabel(num? score) {
  if (score == null || !score.isFinite || score < 0 || score > 100) {
    return 'Match score unavailable';
  }
  return 'Match score: ${score.toStringAsFixed(1)}%';
}
