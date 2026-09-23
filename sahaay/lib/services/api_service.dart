import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

class ApiException implements Exception {
  final int statusCode;
  final String message;
  const ApiException(this.statusCode, this.message);

  @override
  String toString() => message;
}

class ApiService {
  final FirebaseAuth _auth;
  final http.Client _client;
  static const _baseUrl = String.fromEnvironment('API_BASE_URL');

  ApiService({FirebaseAuth? auth, http.Client? client})
      : _auth = auth ?? FirebaseAuth.instance,
        _client = client ?? http.Client();

  bool get isConfigured => _baseUrl.isNotEmpty && !_baseUrl.contains('your-fastapi-host');

  Future<Map<String, dynamic>> getProfile() => _request('GET', '/api/v1/profile');

  Future<Map<String, dynamic>> createProfile(Map<String, dynamic> payload) =>
      _request('POST', '/api/v1/profile', body: payload);

  Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> payload) =>
      _request('PATCH', '/api/v1/profile', body: payload);

  Future<List<dynamic>> getDonations() async {
    final response = await _request('GET', '/api/v1/donations');
    return response['data'] is List ? response['data'] as List<dynamic> : <dynamic>[];
  }

  Future<Map<String, dynamic>> createDonation(Map<String, dynamic> payload) =>
      _request('POST', '/api/v1/donations', body: payload);

  /// Uploads a food photo through the authenticated backend boundary and
  /// returns the persistent public URL to attach to the donation.
  Future<String> uploadDonationImage(File file) async {
    if (!isConfigured) {
      throw const ApiException(0, 'The FastAPI backend URL is not configured.');
    }
    final user = _auth.currentUser;
    final token = await user?.getIdToken();
    if (token == null || token.isEmpty) {
      throw const ApiException(401, 'You must be signed in to use SAHAAY.');
    }
    final request =
        await buildUploadRequest(baseUrl: _baseUrl, token: token, file: file);
    final response = await _client.send(request);
    final text = await response.stream.bytesToString();
    dynamic decoded;
    if (text.isNotEmpty) {
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        decoded = null;
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map<String, dynamic> ? decoded['detail'] : null;
      throw ApiException(response.statusCode,
          detail?.toString() ?? 'Food photo upload failed.');
    }
    final url = decoded is Map<String, dynamic> ? decoded['food_image_url'] : null;
    if (url is! String || url.isEmpty) {
      throw ApiException(
          response.statusCode, 'Backend did not return an image URL.');
    }
    return url;
  }

  /// Resolves the correct `image/*` content type from the selected file's
  /// extension. This is what makes PNG/JPG/JPEG uploads valid regardless of any
  /// empty or cache-generated path the image picker may hand us.
  @visibleForTesting
  static String mimeForPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      default:
        return 'application/octet-stream';
    }
  }

  /// Builds the authenticated multipart request used to upload a food photo.
  /// The filename and MIME content type are derived from the actual file so the
  /// backend can validate PNG/JPG/JPEG correctly.
  @visibleForTesting
  static Future<http.MultipartRequest> buildUploadRequest({
    required String baseUrl,
    required String token,
    required File file,
  }) async {
    final mime = mimeForPath(file.path);
    final filename = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : 'photo';
    return http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/v1/donations/upload'),
    )
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(await http.MultipartFile.fromPath(
        'file',
        file.path,
        filename: filename,
        contentType: MediaType.parse(mime),
      ));
  }

  Future<Map<String, dynamic>> getDonation(String donationId) =>
      _request('GET', '/api/v1/donations/$donationId');

  Future<List<dynamic>> getClaims() async {
    final response = await _request('GET', '/api/v1/claims');
    return response['data'] is List ? response['data'] as List<dynamic> : <dynamic>[];
  }

  Future<Map<String, dynamic>> createClaim(Map<String, dynamic> payload) =>
      _request('POST', '/api/v1/claims', body: payload);

  Future<List<dynamic>> getDeliveries() async {
    final response = await _request('GET', '/api/v1/deliveries');
    return response['data'] is List ? response['data'] as List<dynamic> : <dynamic>[];
  }

  Future<Map<String, dynamic>> updateDeliveryStatus(
    String deliveryId,
    Map<String, dynamic> payload,
  ) =>
      _request('PATCH', '/api/v1/deliveries/$deliveryId/status', body: payload);

  Future<List<dynamic>> getNotifications() async {
    final response = await _request('GET', '/api/v1/notifications');
    return response['data'] is List ? response['data'] as List<dynamic> : <dynamic>[];
  }

  Future<Map<String, dynamic>> markNotificationRead(String notificationId) =>
      _request('PATCH', '/api/v1/notifications/$notificationId/read');

  /// NGO Matching — returns the AI service's ranked NGO list for a donation
  /// (or an `insufficient_data`/`no_candidates` status when not integrable).
  Future<Map<String, dynamic>> matchDonation(String donationId) =>
      _request('POST', '/api/v1/donations/$donationId/match');

  /// Auto-Escalation — asks the AI service whether the current claim has timed
  /// out and, if so, escalates to the next ranked NGO on the backend.
  Future<Map<String, dynamic>> checkEscalation(String donationId) =>
      _request('POST', '/api/v1/donations/$donationId/escalation-check');

  /// Provider Reliability — AI-computed trust score from real history.
  Future<Map<String, dynamic>> getReliability() =>
      _request('GET', '/api/v1/providers/me/reliability');

  /// Asks the AI service to generate the donation completion acknowledgment PDF
  /// and returns the raw bytes, ready to be saved.
  Future<List<int>> generateAcknowledgment(String donationId) async {
    final bytes = await _rawRequest(
      'POST',
      '/api/v1/donations/$donationId/acknowledgment/generate',
    );
    if (bytes.isEmpty) {
      throw const ApiException(
          0, 'The acknowledgment PDF came back empty from the backend.');
    }
    return bytes;
  }

  /// Downloads the already-generated acknowledgment PDF for a donation.
  Future<List<int>> downloadAcknowledgment(String donationId) async {
    final bytes = await _rawRequest(
      'GET',
      '/api/v1/donations/$donationId/acknowledgment',
    );
    if (bytes.isEmpty) {
      throw const ApiException(
          0, 'The acknowledgment PDF came back empty from the backend.');
    }
    return bytes;
  }

  /// Same auth guard as [_request] but returns the raw response bytes. Used
  /// when the response is a binary PDF instead of JSON.
  Future<List<int>> _rawRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (!isConfigured) {
      throw const ApiException(0, 'The FastAPI backend URL is not configured.');
    }
    final user = _auth.currentUser;
    final token = await user?.getIdToken();
    if (token == null || token.isEmpty) {
      throw const ApiException(401, 'You must be signed in to use SAHAAY.');
    }
    final request = http.Request(method, Uri.parse('$_baseUrl$path'))
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      });
    if (body != null) request.body = jsonEncode(body);
    final response = await _client.send(request);
    final bytes = await response.stream.toBytes();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String detail = 'Backend request failed.';
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map<String, dynamic> && decoded['detail'] != null) {
          detail = decoded['detail'].toString();
        }
      } catch (_) {
        // Non-JSON error body — keep the generic message.
      }
      throw ApiException(response.statusCode, detail);
    }
    return bytes;
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (!isConfigured) {
      throw const ApiException(0, 'The FastAPI backend URL is not configured.');
    }
    final user = _auth.currentUser;
    final token = await user?.getIdToken();
    if (token == null || token.isEmpty) {
      throw const ApiException(401, 'You must be signed in to use SAHAAY.');
    }
    final request = http.Request(method, Uri.parse('$_baseUrl$path'))
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      });
    if (body != null) request.body = jsonEncode(body);
    final response = await _client.send(request);
    final text = await response.stream.bytesToString();
    dynamic decoded;
    if (text.isNotEmpty) {
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        decoded = null;
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map<String, dynamic> ? decoded['detail'] : null;
      throw ApiException(response.statusCode, detail?.toString() ?? 'Backend request failed.');
    }
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{'data': decoded};
  }
}
