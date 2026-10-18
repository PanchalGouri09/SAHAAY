import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:sahaay/services/firebase_auth_service.dart';

/// In-memory Firebase core so `FirebaseAuth.instance` resolves inside the test
/// with no real project, network call or platform channel (same technique as
/// startup_login_test.dart).
class _FakeFirebaseCorePlatform extends FirebasePlatform {
  final _app = FirebaseAppPlatform(
    defaultFirebaseAppName,
    const FirebaseOptions(
      apiKey: 'test-api-key',
      appId: 'test-app-id',
      messagingSenderId: 'test-sender-id',
      projectId: 'test-project',
    ),
  );

  @override
  List<FirebaseAppPlatform> get apps => [_app];

  @override
  FirebaseAppPlatform app([String name = defaultFirebaseAppName]) => _app;

  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async =>
      _app;
}

/// Records the order of the two Google calls the service makes. Returning null
/// from `signIn` reproduces the user cancelling the chooser, so the flow stops
/// right after the chooser is shown - no Firebase or backend call happens.
class _RecordingGoogleSignIn extends GoogleSignIn {
  final List<String> calls = <String>[];

  @override
  Future<GoogleSignInAccount?> signIn() async {
    calls.add('signIn');
    return null;
  }

  @override
  Future<GoogleSignInAccount?> signOut() async {
    calls.add('signOut');
    return null;
  }
}

void main() {
  setUpAll(() {
    FirebasePlatform.instance = _FakeFirebaseCorePlatform();
  });

  test(
      'Google sign-in clears the cached account before showing the chooser, '
      'so the picker appears on every tap', () async {
    final google = _RecordingGoogleSignIn();
    final service = FirebaseAuthService(googleSignIn: google);

    final result = await service.signInWithGoogle();

    expect(result, isNull); // cancelled at the chooser
    expect(google.calls, <String>['signOut', 'signIn'],
        reason: 'signOut() must precede signIn() to force the account chooser');
  });
}
