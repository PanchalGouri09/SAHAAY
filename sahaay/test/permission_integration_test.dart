import 'package:flutter_test/flutter_test.dart';
import 'package:sahaay/main.dart';
import 'package:sahaay/services/permission_service.dart';

/// Records what was asked and returns scripted answers, so no real platform
/// channel is involved.
class _FakeGateway implements PermissionGateway {
  PermissionOutcome statusOutcome = PermissionOutcome.notRequested;
  PermissionOutcome requestOutcome = PermissionOutcome.granted;
  bool appSettingsOpened = false;
  bool locationSettingsOpened = false;

  @override
  Future<PermissionOutcome> status(AppPermission permission) async =>
      statusOutcome;

  @override
  Future<PermissionOutcome> request(AppPermission permission) async =>
      requestOutcome;

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<bool> openLocationSettings() async {
    locationSettingsOpened = true;
    return true;
  }

  @override
  Future<bool> openAppSettings() async {
    appSettingsOpened = true;
    return true;
  }
}

void main() {
  late _FakeGateway gateway;
  late PermissionService service;

  setUp(() {
    gateway = _FakeGateway();
    service = PermissionService(gateway);
  });

  tearDown(() {
    // Never let a test seam leak into another test.
    permissionServiceOverride = null;
    positionReaderOverride = null;
  });

  group('Permission surface', () {
    test('exactly the three required permissions exist', () {
      expect(AppPermission.values, <AppPermission>[
        AppPermission.location,
        AppPermission.camera,
        AppPermission.notifications,
      ]);
    });

    test('the app uses one shared service, not per-feature copies', () {
      expect(permissionServiceOverride, isNull);
      expect(activePermissionService(), isA<PermissionService>());
    });

    test('an installed override is what production code reads', () {
      permissionServiceOverride = service;
      expect(identical(activePermissionService(), service), isTrue);
    });
  });

  group('Device position seam', () {
    test('returns injected coordinates without touching GPS', () async {
      positionReaderOverride =
          () async => (latitude: 18.5204, longitude: 73.8567);

      final position = await readDevicePosition();

      expect(position?.latitude, 18.5204);
      expect(position?.longitude, 73.8567);
    });

    test('a failed read yields null rather than invented coordinates',
        () async {
      // The caller must keep manual entry available instead of faking a fix.
      positionReaderOverride = () async => null;

      expect(await readDevicePosition(), isNull);
    });
  });

  group('Notification permission flow', () {
    test('reading the status never prompts the OS', () async {
      gateway.statusOutcome = PermissionOutcome.denied;

      expect(await service.status(AppPermission.notifications),
          PermissionOutcome.denied);
      expect(gateway.requestOutcome, PermissionOutcome.granted);
    });

    test('granting works on the first explicit ask', () async {
      expect(await service.request(AppPermission.notifications),
          PermissionOutcome.granted);
    });

    test('declining leaves in-app notifications usable', () async {
      gateway.requestOutcome = PermissionOutcome.denied;

      final outcome = await service.request(AppPermission.notifications);

      expect(outcome, PermissionOutcome.denied);
      expect(
        PermissionCopy.deniedMessage(
            AppPermission.notifications, outcome),
        contains('inside SAHAAY'),
      );
    });

    test('a blocked permission routes to Settings instead of re-asking',
        () async {
      gateway.statusOutcome = PermissionOutcome.permanentlyDenied;

      final outcome = await service.request(AppPermission.notifications);
      await service.openAppSettings();

      expect(outcome, PermissionOutcome.permanentlyDenied);
      expect(gateway.appSettingsOpened, isTrue);
    });

    test('a platform that does not need it is not nagged', () async {
      gateway.statusOutcome = PermissionOutcome.notRequired;

      // NotRequired is a terminal, non-prompting state: nothing to offer.
      expect(await service.status(AppPermission.notifications),
          PermissionOutcome.notRequired);
    });
  });

  group('Camera permission flow', () {
    test('granted allows the capture path', () async {
      expect(await service.request(AppPermission.camera),
          PermissionOutcome.granted);
    });

    test('denied still offers the gallery, so the flow is not dead-ended',
        () async {
      gateway.requestOutcome = PermissionOutcome.denied;

      final outcome = await service.request(AppPermission.camera);

      expect(outcome, PermissionOutcome.denied);
      expect(PermissionCopy.deniedMessage(AppPermission.camera, outcome),
          contains('gallery'));
    });

    test('permanently denied offers Settings', () async {
      gateway.statusOutcome = PermissionOutcome.permanentlyDenied;

      final outcome = await service.request(AppPermission.camera);

      expect(service.needsSettings(outcome), isTrue);
      expect(PermissionCopy.deniedMessage(AppPermission.camera, outcome),
          contains('Settings'));
    });
  });

  group('Location permission flow', () {
    test('granted allows a location read', () async {
      expect(await service.request(AppPermission.location),
          PermissionOutcome.granted);
    });

    test('denied does not need Settings and can be asked again', () async {
      gateway.requestOutcome = PermissionOutcome.denied;

      final outcome = await service.request(AppPermission.location);

      expect(outcome, PermissionOutcome.denied);
      expect(service.canAskInApp(outcome), isTrue);
    });

    test('service disabled offers the location toggle, not a permission dialog',
        () async {
      gateway.requestOutcome = PermissionOutcome.serviceDisabled;

      final outcome = await service.request(AppPermission.location);

      expect(outcome, PermissionOutcome.serviceDisabled);
      await service.openLocationSettings();
      expect(gateway.locationSettingsOpened, isTrue);
    });

    test('a failed read never fabricates coordinates', () async {
      positionReaderOverride = () async => null;

      expect(await readDevicePosition(), isNull);
    });
  });
}
