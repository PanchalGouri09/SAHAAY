import 'package:geolocator/geolocator.dart' as geo;
import 'package:permission_handler/permission_handler.dart' as ph;

/// The three runtime permissions SAHAAY needs, kept in one place so the app
/// never grows three unrelated permission code paths.
enum AppPermission { location, camera, notifications }

/// Normalised permission state, so UI and tests never depend on plugin enums.
enum PermissionOutcome {
  /// Never asked for on this device, or not yet asked in this session.
  notRequested,

  granted,

  /// Asked and refused, but the user can be asked again.
  denied,

  /// Refused with "don't ask again" / blocked. Only Settings can change it.
  permanentlyDenied,

  /// Blocked by policy or parental controls; Settings is the only route.
  restricted,

  /// Permission is granted but the OS location service itself is off.
  serviceDisabled,

  /// Not required on this platform/version (e.g. notifications on Android 12).
  notRequired,
}

/// User-facing copy for each permission, in one place so the wording stays
/// consistent and is assertable in tests.
class PermissionCopy {
  const PermissionCopy._();

  static const String locationTitle = 'Location';
  static const String locationReason =
      'SAHAAY uses your location to provide location-aware pickup and map features.';
  static const String locationDenied =
      'Location is off. Pickup distance and map features stay unavailable, but the rest of the app still works.';
  static const String locationPermanentlyDenied =
      'Location is blocked for SAHAAY. Open Settings to allow it.';
  static const String locationServiceOff =
      'Location services are turned off on this device. Turn them on to use pickup distance and maps.';

  static const String cameraTitle = 'Camera';
  static const String cameraReason =
      'SAHAAY needs camera access so you can add a photo of donated food.';
  static const String cameraDenied =
      'Camera access was declined. You can still choose a photo from your gallery.';
  static const String cameraPermanentlyDenied =
      'Camera is blocked for SAHAAY. Open Settings to allow it, or choose a photo from your gallery.';

  static const String notificationsTitle = 'Notifications';
  static const String notificationsReason =
      'Allow notifications to receive important updates about donations, claims, pickups and deliveries.';
  static const String notificationsDenied =
      'Notifications are off. In-app updates still appear inside SAHAAY.';
  static const String notificationsPermanentlyDenied =
      'Notifications are blocked for SAHAAY. Open Settings to allow them.';

  static String reasonFor(AppPermission permission) {
    switch (permission) {
      case AppPermission.location:
        return locationReason;
      case AppPermission.camera:
        return cameraReason;
      case AppPermission.notifications:
        return notificationsReason;
    }
  }

  static String titleFor(AppPermission permission) {
    switch (permission) {
      case AppPermission.location:
        return locationTitle;
      case AppPermission.camera:
        return cameraTitle;
      case AppPermission.notifications:
        return notificationsTitle;
    }
  }

  /// Message for a refusal, choosing the permanently-denied wording when the
  /// user must go to Settings to recover.
  static String deniedMessage(
    AppPermission permission,
    PermissionOutcome outcome,
  ) {
    final permanent = outcome == PermissionOutcome.permanentlyDenied ||
        outcome == PermissionOutcome.restricted;
    switch (permission) {
      case AppPermission.location:
        if (permanent) return locationPermanentlyDenied;
        if (outcome == PermissionOutcome.serviceDisabled) {
          return locationServiceOff;
        }
        return locationDenied;
      case AppPermission.camera:
        return permanent ? cameraPermanentlyDenied : cameraDenied;
      case AppPermission.notifications:
        return permanent ? notificationsPermanentlyDenied : notificationsDenied;
    }
  }
}

/// Platform seam. The real implementation talks to permission_handler and
/// geolocator; tests inject a fake so no real GPS hardware or platform channel
/// is ever touched.
abstract class PermissionGateway {
  /// Current state without prompting the user.
  Future<PermissionOutcome> status(AppPermission permission);

  /// Shows the OS prompt. Must not be called when already permanently denied.
  Future<PermissionOutcome> request(AppPermission permission);

  /// OS location service toggle (Android location settings / iOS).
  Future<bool> isLocationServiceEnabled();

  /// Opens the OS location-settings screen.
  Future<bool> openLocationSettings();

  /// Opens this app's settings page, where a blocked permission can be fixed.
  Future<bool> openAppSettings();
}

class PlatformPermissionGateway implements PermissionGateway {
  const PlatformPermissionGateway();

  @override
  Future<PermissionOutcome> status(AppPermission permission) async {
    final status = await _platformStatus(permission);
    return _map(status, await _serviceEnabledIfLocation(permission));
  }

  @override
  Future<PermissionOutcome> request(AppPermission permission) async {
    final status = await _platformStatus(permission, request: true);
    return _map(status, await _serviceEnabledIfLocation(permission));
  }

  Future<ph.PermissionStatus> _platformStatus(
    AppPermission permission, {
    bool request = false,
  }) async {
    switch (permission) {
      case AppPermission.location:
        final base = ph.Permission.location;
        return request
            ? await base.request()
            : await base.status;
      case AppPermission.camera:
        final base = ph.Permission.camera;
        return request
            ? await base.request()
            : await base.status;
      case AppPermission.notifications:
        final base = ph.Permission.notification;
        return request
            ? await base.request()
            : await base.status;
    }
  }

  /// Only meaningful for location; a granted location permission with the OS
  /// service off is reported as [PermissionOutcome.serviceDisabled].
  Future<bool?> _serviceEnabledIfLocation(AppPermission permission) async {
    if (permission != AppPermission.location) return null;
    try {
      return await geo.Geolocator.isLocationServiceEnabled();
    } catch (_) {
      // A platform that cannot answer must not be reported as "service off",
      // which would wrongly nag the user to change a setting that is fine.
      return null;
    }
  }

  PermissionOutcome _map(ph.PermissionStatus status, bool? serviceEnabled) {
    switch (status) {
      case ph.PermissionStatus.granted:
      case ph.PermissionStatus.limited:
        // A granted location permission is useless while the OS location
        // service is off, so that is surfaced as its own state.
        if (serviceEnabled == false) {
          return PermissionOutcome.serviceDisabled;
        }
        return PermissionOutcome.granted;
      case ph.PermissionStatus.denied:
        return PermissionOutcome.denied;
      case ph.PermissionStatus.permanentlyDenied:
      case ph.PermissionStatus.restricted:
        return status == ph.PermissionStatus.permanentlyDenied
            ? PermissionOutcome.permanentlyDenied
            : PermissionOutcome.restricted;
      case ph.PermissionStatus.provisional:
        return PermissionOutcome.granted;
    }
  }

  @override
  Future<bool> isLocationServiceEnabled() async {
    try {
      return await geo.Geolocator.isLocationServiceEnabled();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> openLocationSettings() async {
    try {
      return await geo.Geolocator.openLocationSettings();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> openAppSettings() async {
    try {
      return await ph.openAppSettings();
    } catch (_) {
      return false;
    }
  }
}

/// Single entry point for all SAHAAY permission handling.
///
/// Callers never touch plugin enums or platform channels directly, which keeps
/// the decision logic (explain -> request -> react) unit-testable.
class PermissionService {
  PermissionService([PermissionGateway? gateway])
      : _gateway = gateway ?? const PlatformPermissionGateway();

  final PermissionGateway _gateway;

  /// Current state, never prompting.
  Future<PermissionOutcome> status(AppPermission permission) =>
      _gateway.status(permission);

  /// Requests [permission] if asking again is still allowed.
  ///
  /// Re-prompts the user at most once: a permanently denied or restricted
  /// permission is never asked for again, because the OS will not show a
  /// dialog and firing it repeatedly is exactly the behaviour to avoid. The
  /// caller is told to send the user to Settings instead.
  Future<PermissionOutcome> request(AppPermission permission) async {
    final current = await _gateway.status(permission);
    if (current == PermissionOutcome.permanentlyDenied ||
        current == PermissionOutcome.restricted) {
      return current;
    }
    return _gateway.request(permission);
  }

  /// True when a Settings route is the only way forward.
  bool needsSettings(PermissionOutcome outcome) =>
      outcome == PermissionOutcome.permanentlyDenied ||
      outcome == PermissionOutcome.restricted;

  /// True when the user can still fix this without leaving the app.
  bool canAskInApp(PermissionOutcome outcome) => !needsSettings(outcome);

  /// Opens the OS location toggle, for [PermissionOutcome.serviceDisabled].
  Future<bool> openLocationSettings() => _gateway.openLocationSettings();

  /// Opens this app's settings page.
  Future<bool> openAppSettings() => _gateway.openAppSettings();
}
