/// The four roles in SAHAAY.
enum UserRole { provider, ngo, volunteer, admin }

UserRole userRoleFromString(String value) {
  return UserRole.values.firstWhere(
    (r) => r.name == value,
    orElse: () => UserRole.volunteer,
  );
}

/// Provider sub-types (only relevant when role == provider).
enum ProviderType { restaurant, hotel, caterer, cafeteria, institution }

ProviderType providerTypeFromString(String value) {
  return ProviderType.values.firstWhere(
    (p) => p.name == value,
    orElse: () => ProviderType.restaurant,
  );
}

/// Core user record. Shared shape for all four roles — role-specific
/// extra fields are kept in [extra] so we don't need four separate models
/// this early (keeps the app simple for a student project; can be split
/// later if the schema grows).
class AppUser {
  final String id; // Firebase UID
  final String email;
  final String fullName;
  final String phone;
  final UserRole role;
  final String? photoUrl;
  final DateTime createdAt;

  // Location (used for map features in later phases)
  final double? latitude;
  final double? longitude;
  final String? address;

  /// Role-specific fields, e.g.:
  /// - provider: {providerType, organizationName}
  /// - ngo: {ngoName, registrationId, capacityServed, foodCategoriesAccepted}
  /// - volunteer: {preferredDistanceKm, availableDays}
  final Map<String, dynamic> extra;

  const AppUser({
    required this.id,
    required this.email,
    required this.fullName,
    required this.phone,
    required this.role,
    required this.createdAt,
    this.photoUrl,
    this.latitude,
    this.longitude,
    this.address,
    this.extra = const {},
  });

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      email: json['email'] as String,
      fullName: json['full_name'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      role: userRoleFromString(json['role'] as String? ?? 'volunteer'),
      photoUrl: json['photo_url'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      address: json['address'] as String?,
      extra: (json['extra'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'full_name': fullName,
      'phone': phone,
      'role': role.name,
      'photo_url': photoUrl,
      'created_at': createdAt.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      'address': address,
      'extra': extra,
    };
  }

  AppUser copyWith({
    String? fullName,
    String? phone,
    String? photoUrl,
    double? latitude,
    double? longitude,
    String? address,
    Map<String, dynamic>? extra,
  }) {
    return AppUser(
      id: id,
      email: email,
      fullName: fullName ?? this.fullName,
      phone: phone ?? this.phone,
      role: role,
      createdAt: createdAt,
      photoUrl: photoUrl ?? this.photoUrl,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      address: address ?? this.address,
      extra: extra ?? this.extra,
    );
  }
}
