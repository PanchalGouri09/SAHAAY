import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
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
  static const _placesMethodChannel = MethodChannel('sahaay/places');
  static const _configurationError =
      'The FastAPI backend URL is not configured. Set a valid '
      'API_BASE_URL in sahaay/env.json and rebuild with '
      'sahaay/scripts/build_release.ps1.';

  ApiService({FirebaseAuth? auth, http.Client? client})
      : _auth = auth ?? FirebaseAuth.instance,
        _client = client ?? http.Client();

  bool get isConfigured => _configuredBaseUrl != null;

  String? get _configuredBaseUrl {
    if (!isValidBaseUrl(_baseUrl)) return null;
    return _baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  }

  @visibleForTesting
  static bool isValidBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        trimmed != value ||
        trimmed.contains(RegExp(r'\s'))) {
      return false;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    final host = uri.host.toLowerCase();
    final address = InternetAddress.tryParse(host);
    return host != 'localhost' &&
        !host.endsWith('.localhost') &&
        host != 'example.com' &&
        !host.endsWith('.example.com') &&
        !host.contains('your-fastapi-host') &&
        !host.contains('your-project') &&
        host != '0.0.0.0' &&
        host != '::' &&
        address?.isLoopback != true;
  }

  String _requireBaseUrl() {
    final baseUrl = _configuredBaseUrl;
    if (baseUrl == null) throw const ApiException(0, _configurationError);
    return baseUrl;
  }

  Future<Map<String, dynamic>> getProfile() =>
      _request('GET', '/api/v1/profile');

  Future<Map<String, dynamic>> createProfile(Map<String, dynamic> payload) =>
      _request('POST', '/api/v1/profile', body: payload);

  /// Restores an existing SAHAAY account to the signed-in Firebase identity.
  ///
  /// Used when the Firebase user was re-created (new UID) but the SAHAAY row
  /// still exists for the same verified email: the backend re-links the row to
  /// the new UID and returns the profile, so the person logs straight in
  /// instead of being pushed into enrollment and hitting an email conflict.
  /// Throws a 404 [ApiException] when there is genuinely no account to restore.
  Future<Map<String, dynamic>> adoptProfile() =>
      _request('POST', '/api/v1/profile/adopt');

  Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> payload) =>
      _request('PATCH', '/api/v1/profile', body: payload);

  /// Sets the signed-in NGO's pickup-vehicle availability.
  ///
  /// Three-state: `true` = has a vehicle, `false` = explicitly none, `null` =
  /// clear the answer back to "not answered". The body carries no NGO id, so
  /// the backend resolves the row from the Firebase token.
  Future<Map<String, dynamic>> setNgoVehicleAvailability(bool? available) =>
      _request('PATCH', '/api/v1/profile/ngo/vehicle-availability',
          body: <String, dynamic>{'vehicle_available': available});

  /// Sets or clears the signed-in provider's pickup-vehicle availability.
  ///
  /// Tri-state, exactly like the NGO variant: `true` = has a vehicle, `false` =
  /// explicitly none, `null` = clear back to "not answered". The body carries no
  /// provider id, so the backend resolves the row from the Firebase token and a
  /// client cannot address another provider's record.
  Future<Map<String, dynamic>> setProviderVehicleAvailability(
          bool? available) =>
      _request('PATCH', '/api/v1/profile/provider/vehicle-availability',
          body: <String, dynamic>{'vehicle_available': available});

  Future<List<dynamic>> getDonations() async {
    final response = await _request('GET', '/api/v1/donations');
    return response['data'] is List
        ? response['data'] as List<dynamic>
        : <dynamic>[];
  }

  Future<Map<String, dynamic>> createDonation(Map<String, dynamic> payload) =>
      _request('POST', '/api/v1/donations', body: payload);

  Future<Map<String, dynamic>> updateDonationFoodType(
    String donationId,
    String vegType,
  ) =>
      _request(
        'PATCH',
        '/api/v1/donations/$donationId/matching-details',
        body: <String, dynamic>{'veg_type': vegType},
      );

  /// The real, opt-in Public Impact Leaderboard (FR-19): organizations ranked
  /// by the kilograms `impact_records` genuinely recorded for their completed
  /// donations. Returns an empty list when nobody opted in or nothing is
  /// recorded — never seeded or demo rows.
  Future<List<dynamic>> getLeaderboard() async {
    final response = await _request('GET', '/api/v1/leaderboard');
    return response['entries'] is List
        ? response['entries'] as List<dynamic>
        : <dynamic>[];
  }

  /// Persists whether the signed-in organization appears on the public
  /// leaderboard. The backend resolves the account from the Firebase token, so
  /// no user id is ever sent.
  Future<Map<String, dynamic>> setLeaderboardVisibility(bool visible) =>
      _request('PATCH', '/api/v1/profile/leaderboard-visibility',
          body: <String, dynamic>{'public': visible});

  /// Uploads a food photo through the authenticated backend boundary and
  /// returns the persistent public URL to attach to the donation.
  Future<String> uploadDonationImage(File file) async {
    final baseUrl = _requireBaseUrl();
    final user = _auth.currentUser;
    final token = await user?.getIdToken();
    if (token == null || token.isEmpty) {
      throw const ApiException(401, 'You must be signed in to use SAHAAY.');
    }
    final request =
        await buildUploadRequest(baseUrl: baseUrl, token: token, file: file);
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
    final url =
        decoded is Map<String, dynamic> ? decoded['food_image_url'] : null;
    if (url is! String || url.isEmpty) {
      throw ApiException(
          response.statusCode, 'Backend did not return an image URL.');
    }
    return url;
  }

  /// Uploads a profile photo through the authenticated backend boundary and
  /// returns the persistent URL to store on the profile. Mirrors the
  /// food-photo upload; degrades into a clear error message until the backend
  /// exposes the upload route.
  Future<String> uploadProfilePhoto(File file) async {
    final baseUrl = _requireBaseUrl();
    final user = _auth.currentUser;
    final token = await user?.getIdToken();
    if (token == null || token.isEmpty) {
      throw const ApiException(401, 'You must be signed in to use SAHAAY.');
    }
    final request = await buildUploadRequest(
      baseUrl: baseUrl,
      token: token,
      file: file,
      uploadPath: '/api/v1/profile/upload-photo',
    );
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
          detail?.toString() ?? 'Profile photo upload failed.');
    }
    final url =
        decoded is Map<String, dynamic> ? decoded['profile_image_url'] : null;
    if (url is! String || url.isEmpty) {
      throw ApiException(
          response.statusCode, 'Backend did not return a photo URL.');
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
    String uploadPath = '/api/v1/donations/upload',
  }) async {
    final mime = mimeForPath(file.path);
    final filename =
        file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : 'photo';
    return http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl$uploadPath'),
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

  // ---------------------------------------------------------------------------
  // Mandatory daily food entry (a food log, NOT a donation)
  // ---------------------------------------------------------------------------
  // These go through the same authenticated FastAPI boundary as everything
  // else. The Flutter app never calls the AI service and never touches
  // Supabase directly; the backend derives provider_id from the Firebase token
  // and the entry date from its own clock.

  /// Submits today's food entry. The backend creates the entry, calls the
  /// existing AI surplus-prediction service and links the stored prediction.
  Future<Map<String, dynamic>> createDailyFoodEntry(
          Map<String, dynamic> payload) =>
      _request('POST', '/api/v1/daily-food', body: payload);

  /// Backend-authoritative check for today's entry. This — not a client-side
  /// date — is what decides whether the provider must complete the entry.
  Future<Map<String, dynamic>> getTodayDailyFoodEntry() =>
      _request('GET', '/api/v1/daily-food/today');

  /// Retries today's prediction from the food amounts already stored by the
  /// backend. No client-supplied or inferred prediction inputs are accepted.
  Future<Map<String, dynamic>> refreshTodayDailyFoodPrediction() =>
      _request('POST', '/api/v1/daily-food/today/prediction/refresh');

  /// The signed-in provider's previous daily entries, newest first.
  Future<List<dynamic>> getDailyFoodHistory() async {
    final response = await _request('GET', '/api/v1/daily-food/history');
    return response['data'] is List
        ? response['data'] as List<dynamic>
        : <dynamic>[];
  }

  Future<List<dynamic>> getClaims() async {
    final response = await _request('GET', '/api/v1/claims');
    return response['data'] is List
        ? response['data'] as List<dynamic>
        : <dynamic>[];
  }

  /// Claims attached to donations owned by the signed-in provider. The backend
  /// enriches each row only with safe NGO display information.
  Future<List<dynamic>> getProviderClaims() async {
    final response = await _request('GET', '/api/v1/claims/provider');
    return response['data'] is List
        ? response['data'] as List<dynamic>
        : <dynamic>[];
  }

  Future<Map<String, dynamic>> getTransportCoordination(String claimId) =>
      _request('GET', '/api/v1/claims/$claimId/transport-coordination');

  Future<Map<String, dynamic>> respondToTransportCoordination(
    String claimId, {
    required String response,
    String? captainName,
    String? captainPhone,
  }) =>
      _request(
        'POST',
        '/api/v1/claims/$claimId/transport-coordination/respond',
        body: <String, dynamic>{
          'response': response,
          if (captainName != null) 'captain_name': captainName,
          if (captainPhone != null) 'captain_phone': captainPhone,
        },
      );

  /// Persisted ranked offers addressed to the signed-in NGO.
  ///
  /// The backend derives the NGO from authentication and enriches each offer
  /// with its donation and persisted ranking. This is not a public feed.
  Future<List<dynamic>> getNgoDonationOffers() async {
    final response = await _request('GET', '/api/v1/donation-offers');
    final data = response['data'];
    if (data is! List) {
      throw const FormatException(
        'Donation offers response must contain a data list.',
      );
    }
    return data;
  }

  /// Records the signed-in NGO's decision for one of its persisted offers.
  Future<Map<String, dynamic>> respondToDonationOffer(
          String offerId, String decision) =>
      _request('POST', '/api/v1/donation-offers/$offerId/respond',
          body: <String, dynamic>{'decision': decision});

  Future<Map<String, dynamic>> createClaim(Map<String, dynamic> payload) =>
      _request('POST', '/api/v1/claims', body: payload);

  Future<List<dynamic>> getDeliveries() async {
    final response = await _request('GET', '/api/v1/deliveries');
    return response['data'] is List
        ? response['data'] as List<dynamic>
        : <dynamic>[];
  }

  /// Open volunteer transport tasks that no volunteer has accepted yet.
  ///
  /// These are real donations where the provider and the claiming NGO both
  /// reported no vehicle, so the pickup needs a volunteer. Nothing is assigned
  /// by this call.
  Future<List<dynamic>> getVolunteerTransportTasks() async {
    final response =
        await _request('GET', '/api/v1/deliveries/transport-required');
    return response['data'] is List
        ? response['data'] as List<dynamic>
        : <dynamic>[];
  }

  /// Accepts an open transport task as the signed-in volunteer.
  ///
  /// The volunteer identity comes from the Firebase token, not the request,
  /// so this cannot be used to take work on somebody else's behalf.
  Future<Map<String, dynamic>> acceptVolunteerTransportTask(
          String deliveryId) =>
      _request('POST', '/api/v1/deliveries/$deliveryId/accept');

  Future<Map<String, dynamic>> updateDeliveryStatus(
    String deliveryId,
    Map<String, dynamic> payload,
  ) =>
      _request('PATCH', '/api/v1/deliveries/$deliveryId/status', body: payload);

  Future<List<dynamic>> getNotifications() async {
    final response = await _request('GET', '/api/v1/notifications');
    return response['data'] is List
        ? response['data'] as List<dynamic>
        : <dynamic>[];
  }

  Future<Map<String, dynamic>> markNotificationRead(String notificationId) =>
      _request('PATCH', '/api/v1/notifications/$notificationId/read');

  /// Registers (or refreshes) this device's FCM token for the signed-in user.
  /// The backend owns the (user, token) upsert, so no user id is ever sent.
  Future<Map<String, dynamic>> registerFcmToken(
          String token, String platform) =>
      _request('POST', '/api/v1/notifications/device-token',
          body: <String, dynamic>{'token': token, 'platform': platform});

  /// Geocodes a human-readable address into latitude/longitude coordinates
  /// using Android's platform Geocoder.
  /// Returns null when the address cannot be geocoded, allowing the donor to
  /// still submit the donation without coordinates (map will show
  /// "Location unavailable" honestly).
  Future<({double latitude, double longitude})?> geocodeAddress(
      String address) async {
    if (address.trim().isEmpty) return null;
    final Object? raw = await _placesMethodChannel
        .invokeMethod('geocode', {'address': address.trim()});
    if (raw is! Map) return null;
    final lat = raw['latitude'];
    final lng = raw['longitude'];
    if (lat is! num || lng is! num) return null;
    final latitude = lat.toDouble();
    final longitude = lng.toDouble();
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      return null;
    }
    return (latitude: latitude, longitude: longitude);
  }

  /// NGO Matching — returns the AI service's ranked NGO list for a donation
  /// (or an `insufficient_data`/`no_candidates` status when not integrable).
  Future<Map<String, dynamic>> matchDonation(String donationId) =>
      _request('POST', '/api/v1/donations/$donationId/match');

  /// Refreshes matching idempotently, then reads the saved ranking and offer
  /// state for the signed-in provider's donation.
  Future<Map<String, dynamic>> getDonationOffers(String donationId) =>
      _request('GET', '/api/v1/donations/$donationId/offers');

  /// Checks a provider-owned ranked offer against its database-clock deadline.
  /// If due, the backend advances it through the same RPC used by the scheduler.
  Future<Map<String, dynamic>> checkRankedOfferEscalation(String donationId) =>
      _request(
        'POST',
        '/api/v1/donations/$donationId/offers/escalation-check',
      );

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

  // ---------------------------------------------------------------------------
  // Handover verification (server-authoritative)
  // ---------------------------------------------------------------------------
  // The claimed-donation screen used to mint a random code in the client and
  // "verify" it against itself, so any client could declare a handover complete
  // with no backend involvement. These call the real lifecycle instead: the
  // code is minted once, stored only as a hash, and verification is the only
  // thing that completes the donation.

  /// Current handover state for the signed-in NGO's claim on this donation.
  Future<Map<String, dynamic>> getHandoverState(String donationId) =>
      _request('GET', '/api/v1/donations/$donationId/handover');

  /// Mints a fresh 4-digit handover code (NGO only). The plaintext code is
  /// returned exactly once; only its per-claim hash is stored server-side.
  Future<Map<String, dynamic>> generateHandoverCode(String donationId) =>
      _request('POST', '/api/v1/donations/$donationId/handover/code');

  /// Submits a handover code for verification (provider or NGO). The backend
  /// resolves the claim from the Firebase token, so no claim id is ever sent.
  Future<Map<String, dynamic>> verifyHandoverCode(
          String donationId, String code) =>
      _request('POST', '/api/v1/donations/$donationId/handover/verify',
          body: <String, dynamic>{'code': code});

  /// Uploads the physical-handover proof photo (NGO only) and returns the
  /// persistent public URL the backend stored on the claim.
  Future<String> uploadHandoverPhoto(String donationId, File file) async {
    final baseUrl = _requireBaseUrl();
    final user = _auth.currentUser;
    final token = await user?.getIdToken();
    if (token == null || token.isEmpty) {
      throw const ApiException(401, 'You must be signed in to use SAHAAY.');
    }
    final request = await buildUploadRequest(
      baseUrl: baseUrl,
      token: token,
      file: file,
      uploadPath: '/api/v1/donations/$donationId/handover/photo',
    );
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
          detail?.toString() ?? 'Handover photo upload failed.');
    }
    final url =
        decoded is Map<String, dynamic> ? decoded['handover_photo_url'] : null;
    if (url is! String || url.isEmpty) {
      throw ApiException(
          response.statusCode, 'Backend did not return a photo URL.');
    }
    return url;
  }

  /// Admin — quantitative impact metrics (kg donated/redistributed, expiry,
  /// redistributions, completed deliveries).
  Future<Map<String, dynamic>> getAdminAnalytics() =>
      _request('GET', '/api/v1/admin/analytics');

  /// Admin — real-time overview counters for the dashboard header cards.
  Future<Map<String, dynamic>> getAdminSummary() =>
      _request('GET', '/api/v1/admin/summary');

  /// Admin — paginated user list with an optional role filter.
  Future<Map<String, dynamic>> getAdminUsers({
    String? role,
    int page = 1,
    int pageSize = 20,
  }) =>
      _adminList('users', role: role, page: page, pageSize: pageSize);

  /// Admin — paginated provider (restaurant) list with owner labels.
  Future<Map<String, dynamic>> getAdminProviders({
    int page = 1,
    int pageSize = 20,
  }) =>
      _adminList('providers', page: page, pageSize: pageSize);

  /// Admin — paginated NGO list with owner labels.
  Future<Map<String, dynamic>> getAdminNgos({
    int page = 1,
    int pageSize = 20,
  }) =>
      _adminList('ngos', page: page, pageSize: pageSize);

  /// Admin — paginated volunteer list with owner labels.
  Future<Map<String, dynamic>> getAdminVolunteers({
    int page = 1,
    int pageSize = 20,
  }) =>
      _adminList('volunteers', page: page, pageSize: pageSize);

  /// Admin — paginated donation list (every status) enriched with the real
  /// provider and surplus-prediction records.
  Future<Map<String, dynamic>> getAdminDonations({
    int page = 1,
    int pageSize = 20,
  }) =>
      _adminList('donations', page: page, pageSize: pageSize);

  /// Admin — paginated claim list enriched with donation and NGO context.
  Future<Map<String, dynamic>> getAdminClaims({
    int page = 1,
    int pageSize = 20,
  }) =>
      _adminList('claims', page: page, pageSize: pageSize);

  /// Admin — paginated delivery list enriched with donation/claim/NGO and
  /// volunteer context.
  Future<Map<String, dynamic>> getAdminDeliveries({
    int page = 1,
    int pageSize = 20,
  }) =>
      _adminList('deliveries', page: page, pageSize: pageSize);

  /// Shared paginated list fetch: `/api/v1/admin/<resource>?page=&page_size=`.
  Future<Map<String, dynamic>> _adminList(
    String resource, {
    String? role,
    int page = 1,
    int pageSize = 20,
  }) {
    final params = <String>['page=$page', 'page_size=$pageSize'];
    if (role != null && role.isNotEmpty) params.add('role=$role');
    return _request('GET', '/api/v1/admin/$resource?${params.join('&')}');
  }

  /// Same auth guard as [_request] but returns the raw response bytes. Used
  /// when the response is a binary PDF instead of JSON.
  Future<List<int>> _rawRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final baseUrl = _requireBaseUrl();
    final user = _auth.currentUser;
    final token = await user?.getIdToken();
    if (token == null || token.isEmpty) {
      throw const ApiException(401, 'You must be signed in to use SAHAAY.');
    }
    final request = http.Request(method, Uri.parse('$baseUrl$path'))
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
    bool forceRefreshToken = false,
  }) async {
    final baseUrl = _requireBaseUrl();
    final user = _auth.currentUser;
    final token = await user?.getIdToken(forceRefreshToken);
    if (token == null || token.isEmpty) {
      throw const ApiException(401, 'You must be signed in to use SAHAAY.');
    }
    final request = http.Request(method, Uri.parse('$baseUrl$path'))
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
      throw ApiException(
          response.statusCode, detail?.toString() ?? 'Backend request failed.');
    }
    return decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{'data': decoded};
  }
}
