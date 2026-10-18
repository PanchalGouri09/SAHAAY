import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sahaay/services/api_service.dart';
import 'package:sahaay/services/firebase_auth_service.dart';

/// Contract tests for the orphaned-account auto-adoption flow.
///
/// The resolver itself (match by verified email, re-link only when the old
/// Firebase UID is gone) is exercised end-to-end in the backend suite
/// (`tests/test_profile_adopt.py`). These tests pin the client wiring: a fresh
/// Firebase UID whose SAHAAY row still exists must be restored on login and on
/// an email-conflict, rather than dropping the person back into enrollment.
void main() {
  final api = File('lib/services/api_service.dart').readAsStringSync();
  final auth =
      File('lib/services/firebase_auth_service.dart').readAsStringSync();

  group('ApiService.adoptProfile', () {
    test('targets POST /api/v1/profile/adopt', () {
      expect(api, contains('Future<Map<String, dynamic>> adoptProfile()'));
      expect(api, contains("_request('POST', '/api/v1/profile/adopt')"));
    });
  });

  group('login adoption wiring', () {
    test('an unavailable backend is not treated as a missing profile', () {
      expect(auth, isNot(contains('if (!_api.isConfigured) return null;')));
      expect(auth, contains('await _api.getProfile()'));
    });

    test('_tryAdopt calls the adopt endpoint', () {
      expect(auth, contains('await _api.adoptProfile()'));
    });

    test('unconfigured backend errors do not resolve as a missing profile',
        () async {
      final user = _TestUser();
      final firebase = _TestFirebaseAuth(user);
      final service = FirebaseAuthService(
        auth: firebase,
        api: _UnavailableProfileApi(firebase),
        googleSignIn: _UnusedGoogleSignIn(),
      );

      await expectLater(
        service.authStateChanges,
        emitsError(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            0,
          ),
        ),
      );
    });

    test(
        'a missing profile by UID (404) attempts adoption, not enrollment only',
        () {
      // `_profileForUser` must fall back to `_tryAdopt(user)` on a 404 so a
      // returning person logs straight in.
      expect(auth, contains('return _tryAdopt(user);'));
    });
  });

  group('email-conflict adoption wiring', () {
    test('register re-links on a 409 instead of failing', () {
      expect(auth, contains('error.statusCode == 409'));
      expect(auth, contains('final adopted = await _tryAdopt(user);'));
    });

    test('completeEnrollment re-links on a 409 instead of failing', () {
      // Both create-profile paths guard on 409 and re-link.
      final matches = 'statusCode == 409'.allMatches(auth).length;
      expect(matches, greaterThanOrEqualTo(2),
          reason:
              'register and completeEnrollment must both handle the conflict');
    });
  });
}

class _TestUser implements User {
  @override
  String get uid => 'test-firebase-user';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestFirebaseAuth implements FirebaseAuth {
  _TestFirebaseAuth(this.user);

  final User user;

  @override
  User? get currentUser => user;

  @override
  Stream<User?> authStateChanges() => Stream<User?>.value(user);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnavailableProfileApi extends ApiService {
  _UnavailableProfileApi(FirebaseAuth auth) : super(auth: auth);

  @override
  bool get isConfigured => false;

  @override
  Future<Map<String, dynamic>> getProfile() async {
    throw const ApiException(
        0,
        'The FastAPI backend URL is not configured. Set a valid '
        'API_BASE_URL in sahaay/env.json and rebuild with '
        'sahaay/scripts/build_release.ps1.');
  }
}

class _UnusedGoogleSignIn extends GoogleSignIn {}
