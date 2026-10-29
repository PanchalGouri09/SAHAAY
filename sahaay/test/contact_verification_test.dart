import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sahaay/services/firebase_auth_service.dart';

void main() {
  group('Firebase phone-auth errors', () {
    test('invalid OTP and expired OTP have actionable messages', () {
      expect(
        FirebaseAuthService.phoneAuthErrorMessage('invalid-verification-code'),
        contains('incorrect'),
      );
      expect(
        FirebaseAuthService.phoneAuthErrorMessage('session-expired'),
        contains('expired'),
      );
    });

    test('account-link conflicts never imply success or a sign-out', () {
      final message = FirebaseAuthService.phoneAuthErrorMessage(
        'credential-already-in-use',
      );
      expect(message, contains('different Firebase account'));
      expect(message, contains('remains signed in'));
    });

    test('quota, throttling, configuration, and network failures are distinct',
        () {
      expect(
        FirebaseAuthService.phoneAuthErrorMessage('quota-exceeded'),
        contains('quota'),
      );
      expect(
        FirebaseAuthService.phoneAuthErrorMessage('too-many-requests'),
        contains('Wait'),
      );
      expect(
        FirebaseAuthService.phoneAuthErrorMessage('operation-not-allowed'),
        contains('not enabled'),
      );
      expect(
        FirebaseAuthService.phoneAuthErrorMessage('network-request-failed'),
        contains('Network connection failed'),
      );
    });
  });

  group('Firebase phone linking account binding', () {
    test('a code cannot be linked after the Firebase account changes',
        () async {
      final user = _PhoneUser('account-a');
      final auth = _PhoneAuth(user);
      final service = FirebaseAuthService(auth: auth);

      await expectLater(
        service.verifyAndLinkPhoneCode(
          verificationId: 'verification-id',
          smsCode: '123456',
          expectedFirebaseUserId: 'account-b',
        ),
        throwsA(isA<AuthException>().having(
          (error) => error.message,
          'message',
          contains('account changed'),
        )),
      );
      expect(user.linkCalls, 0);
    });

    test('successful verification links the phone to the initiating user',
        () async {
      final user = _PhoneUser('account-a');
      final auth = _PhoneAuth(user);
      final service = FirebaseAuthService(auth: auth);

      final phone = await service.verifyAndLinkPhoneCode(
        verificationId: 'verification-id',
        smsCode: '123456',
        expectedFirebaseUserId: 'account-a',
      );

      expect(phone, '+919876543210');
      expect(user.linkCalls, 1);
      expect(user.forceRefreshTokenCalls, 1);
      expect(auth.currentUser?.uid, 'account-a');
    });

    test('a failed verification does not report a linked phone', () async {
      final user = _PhoneUser(
        'account-a',
        onLink: (_) async => throw FirebaseAuthException(
          code: 'invalid-verification-code',
        ),
      );
      final service = FirebaseAuthService(auth: _PhoneAuth(user));

      await expectLater(
        service.verifyAndLinkPhoneCode(
          verificationId: 'verification-id',
          smsCode: '000000',
          expectedFirebaseUserId: 'account-a',
        ),
        throwsA(isA<AuthException>().having(
          (error) => error.message,
          'message',
          contains('incorrect'),
        )),
      );
      expect(user.phoneNumber, isNull);
    });

    test('linking never replaces a different Firebase account', () async {
      final original = _PhoneUser('account-a');
      final switched = _PhoneUser('account-b');
      final auth = _PhoneAuth(original);
      original.onLink = (_) async {
        auth.user = switched;
        original.phoneNumber = '+919876543210';
        return _PhoneCredential(original);
      };
      final service = FirebaseAuthService(auth: auth);

      await expectLater(
        service.verifyAndLinkPhoneCode(
          verificationId: 'verification-id',
          smsCode: '123456',
          expectedFirebaseUserId: 'account-a',
        ),
        throwsA(isA<AuthException>().having(
          (error) => error.message,
          'message',
          contains('account changed'),
        )),
      );
      expect(auth.currentUser?.uid, 'account-b');
    });
  });
}

class _PhoneAuth implements FirebaseAuth {
  _PhoneAuth(this.user);

  User? user;

  @override
  User? get currentUser => user;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PhoneUser implements User {
  _PhoneUser(this.uid, {this.onLink});

  @override
  final String uid;
  @override
  String? phoneNumber;
  int linkCalls = 0;
  int forceRefreshTokenCalls = 0;
  Future<UserCredential> Function(AuthCredential)? onLink;

  @override
  Future<UserCredential> linkWithCredential(AuthCredential credential) {
    linkCalls++;
    final link = onLink;
    if (link != null) return link(credential);
    phoneNumber = '+919876543210';
    return Future.value(_PhoneCredential(this));
  }

  @override
  Future<void> reload() async {}

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    if (forceRefresh) forceRefreshTokenCalls++;
    return 'test-token';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PhoneCredential implements UserCredential {
  _PhoneCredential(this.user);

  @override
  final User user;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
