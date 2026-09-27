import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'api_service.dart';

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

  const AuthProfile({
    required this.uid,
    required this.email,
    required this.role,
    required this.fullName,
    required this.orgLabel,
  });
}

class FirebaseAuthService {
  final FirebaseAuth _auth;
  final ApiService _api;
  final GoogleSignIn _googleSignIn;

  FirebaseAuthService({FirebaseAuth? auth, ApiService? api, GoogleSignIn? googleSignIn})
      : _auth = auth ?? FirebaseAuth.instance,
        _api = api ?? ApiService(auth: auth ?? FirebaseAuth.instance),
        _googleSignIn = googleSignIn ?? GoogleSignIn();

  ApiService get api => _api;

  bool get hasFirebaseUser => _auth.currentUser != null;

  Stream<AuthProfile?> get authStateChanges => _auth.authStateChanges().asyncMap(_profileForUser);

  Future<AuthProfile?> get currentProfile => _profileForUser(_auth.currentUser);

  Future<String?> getIdToken() async => await _auth.currentUser?.getIdToken();

  Future<AuthProfile> signIn({required String email, required String password}) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      return _loadBackendProfile(credential.user);
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

  Future<void> signOut() => _auth.signOut();

  Future<AuthProfile?> _profileForUser(User? user) async {
    if (user == null) return null;
    if (!_api.isConfigured) return null;
    try {
      return _profileFromBackend(await _api.getProfile(), user);
    } on ApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<AuthProfile> _loadBackendProfile(User? user) async {
    if (user == null) throw const AuthException('Firebase did not return a user account.');
    try {
      return _profileFromBackend(await _api.getProfile(), user);
    } on ApiException catch (error) {
      throw AuthException(error.message);
    }
  }

  AuthProfile _profileFromBackend(Map<String, dynamic> data, User user) {
    final role = data['role']?.toString();
    if (role == null || !{'provider', 'ngo', 'volunteer', 'admin'}.contains(role)) {
      throw const AuthException('Your SAHAAY profile has no valid role.');
    }
    final profile = data['profile'];
    final profileMap = profile is Map<String, dynamic> ? profile : null;
    return AuthProfile(
      uid: user.uid,
      email: data['email']?.toString() ?? user.email ?? '',
      role: role,
      fullName: data['full_name']?.toString() ?? user.displayName ?? '',
      orgLabel: profileMap?['organization_name']?.toString() ?? data['full_name']?.toString() ?? '',
    );
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
        return 'Too many attempts. Please try again later.';
      default:
        return error.message ?? 'Something went wrong. Please try again.';
    }
  }
}
