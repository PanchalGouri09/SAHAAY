// Unit tests for the location plumbing that must never touch the network:
// haversine math, Places response parsing, and address formatting. Every
// function under test here is a pure decoder/helper, so no platform channel,
// API key or HTTP call is involved.

import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';
import 'package:sahaay/main.dart';
import 'package:sahaay/services/distance.dart';
import 'package:sahaay/services/geo_service.dart';
import 'package:sahaay/services/phone_contact.dart';
import 'package:sahaay/services/places_service.dart';

void main() {
  group('distance helpers', () {
    test('haversine at the equator: 1 degree is ~111.19 km', () {
      final km = haversineKm(0, 0, 0, 1);
      expect(km, isNotNull);
      expect(km!, closeTo(111.19, 0.2));
    });

    test('haversine Mumbai -> Pune is a real, plausible distance', () {
      final km = haversineKm(19.0760, 72.8777, 18.5204, 73.8567);
      expect(km, isNotNull);
      expect(km!, inInclusiveRange(100, 140));
    });

    test('haversine returns null when any coordinate is missing or invalid',
        () {
      expect(haversineKm(null, 0, 0, 1), isNull);
      expect(haversineKm(0, 0, null, 1), isNull);
      expect(haversineKm(0, 0, 0, null), isNull);
      expect(haversineKm(91, 0, 0, 1), isNull);
      expect(haversineKm(0, 181, 0, 1), isNull);
      expect(haversineKm(0, 0, -91, 1), isNull);
    });

    test('haversine zero distance is honestly zero for the same point', () {
      expect(haversineKm(19.0, 72.8, 19.0, 72.8), closeTo(0, 0.000001));
    });

    test('coordinatesAreUsable requires both real in-range pairs', () {
      expect(coordinatesAreUsable(19.0, 72.8, 18.5, 73.8), isTrue);
      expect(coordinatesAreUsable(null, 72.8, 18.5, 73.8), isFalse);
      expect(coordinatesAreUsable(19.0, 72.8, 18.5, null), isFalse);
      expect(coordinatesAreUsable(91.0, 72.8, 18.5, 73.8), isFalse);
      expect(coordinatesAreUsable(19.0, -181, 18.5, 73.8), isFalse);
    });

    test('coordinateIsUsable checks a single real in-range pair', () {
      expect(coordinateIsUsable(19.0760, 72.8777), isTrue);
      expect(coordinateIsUsable(null, 72.8777), isFalse);
      expect(coordinateIsUsable(19.0760, null), isFalse);
      expect(coordinateIsUsable(190.0, 72.8777), isFalse);
    });

    test('straightLineDistanceLabel is honest and never claims a route', () {
      expect(straightLineDistanceLabel(null), isNull);
      expect(straightLineDistanceLabel(-1), isNull);
      expect(straightLineDistanceLabel(0.5), '500 m straight-line');
      expect(straightLineDistanceLabel(5.0), '5.0 km straight-line');
    });

    test('matching distance labels preserve source and format short distances',
        () {
      expect(matchingDistanceLabel(0.5, 'road'), '500 m driving');
      expect(
          matchingDistanceLabel(2.4, 'straight_line'), '2.4 km straight-line');
      expect(matchingDistanceLabel(2.4, 'unknown'), 'Distance unavailable');
      expect(matchingDistanceLabel(null, 'road'), 'Distance unavailable');
      expect(matchingDistanceLabel(-1, 'road'), 'Distance unavailable');
    });

    test('match scores are labelled only on the normalized 0-100 scale', () {
      expect(matchScoreLabel(87.5), 'Match score: 87.5%');
      expect(matchScoreLabel(null), 'Match score unavailable');
      expect(matchScoreLabel(-1), 'Match score unavailable');
      expect(matchScoreLabel(100.1), 'Match score unavailable');
      expect(matchScoreLabel(double.nan), 'Match score unavailable');
    });
  });

  group('human-readable address fallback', () {
    test('uses stored addresses and hides coordinate-pair strings', () {
      expect(readableAddressOrUnavailable('12 Main Road, Pune'),
          '12 Main Road, Pune');
      expect(readableAddressOrUnavailable(' 18.5204, 73.8567 '),
          'Address unavailable');
      expect(readableAddressOrUnavailable(''), 'Address unavailable');
      expect(readableAddressOrUnavailable(null), 'Address unavailable');
    });

    group('claimed donation provider details', () {
      test('reads saved provider and claim fields without inventing contact data',
          () {
        final donation = Donation.fromBackend({
          'id': 'donation-1',
          'food_name': 'Rice meals',
          'food_category': 'prepared_meals',
          'quantity': 12,
          'servings': 24,
          'pickup_deadline': '2026-10-14T12:00:00Z',
          'expiry_time': '2026-10-14T13:00:00Z',
          'pickup_address': '12 Main Road, Pune',
          'claim_status': 'pending',
          'provider': {
            'organization_name': 'Verified Kitchen',
            'phone': '+91 8830392843',
            'verified': true,
            'address': 'Provider profile address',
          },
        });

        expect(donation.providerName, 'Verified Kitchen');
        expect(donation.providerAddress, '12 Main Road, Pune');
        expect(donation.providerContactNumber, '+91 8830392843');
        expect(donation.claimStatus, 'pending');
        expect(donation.foodExpiryLabel, startsWith('Expires '));
        expect(donation.category, 'prepared_meals');
      });

      test('does not expose unverified provider phone as callable contact', () {
        final donation = Donation.fromBackend({
          'id': 'donation-2',
          'provider': {
            'organization_name': 'Kitchen',
            'phone': '+91 8830392843',
            'verified': false,
          },
        });

        expect(donation.providerContactNumber, isNull);
        expect(dialerUriForPhone(donation.providerContactNumber), isNull);
      });
    });
  });

  group('Places autocomplete decoding', () {
    test('empty or missing payload yields no suggestions', () {
      expect(parseAutocompleteResponse(null), isEmpty);
      expect(parseAutocompleteResponse({'predictions': []}), isEmpty);
      expect(parseAutocompleteResponse({'predictions': 'nope'}), isEmpty);
    });

    test('decodes a real prediction and falls back to fullText for primary',
        () {
      final suggestions = parseAutocompleteResponse({
        'predictions': [
          {
            'placeId': 'ChIJabc',
            'primaryText': 'Taj Mahal Palace',
            'secondaryText': 'Apollo Bandar, Colaba',
            'fullText':
                'Taj Mahal Palace, Apollo Bandar, Colaba, Maharashtra, India',
          },
        ],
      });
      expect(suggestions, hasLength(1));
      expect(suggestions.single.placeId, 'ChIJabc');
      expect(suggestions.single.primaryText, 'Taj Mahal Palace');
      expect(suggestions.single.secondaryText, 'Apollo Bandar, Colaba');
      expect(suggestions.single.fullText, contains('Taj Mahal Palace'));
      expect(suggestions.single.isUsable, isTrue);
    });

    test('drops predictions with an empty place id (unresolvable later)', () {
      final suggestions = parseAutocompleteResponse({
        'predictions': [
          {'placeId': '', 'fullText': 'Somewhere'},
          {'placeId': '  ', 'fullText': 'Also not usable'},
          {'placeId': 'ChIJok', 'fullText': 'Good'},
        ],
      });
      expect(suggestions, hasLength(1));
      expect(suggestions.single.placeId, 'ChIJok');
    });

    test('no primaryText means the full text or id is used as the primary', () {
      final withFull = parseAutocompleteResponse({
        'predictions': [
          {'placeId': 'ChIJa', 'fullText': 'Full Address Line'},
        ],
      });
      expect(withFull.single.primaryText, 'Full Address Line');

      final idOnly = parseAutocompleteResponse({
        'predictions': [
          {'placeId': 'ChIJb'},
        ],
      });
      expect(idOnly.single.primaryText, 'ChIJb');
    });
  });

  group('Places details decoding', () {
    test('decodes coordinates and address from a numeric payload', () {
      final details = parsePlaceDetailsResponse({
        'placeId': 'ChIJx',
        'latitude': 18.9211,
        'longitude': 72.8347,
        'address': 'Bandra West, Mumbai, Maharashtra',
        'name': 'Some Kitchen',
      });
      expect(details, isNotNull);
      expect(details!.latitude, 18.9211);
      expect(details.longitude, 72.8347);
      expect(details.address, 'Bandra West, Mumbai, Maharashtra');
      expect(details.name, 'Some Kitchen');
    });

    test('accepts string-form numbers the native bridge might send', () {
      final details = parsePlaceDetailsResponse({
        'placeId': 'ChIJy',
        'latitude': '18.5',
        'longitude': '73.8',
        'address': 'Pune',
      });
      expect(details, isNotNull);
      expect(details!.latitude, closeTo(18.5, 0.0000001));
      expect(details.longitude, closeTo(73.8, 0.0000001));
    });

    test('rejects a payload with no usable coordinates or no address', () {
      expect(parsePlaceDetailsResponse(null), isNull);
      expect(parsePlaceDetailsResponse({'latitude': 18.5, 'longitude': 73.8}),
          isNull);
      expect(
          parsePlaceDetailsResponse(
              {'latitude': null, 'longitude': 73.8, 'address': 'Pune'}),
          isNull);
      expect(
          parsePlaceDetailsResponse(
              {'latitude': 91, 'longitude': 73.8, 'address': 'Pune'}),
          isNull);
      expect(
          parsePlaceDetailsResponse(
              {'latitude': 18.5, 'longitude': 73.8, 'address': '  '}),
          isNull);
    });

    test('PlaceDetails.hasUsableCoordinates bounds-check is honest', () {
      const ok = PlaceDetails(
          placeId: 'x', latitude: 18.5, longitude: 73.8, address: 'Pune');
      const badLng = PlaceDetails(
          placeId: 'x', latitude: 18.5, longitude: 181, address: 'Pune');
      expect(ok.hasUsableCoordinates, isTrue);
      expect(badLng.hasUsableCoordinates, isFalse);
    });
  });

  group('reverse-geocoding formatting', () {
    test('formats a full placemark into one readable line', () {
      final text = formatPlacemarkAddress(Placemark(
        name: 'Plot 4',
        subThoroughfare: '4',
        thoroughfare: 'MG Road',
        subLocality: 'Shivaji Nagar',
        locality: 'Pune',
        subAdministrativeArea: 'Pune',
        administrativeArea: 'Maharashtra',
        postalCode: '411005',
        country: 'India',
      ));
      expect(text, '4 MG Road, Shivaji Nagar, Pune, Maharashtra 411005, India');
    });

    test('skips missing parts instead of producing ", ,"', () {
      final text = formatPlacemarkAddress(Placemark(locality: 'Pune'));
      expect(text, 'Pune');
    });

    test('falls back to the place name when nothing structured exists', () {
      final text = formatPlacemarkAddress(Placemark(name: 'Gateway of India'));
      expect(text, 'Gateway of India');
    });

    test('empty placemark yields an empty string, never a fabricated address',
        () {
      expect(formatPlacemarkAddress(const Placemark()), '');
    });

    test('placemarkCity prefers locality, then administrative locality', () {
      expect(
        placemarkCity(Placemark(locality: 'Pune')),
        'Pune',
      );
      expect(
        placemarkCity(Placemark(subAdministrativeArea: 'Pune')),
        'Pune',
      );
      expect(placemarkCity(const Placemark()), isNull);
    });
  });

  group('DeliveryOpportunity.fromBackend distance', () {
    test('computes a straight-line distance when pickup and viewer are known',
        () {
      final o = DeliveryOpportunity.fromBackend(
        {'id': 'd1', 'latitude': 18.5204, 'longitude': 73.8567},
        viewerLatitude: 19.0760,
        viewerLongitude: 72.8777,
      );
      expect(o.distanceKm, isNotNull);
      expect(o.distanceKm!, inInclusiveRange(100, 140));
      expect(
          straightLineDistanceLabel(o.distanceKm), contains('straight-line'));
    });

    test('stays null (not 0) when the volunteer location is unknown', () {
      final o = DeliveryOpportunity.fromBackend(
        {'id': 'd2', 'latitude': 18.5204, 'longitude': 73.8567},
      );
      expect(o.distanceKm, isNull);
      // The UI renders an honest dash rather than a fake "0 km".
      expect(straightLineDistanceLabel(o.distanceKm), isNull);
    });

    test('stays null when the delivery row carries no coordinates', () {
      final o = DeliveryOpportunity.fromBackend(
        {'id': 'd3'},
        viewerLatitude: 19.0760,
        viewerLongitude: 72.8777,
      );
      expect(o.distanceKm, isNull);
    });
  });
}
