import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

class DatabaseException implements Exception {
  final String message;
  final Object? cause;
  const DatabaseException(this.message, [this.cause]);

  @override
  String toString() => message;
}

class DatabaseAuthorizationException extends DatabaseException {
  const DatabaseAuthorizationException(super.message);
}

class DatabaseService {
  final SupabaseClient _client;
  final FirebaseAuth _firebaseAuth;

  DatabaseService({SupabaseClient? client, FirebaseAuth? firebaseAuth})
      : _client = client ?? SupabaseService.client,
        _firebaseAuth = firebaseAuth ?? FirebaseAuth.instance;

  Future<Map<String, dynamic>?> getUserByFirebaseUid(String firebaseUid) async {
    _requireCurrentFirebaseUid(firebaseUid);
    _requireBackendAuthorization();
    return _single('users', (query) => query.eq('firebase_uid', firebaseUid));
  }

  Future<Map<String, dynamic>?> getCurrentUserProfile() async {
    final firebaseUid = _currentFirebaseUid;
    if (firebaseUid == null) return null;
    return getUserByFirebaseUid(firebaseUid);
  }

  Future<Map<String, dynamic>?> getProviderProfile(String userId) async {
    _requireBackendAuthorization();
    return _single('providers', (query) => query.eq('user_id', userId));
  }

  Future<Map<String, dynamic>?> getNgoProfile(String userId) async {
    _requireBackendAuthorization();
    return _single('ngos', (query) => query.eq('user_id', userId));
  }

  Future<Map<String, dynamic>?> getVolunteerProfile(String userId) async {
    _requireBackendAuthorization();
    return _single('volunteers', (query) => query.eq('user_id', userId));
  }

  Future<Map<String, dynamic>> createUserProfile({
    required String firebaseUid,
    required String fullName,
    required String email,
    required String role,
    String? phone,
  }) async {
    _requireCurrentFirebaseUid(firebaseUid);
    _requireBackendAuthorization();
    return _insert('users', {
      'firebase_uid': firebaseUid,
      'full_name': fullName,
      'email': email,
      'phone': phone,
      'role': role,
    });
  }

  Future<Map<String, dynamic>> createProviderProfile({
    required String userId,
    required String organizationName,
    required String organizationType,
    required String address,
    required String city,
    String? phone,
    String? description,
    double? latitude,
    double? longitude,
  }) async {
    _requireBackendAuthorization();
    return _insert('providers', {
      'user_id': userId,
      'organization_name': organizationName,
      'organization_type': organizationType,
      'description': description,
      'phone': phone,
      'address': address,
      'city': city,
      'latitude': latitude,
      'longitude': longitude,
    });
  }

  Future<Map<String, dynamic>> updateProviderProfile(
    String providerId,
    Map<String, dynamic> values,
  ) async {
    _requireBackendAuthorization();
    return _update('providers', providerId, values);
  }

  Future<Map<String, dynamic>> createDonation(
      Map<String, dynamic> values) async {
    _requireBackendAuthorization();
    return _insert(
        'donations',
        _only(values, const {
          'provider_id',
          'prediction_id',
          'food_name',
          'food_category',
          'quantity',
          'unit',
          'servings',
          'veg_type',
          'description',
          'food_image_url',
          'food_prepared_kg',
          'food_sold_kg',
          'prepared_at',
          'expiry_time',
          'pickup_deadline',
          'pickup_address',
          'latitude',
          'longitude',
          'status',
        }));
  }

  Future<List<Map<String, dynamic>>> getProviderDonations(String providerId) {
    _requireBackendAuthorization();
    return _list(
        'donations',
        (query) => query
            .eq('provider_id', providerId)
            .order('created_at', ascending: false));
  }

  Future<List<Map<String, dynamic>>> getAvailableDonations() {
    return _list(
        'donations',
        (query) => query
            .eq('status', 'available')
            .gt('expiry_time', DateTime.now().toUtc().toIso8601String())
            .order('created_at', ascending: false));
  }

  Future<Map<String, dynamic>?> getDonationById(String donationId) {
    _requireBackendAuthorization();
    return _single('donations', (query) => query.eq('id', donationId));
  }

  Future<Map<String, dynamic>> updateDonationStatus(
      String donationId, String status) {
    _requireBackendAuthorization();
    return _update('donations', donationId, {'status': status});
  }

  Future<Map<String, dynamic>> createClaim(Map<String, dynamic> values) {
    _requireBackendAuthorization();
    return _insert(
        'claims',
        _only(values, const {
          'donation_id',
          'ngo_id',
          'requested_quantity',
          'status',
          'notes',
          'rejection_reason',
        }));
  }

  Future<List<Map<String, dynamic>>> getNgoClaims(String ngoId) {
    _requireBackendAuthorization();
    return _list(
        'claims',
        (query) =>
            query.eq('ngo_id', ngoId).order('created_at', ascending: false));
  }

  Future<List<Map<String, dynamic>>> getDonationClaims(String donationId) {
    _requireBackendAuthorization();
    return _list(
        'claims',
        (query) => query
            .eq('donation_id', donationId)
            .order('created_at', ascending: false));
  }

  Future<Map<String, dynamic>> updateClaimStatus(
      String claimId, String status) {
    _requireBackendAuthorization();
    return _update('claims', claimId, {'status': status});
  }

  Future<Map<String, dynamic>> createDelivery(Map<String, dynamic> values) {
    _requireBackendAuthorization();
    return _insert(
        'deliveries',
        _only(values, const {
          'donation_id',
          'claim_id',
          'volunteer_id',
          'pickup_address',
          'delivery_address',
          'pickup_time',
          'delivery_time',
          'status',
          'notes',
          'proof_of_delivery_url',
          'failure_reason',
        }));
  }

  Future<List<Map<String, dynamic>>> getVolunteerDeliveries(
      String volunteerId) {
    _requireBackendAuthorization();
    return _list(
        'deliveries',
        (query) => query
            .eq('volunteer_id', volunteerId)
            .order('created_at', ascending: false));
  }

  Future<Map<String, dynamic>?> getDeliveryById(String deliveryId) {
    _requireBackendAuthorization();
    return _single('deliveries', (query) => query.eq('id', deliveryId));
  }

  Future<Map<String, dynamic>> updateDeliveryStatus(
      String deliveryId, String status) {
    _requireBackendAuthorization();
    return _update('deliveries', deliveryId, {'status': status});
  }

  Future<List<Map<String, dynamic>>> getNotifications(String userId) {
    _requireBackendAuthorization();
    return _list(
        'notifications',
        (query) =>
            query.eq('user_id', userId).order('created_at', ascending: false));
  }

  Future<Map<String, dynamic>> markNotificationRead(String notificationId) {
    _requireBackendAuthorization();
    return _update('notifications', notificationId, {'is_read': true});
  }

  Future<Map<String, dynamic>> createNotification(Map<String, dynamic> values) {
    _requireBackendAuthorization();
    return _insert(
        'notifications',
        _only(values, const {
          'user_id',
          'title',
          'message',
          'type',
          'related_donation_id',
          'is_read',
        }));
  }

  Future<List<Map<String, dynamic>>> getProviderImpact(String providerId) =>
      _impactForProvider(providerId);

  Future<List<Map<String, dynamic>>> getNgoImpact(String ngoId) async {
    final claims = await getNgoClaims(ngoId);
    final donationIds = claims
        .map((claim) => claim['donation_id'])
        .whereType<String>()
        .toList();
    if (donationIds.isEmpty) return [];
    return _list('impact_records',
        (query) => query.inFilter('donation_id', donationIds));
  }

  Future<List<Map<String, dynamic>>> getVolunteerImpact(
      String volunteerId) async {
    final deliveries = await getVolunteerDeliveries(volunteerId);
    final donationIds = deliveries
        .map((delivery) => delivery['donation_id'])
        .whereType<String>()
        .toList();
    if (donationIds.isEmpty) return [];
    return _list('impact_records',
        (query) => query.inFilter('donation_id', donationIds));
  }

  Future<Map<String, dynamic>?> getImpactForDonation(String donationId) {
    return _single(
        'impact_records', (query) => query.eq('donation_id', donationId));
  }

  Future<Map<String, dynamic>> submitFeedback(Map<String, dynamic> values) {
    _requireBackendAuthorization();
    return _insert(
        'feedback',
        _only(values, const {
          'user_id',
          'donation_id',
          'rating',
          'feedback_type',
          'comments',
        }));
  }

  Future<List<Map<String, dynamic>>> getFeedback(
      {String? donationId, String? userId}) {
    _requireBackendAuthorization();
    return _list('feedback', (query) {
      var filtered = query;
      if (donationId != null) filtered = filtered.eq('donation_id', donationId);
      if (userId != null) filtered = filtered.eq('user_id', userId);
      return filtered.order('created_at', ascending: false);
    });
  }

  String? get _currentFirebaseUid => _firebaseAuth.currentUser?.uid;

  void _requireCurrentFirebaseUid(String firebaseUid) {
    if (_currentFirebaseUid != firebaseUid) {
      throw const DatabaseException(
          'The Firebase user does not match the requested profile.');
    }
  }

  Never _requireBackendAuthorization() {
    throw const DatabaseAuthorizationException(
      'This protected Supabase operation requires the Firebase-token backend bridge.',
    );
  }

  Future<List<Map<String, dynamic>>> _impactForProvider(
      String providerId) async {
    final donations = await getProviderDonations(providerId);
    final donationIds = donations
        .map((donation) => donation['id'])
        .whereType<String>()
        .toList();
    if (donationIds.isEmpty) return [];
    return _list('impact_records',
        (query) => query.inFilter('donation_id', donationIds));
  }

  Future<Map<String, dynamic>?> _single(
    String table,
    dynamic Function(dynamic) filter,
  ) async {
    try {
      final query = filter(_client.from(table).select());
      return await query.maybeSingle();
    } catch (error) {
      throw DatabaseException('Unable to read $table.', error);
    }
  }

  Future<List<Map<String, dynamic>>> _list(
    String table,
    dynamic Function(dynamic) filter,
  ) async {
    try {
      final query = filter(_client.from(table).select());
      final result = await query;
      return List<Map<String, dynamic>>.from(result);
    } catch (error) {
      throw DatabaseException('Unable to read $table.', error);
    }
  }

  Future<Map<String, dynamic>> _insert(
      String table, Map<String, dynamic> values) async {
    try {
      final result = await _client.from(table).insert(values).select().single();
      return Map<String, dynamic>.from(result);
    } catch (error) {
      throw DatabaseException('Unable to create a record in $table.', error);
    }
  }

  Future<Map<String, dynamic>> _update(
      String table, String id, Map<String, dynamic> values) async {
    try {
      final result = await _client
          .from(table)
          .update(values)
          .eq('id', id)
          .select()
          .single();
      return Map<String, dynamic>.from(result);
    } catch (error) {
      throw DatabaseException('Unable to update a record in $table.', error);
    }
  }

  Map<String, dynamic> _only(Map<String, dynamic> values, Set<String> allowed) {
    return Map<String, dynamic>.fromEntries(
      values.entries
          .where((entry) => allowed.contains(entry.key) && entry.value != null),
    );
  }
}
