import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'api_service.dart';
import 'profile_completion.dart';

typedef PhoneCodeSentCallback = void Function(
    String verificationId, int? resendToken);
typedef PhoneVerifiedCallback = void Function(String phoneNumber);
typedef PhoneVerificationErrorCallback = void Function(String message);

class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => message;
}

class AuthProfile {
  final String uid;
  final String email;
  final String role;
  final String fullName;
  final String orgLabel;
  final ProfileCompletion? profileCompletion;

  /// Real WGS-84 location of the signed-in organization, read from the role
  /// profile join on `GET /profile`. Null whenever no coordinate was stored.
  final double? latitude;
  final double? longitude;

  /// Whether the signed-in user opted their organization into the public
  /// leaderboard (`users.leaderboard_public`, which defaults to false).
  final bool leaderboardPublic;

  /// The saved profile photo URL (`users.profile_image_url`), so every avatar
  /// in the app can show the real picture instead of a default icon. Null when
  /// the account has not uploaded one.
  final String? profileImageUrl;

  const AuthProfile({
    required this.uid,
    required this.email,
    required this.role,
    required this.fullName,
    required this.orgLabel,
    this.profileCompletion,
    this.latitude,
    this.longitude,
    this.leaderboardPublic = false,
    this.profileImageUrl,
  });
}

class FirebaseAuthService {
  final FirebaseAuth _auth;
  final ApiService _api;
  final GoogleSignIn _googleSignIn;

  FirebaseAuthService(
      {FirebaseAuth? auth, ApiService? api, GoogleSignIn? googleSignIn})
      : _auth = auth ?? FirebaseAuth.instance,
        _api = api ?? ApiService(auth: auth ?? FirebaseAuth.instance),
        _googleSignIn = googleSignIn ?? GoogleSignIn();

  ApiService get api => _api;

  bool get hasFirebaseUser => _auth.currentUser != null;

  String? get currentFirebaseUserId => _auth.currentUser?.uid;

  Stream<AuthProfile?> get authStateChanges =>
      _auth.authStateChanges().asyncMap(_profileForUser);

  Future<AuthProfile?> get currentProfile => _profileForUser(_auth.currentUser);

  Future<String?> getIdToken() async => await _auth.currentUser?.getIdToken();

  Future<AuthProfile> signIn(
      {required String email, required String password}) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      return await _loadBackendProfile(credential.user);
    } on FirebaseAuthException catch (error) {
      throw AuthException(_messageFor(error));
    }
  }

  Future<AuthProfile> register({
    required String email,
    required String password,
    required String role,
    required String fullName,
    required String orgLabel,
    String? phone,
    Map<String, dynamic>? roleProfile,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        throw const AuthException('Firebase did not return a user account.');
      }

      await user.updateDisplayName(fullName);
      try {
        final response = await _api.createProfile({
          'full_name': fullName,
          'email': user.email ?? email.trim(),
          'phone': phone,
          'role': role,
          if (role == 'provider') 'provider': roleProfile,
          if (role == 'ngo') 'ngo': roleProfile,
          if (role == 'volunteer') 'volunteer': roleProfile,
        });
        return _profileFromBackend(response, user);
      } catch (error) {
        // The verified email may already own a SAHAAY account whose Firebase
        // user was deleted (the orphan case). Re-link and sign in rather than
        // rejecting the person from an account that already exists.
        if (error is ApiException && error.statusCode == 409) {
          try {
            final adopted = await _tryAdopt(user);
            if (adopted != null) return adopted;
          } on AuthException {
            // Email belongs to a still-active account: fall through to the
            // original conflict so no stray Firebase user is left behind.
          }
        }
        await user.delete();
        if (error is ApiException) throw AuthException(error.message);
        rethrow;
      }
    } on FirebaseAuthException catch (error) {
      throw AuthException(_messageFor(error));
    }
  }

  /// Google OAuth flow: Google account -> Firebase credential -> backend profile.
  ///
  /// Returns `null` when the user cancels the Google picker, or when Firebase
  /// authentication succeeds but the user has no SAHAAY `users` row yet
  /// (a brand-new Google user — the caller must then run the enrollment flow).
  /// Identity is always re-derrived server-side from the verified Firebase
  /// token; no firebase_uid is ever sent from the client.
  Future<AuthProfile?> signInWithGoogle() async {
    try {
      // Force the account chooser on EVERY tap. google_sign_in silently reuses
      // the last-used account otherwise, so a user could never switch Google
      // accounts from the login screen. This clears only the cached Google
      // OAuth session; the Firebase session is untouched until the credential
      // below succeeds, and choosing an already-enrolled account still logs
      // straight in (GET /profile resolves its stored role - no duplicate).
      await _googleSignIn.signOut();
      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) return null; // user cancelled the picker
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final userCredential = await _auth.signInWithCredential(credential);
      return await _profileForUser(userCredential.user);
    } on FirebaseAuthException catch (error) {
      throw AuthException(_messageFor(error));
    } on ApiException catch (error) {
      if (error.statusCode == 404) return null;
      throw AuthException(error.message);
    } on AuthException {
      rethrow; // preserve the specific adoption conflict message
    } catch (_) {
      throw const AuthException('Google sign-in failed. Please try again.');
    }
  }

  /// Completes the SAHAAY profile for an already-Firebase-authenticated user
  /// (Google first-time enrollment). Reuses POST /api/v1/profile with the
  /// authenticated session token, exactly like email/password registration.
  ///
  /// Unlike email/password registration, the Firebase account is NOT deleted
  /// on failure — the Google identity is owned by Google, and rolling it back
  /// could orphan a real user account. The caller surfaces the error instead.
  Future<AuthProfile> completeEnrollment({
    required String role,
    required String fullName,
    required String orgLabel,
    String? phone,
    Map<String, dynamic>? roleProfile,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthException('Your session expired. Please log in again.');
    }
    try {
      final response = await _api.createProfile({
        'full_name': fullName,
        'email': user.email ?? '',
        'phone': phone,
        'role': role,
        if (role == 'provider') 'provider': roleProfile,
        if (role == 'ngo') 'ngo': roleProfile,
        if (role == 'volunteer') 'volunteer': roleProfile,
      });
      return _profileFromBackend(response, user);
    } on ApiException catch (error) {
      // Google enrollment can also collide with an orphaned SAHAAY row that
      // still holds this verified email. Adopt it instead of dead-ending.
      if (error.statusCode == 409) {
        final adopted = await _tryAdopt(user);
        if (adopted != null) return adopted;
      }
      throw AuthException(error.message);
    }
  }

  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (error) {
      throw AuthException(_messageFor(error));
    }
  }

  Future<bool> sendEmailVerification() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthException('Your session expired. Please log in again.');
    }
    if (user.emailVerified) return false;
    try {
      await user.sendEmailVerification();
      return true;
    } on FirebaseAuthException catch (error) {
      throw AuthException(_messageFor(error));
    }
  }

  Future<void> reloadCurrentUser() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthException('Your session expired. Please log in again.');
    }
    await user.reload();
    if (_auth.currentUser?.uid != user.uid) {
      throw const AuthException(
          'Your signed-in account changed. Refresh the page and try again.');
    }
    await user.getIdToken(true);
  }

  Future<void> startPhoneVerification({
    required String phoneNumber,
    int? forceResendingToken,
    required PhoneCodeSentCallback onCodeSent,
    required PhoneVerifiedCallback onVerified,
    required PhoneVerificationErrorCallback onFailure,
    required PhoneVerificationErrorCallback onTimeout,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthException('Your session expired. Please log in again.');
    }
    if (user.phoneNumber != null) {
      onFailure(
        'A phone number is already linked to this account. Refresh status or contact support before changing it.',
      );
      return;
    }
    final initiatingUid = user.uid;
    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        timeout: const Duration(seconds: 60),
        forceResendingToken: forceResendingToken,
        verificationCompleted: (credential) async {
          try {
            final linked = await _linkPhoneCredential(user, credential);
            if (_auth.currentUser?.uid != initiatingUid ||
                linked.uid != initiatingUid) {
              onFailure(
                  'Your signed-in account changed. Refresh the page and try again.');
              return;
            }
            onVerified(linked.phoneNumber ?? phoneNumber);
          } on FirebaseAuthException catch (error) {
            onFailure(_phoneMessageFor(error));
          } on AuthException catch (error) {
            onFailure(error.message);
          }
        },
        verificationFailed: (error) => onFailure(_phoneMessageFor(error)),
        codeSent: onCodeSent,
        codeAutoRetrievalTimeout: (verificationId) => onTimeout(verificationId),
      );
    } on FirebaseAuthException catch (error) {
      onFailure(_phoneMessageFor(error));
    }
  }

  Future<String> verifyAndLinkPhoneCode({
    required String verificationId,
    required String smsCode,
    required String expectedFirebaseUserId,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthException('Your session expired. Please log in again.');
    }
    if (user.uid != expectedFirebaseUserId) {
      throw const AuthException(
          'Your signed-in account changed. Request a new verification code.');
    }
    if (user.phoneNumber != null && user.phoneNumber!.isNotEmpty) {
      throw const AuthException(
        'A phone number is already linked to this account. Refresh status or contact support before changing it.',
      );
    }
    final credential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: smsCode.trim(),
    );
    try {
      final linked = await _linkPhoneCredential(user, credential);
      if (_auth.currentUser?.uid != expectedFirebaseUserId ||
          linked.uid != expectedFirebaseUserId) {
        throw const AuthException(
            'Your signed-in account changed. Refresh the page and try again.');
      }
      return linked.phoneNumber ??
          (throw const AuthException(
              'Firebase linked the phone credential but did not return its number.'));
    } on FirebaseAuthException catch (error) {
      throw AuthException(_phoneMessageFor(error));
    }
  }

  Future<User> _linkPhoneCredential(
      User user, AuthCredential credential) async {
    if (_auth.currentUser?.uid != user.uid) {
      throw const AuthException(
          'Your signed-in account changed. Request a new verification code.');
    }
    if (user.phoneNumber != null && user.phoneNumber!.isNotEmpty) {
      throw const AuthException(
        'A phone number is already linked to this account. Refresh status or contact support before changing it.',
      );
    }
    try {
      final linked = await user.linkWithCredential(credential);
      final updatedUser = linked.user ??
          (throw const AuthException(
              'Firebase did not return the signed-in account after linking.'));
      if (updatedUser.uid != user.uid) {
        throw const AuthException(
            'Firebase returned a different account after phone verification.');
      }
      return updatedUser;
    } on FirebaseAuthException catch (error) {
      if (error.code == 'provider-already-linked') {
        await user.reload();
        throw const AuthException(
          'A phone number is already linked to this account. Refresh status or contact support before changing it.',
        );
      }
      rethrow;
    }
  }

  Future<void> signOut() => _auth.signOut();

  Future<AuthProfile?> _profileForUser(User? user) async {
    if (user == null) return null;
    try {
      return _profileFromBackend(await _api.getProfile(), user);
    } on ApiException catch (error) {
      if (error.statusCode == 404) return _tryAdopt(user);
      rethrow;
    }
  }

  /// Attempts to restore an existing SAHAAY account whose Firebase user was
  /// replaced (new UID, same verified email). Returns the restored profile, or
  /// null when there is genuinely no existing account (the caller should then
  /// enroll as a brand-new user). A 409 means the email belongs to a still
  /// active account, which is surfaced rather than silently swallowed.
  Future<AuthProfile?> _tryAdopt(User user) async {
    try {
      return _profileFromBackend(await _api.adoptProfile(), user);
    } on ApiException catch (error) {
      if (error.statusCode == 404) return null;
      throw AuthException(error.message);
    }
  }

  Future<AuthProfile> _loadBackendProfile(User? user) async {
    if (user == null) {
      throw const AuthException('Firebase did not return a user account.');
    }
    try {
      return _profileFromBackend(await _api.getProfile(), user);
    } on ApiException catch (error) {
      if (error.statusCode == 404) {
        final adopted = await _tryAdopt(user);
        if (adopted != null) return adopted;
      }
      throw AuthException(error.message);
    }
  }

  AuthProfile _profileFromBackend(Map<String, dynamic> data, User user) {
    final role = data['role']?.toString();
    if (role == null ||
        !{'provider', 'ngo', 'volunteer', 'admin'}.contains(role)) {
      throw const AuthException('Your SAHAAY profile has no valid role.');
    }
    final profile = data['profile'];
    final profileMap = _profileMap(profile);
    final completionValue = data['profile_completion'];
    final completionMap = completionValue is Map
        ? Map<String, dynamic>.from(completionValue)
        : null;
    return AuthProfile(
      uid: user.uid,
      email: data['email']?.toString() ?? user.email ?? '',
      role: role,
      fullName: data['full_name']?.toString() ?? user.displayName ?? '',
      orgLabel: profileMap?['organization_name']?.toString() ??
          data['full_name']?.toString() ??
          '',
      profileCompletion: completionMap == null
          ? ProfileCompletion.calculate(
              role: role,
              account: data,
              roleProfile: profileMap ?? const <String, dynamic>{},
            )
          : ProfileCompletion.fromBackend(completionMap),
      latitude: _coordinate(profileMap?['latitude'], maxAbs: 90),
      longitude: _coordinate(profileMap?['longitude'], maxAbs: 180),
      leaderboardPublic: data['leaderboard_public'] == true,
      profileImageUrl: _nonEmpty(data['profile_image_url']) ??
          _nonEmpty(profileMap?['profile_image_url']),
    );
  }

  static Map<String, dynamic>? _profileMap(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is List && value.isNotEmpty && value.first is Map) {
      return Map<String, dynamic>.from(value.first as Map);
    }
    return null;
  }

  /// Defensive WGS-84 coordinate parse: accepts a [num] or numeric [String]
  /// and drops anything absent, non-numeric or out of range to null.
  static double? _coordinate(dynamic raw, {required double maxAbs}) {
    if (raw == null) return null;
    final value = raw is num ? raw.toDouble() : double.tryParse(raw.toString());
    if (value == null || !value.isFinite || value.abs() > maxAbs) return null;
    return value;
  }

  /// Trimmed non-empty string, or null for blank/missing values, so an absent
  /// photo URL never renders as an empty avatar image.
  static String? _nonEmpty(dynamic raw) {
    final text = raw?.toString().trim();
    return (text == null || text.isEmpty) ? null : text;
  }

  String _messageFor(FirebaseAuthException error) {
    switch (error.code) {
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'user-not-found':
      case 'invalid-credential':
        return 'Incorrect email or password.';
      case 'wrong-password':
        return 'Incorrect email or password.';
      case 'email-already-in-use':
        return 'An account already exists with this email.';
      case 'weak-password':
        return 'Password must be at least 6 characters.';
      case 'network-request-failed':
        return 'Network connection failed. Please try again.';
      case 'too-many-requests':
        return 'Too many attempts. Firebase has temporarily limited requests. Please wait and try again.';
      case 'requires-recent-login':
        return 'Your session expired. Sign in again, then retry verification.';
      case 'operation-not-allowed':
        return 'This verification method is not enabled for the SAHAAY Firebase project.';
      default:
        return error.message ?? 'Something went wrong. Please try again.';
    }
  }

  String _phoneMessageFor(FirebaseAuthException error) {
    return phoneAuthErrorMessage(error.code, error.message);
  }

  static String phoneAuthErrorMessage(String code, [String? firebaseMessage]) {
    switch (code) {
      case 'invalid-phone-number':
        return 'Enter a valid phone number with its country code.';
      case 'invalid-verification-code':
        return 'That OTP is incorrect. Check the SMS and try again.';
      case 'session-expired':
        return 'That OTP has expired. Request a new code and try again.';
      case 'quota-exceeded':
        return 'Firebase SMS quota is exhausted. Please try again later.';
      case 'too-many-requests':
        return 'Too many OTP requests. Wait before requesting another code.';
      case 'credential-already-in-use':
        return 'This phone is linked to a different Firebase account. Your current account remains signed in.';
      case 'provider-already-linked':
        return 'A phone number is already linked to this account.';
      case 'operation-not-allowed':
        return 'Phone sign-in is not enabled for the SAHAAY Firebase project.';
      case 'network-request-failed':
        return 'Network connection failed. Check your connection and retry.';
      case 'requires-recent-login':
        return 'Your session expired. Sign in again, then retry phone verification.';
      default:
        return firebaseMessage ??
            'Phone verification failed. Check the number and try again.';
    }
  }
}
