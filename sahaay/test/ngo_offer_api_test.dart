import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sahaay/services/api_service.dart';

class _FakeUser extends Fake implements User {
  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => 'test-token';
}

class _FakeFirebaseAuth extends Fake implements FirebaseAuth {
  final User _user = _FakeUser();

  @override
  User? get currentUser => _user;
}

void main() {
  group('NGO offer API response', () {
    test('returns offers from the backend list response', () async {
      final api = ApiService(
        auth: _FakeFirebaseAuth(),
        client: MockClient((request) async {
          expect(request.url.path, '/api/v1/donation-offers');
          return http.Response(
            jsonEncode([
              {'id': 'offer-1', 'status': 'pending'},
            ]),
            200,
          );
        }),
      );

      final result = await api.getNgoDonationOffers();

      expect(result, [
        {'id': 'offer-1', 'status': 'pending'},
      ]);
    });

    test('rejects a malformed success payload instead of reporting no offers',
        () async {
      final api = ApiService(
        auth: _FakeFirebaseAuth(),
        client: MockClient((_) async {
          return http.Response(
            jsonEncode({
              'data': {'unexpected': 'shape'}
            }),
            200,
          );
        }),
      );

      await expectLater(
        api.getNgoDonationOffers(),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
