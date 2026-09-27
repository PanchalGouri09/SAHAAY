import 'package:flutter_test/flutter_test.dart';
import 'package:sahaay/services/permission_service.dart';

/// Fake gateway so no real platform channel or GPS hardware is touched.
class _FakeGateway implements PermissionGateway {
  _FakeGateway({this.current = PermissionOutcome.notRequested,
      this.requestResult});

  PermissionOutcome current;
  final PermissionOutcome? requestResult;
  bool locationServiceEnabled = true;

  int statusCalls = 0;
  int requestCalls = 0;
  int openAppSettingsCalls = 0;
  int openLocationSettingsCalls = 0;
  final List<AppPermission> requested = <AppPermission>[];

  @override
  Future<PermissionOutcome> status(AppPermission permission) async {
    statusCalls++;
    return current;
  }

  @override
  Future<PermissionOutcome> request(AppPermission permission) async {
    requestCalls++;
    requested.add(permission);
    final outcome = requestResult ?? PermissionOutcome.granted;
    current = outcome;
    return outcome;
  }

  @override
  Future<bool> isLocationServiceEnabled() async => locationServiceEnabled;

  @override
  Future<bool> openLocationSettings() async {
    openLocationSettingsCalls++;
    return true;
  }

  @override
  Future<bool> openAppSettings() async {
    openAppSettingsCalls++;
    return true;
  }
}

void main() {
  group('PermissionService status', () {
    test('reports the gateway state without prompting', () async {
      final gateway = _FakeGateway(current: PermissionOutcome.granted);
      final service = PermissionService(gateway);

      final outcome = await service.status(AppPermission.camera);

      expect(outcome, PermissionOutcome.granted);
      // status() must never fire an OS dialog.
      expect(gateway.requestCalls, 0);
    });

    test('covers every documented state', () async {
      for (final state in PermissionOutcome.values) {
        final service = PermissionService(_FakeGateway(current: state));
        expect(await service.status(AppPermission.location), state);
      }
    });

    test('works for all three permission types', () async {
      final gateway = _FakeGateway(current: PermissionOutcome.denied);
      final service = PermissionService(gateway);

      for (final permission in AppPermission.values) {
        expect(await service.status(permission), PermissionOutcome.denied);
      }
    });
  });

  group('PermissionService request', () {
    test('granted is returned when the user allows', () async {
      final gateway =
          _FakeGateway(requestResult: PermissionOutcome.granted);
      final service = PermissionService(gateway);

      final outcome = await service.request(AppPermission.camera);

      expect(outcome, PermissionOutcome.granted);
      expect(gateway.requestCalls, 1);
    });

    test('denied is returned when the user refuses', () async {
      final gateway =
          _FakeGateway(requestResult: PermissionOutcome.denied);
      final service = PermissionService(gateway);

      expect(await service.request(AppPermission.notifications),
          PermissionOutcome.denied);
    });

    test('serviceDisabled is surfaced for location', () async {
      final gateway = _FakeGateway(
        requestResult: PermissionOutcome.serviceDisabled,
      );
      final service = PermissionService(gateway);

      expect(await service.request(AppPermission.location),
          PermissionOutcome.serviceDisabled);
    });

    test('notRequired is preserved for platforms that do not need it',
        () async {
      final gateway = _FakeGateway(
        requestResult: PermissionOutcome.notRequired,
      );
      final service = PermissionService(gateway);

      expect(await service.request(AppPermission.notifications),
          PermissionOutcome.notRequired);
    });
  });

  group('No repeated native dialogs', () {
    test('permanently denied is never re-requested', () async {
      final gateway = _FakeGateway(current: PermissionOutcome.permanentlyDenied);
      final service = PermissionService(gateway);

      final first = await service.request(AppPermission.camera);
      final second = await service.request(AppPermission.camera);
      final third = await service.request(AppPermission.camera);

      expect(first, PermissionOutcome.permanentlyDenied);
      expect(second, PermissionOutcome.permanentlyDenied);
      expect(third, PermissionOutcome.permanentlyDenied);
      // The OS would show nothing, so the plugin is never asked again.
      expect(gateway.requestCalls, 0);
    });

    test('restricted is never re-requested', () async {
      final gateway = _FakeGateway(current: PermissionOutcome.restricted);
      final service = PermissionService(gateway);

      expect(await service.request(AppPermission.notifications),
          PermissionOutcome.restricted);
      expect(gateway.requestCalls, 0);
    });

    test('denied can still be asked again later', () async {
      final gateway = _FakeGateway(
        current: PermissionOutcome.denied,
        requestResult: PermissionOutcome.granted,
      );
      final service = PermissionService(gateway);

      expect(await service.request(AppPermission.camera),
          PermissionOutcome.granted);
      expect(gateway.requestCalls, 1);
    });
  });

  group('Settings routing', () {
    test('permanently denied and restricted need Settings', () {
      final service = PermissionService(_FakeGateway());

      expect(service.needsSettings(PermissionOutcome.permanentlyDenied), isTrue);
      expect(service.needsSettings(PermissionOutcome.restricted), isTrue);
    });

    test('denied and granted do not need Settings', () {
      final service = PermissionService(_FakeGateway());

      expect(service.needsSettings(PermissionOutcome.denied), isFalse);
      expect(service.needsSettings(PermissionOutcome.granted), isFalse);
      expect(service.needsSettings(PermissionOutcome.notRequested), isFalse);
      expect(
          service.needsSettings(PermissionOutcome.serviceDisabled), isFalse);
    });

    test('canAskInApp is the inverse of needsSettings', () {
      final service = PermissionService(_FakeGateway());

      expect(service.canAskInApp(PermissionOutcome.denied), isTrue);
      expect(service.canAskInApp(PermissionOutcome.permanentlyDenied), isFalse);
    });

    test('openAppSettings is delegated to the gateway', () async {
      final gateway = _FakeGateway();
      final service = PermissionService(gateway);

      expect(await service.openAppSettings(), isTrue);
      expect(gateway.openAppSettingsCalls, 1);
    });

    test('openLocationSettings is delegated to the gateway', () async {
      final gateway = _FakeGateway();
      final service = PermissionService(gateway);

      expect(await service.openLocationSettings(), isTrue);
      expect(gateway.openLocationSettingsCalls, 1);
    });
  });

  group('User-facing copy', () {
    test('each permission explains why it is needed', () {
      expect(PermissionCopy.reasonFor(AppPermission.location),
          contains('location'));
      expect(PermissionCopy.reasonFor(AppPermission.camera),
          contains('photo'));
      expect(PermissionCopy.reasonFor(AppPermission.notifications),
          contains('notifications'));
    });

    test('permanently denied copy points at Settings', () {
      for (final permission in AppPermission.values) {
        final message = PermissionCopy.deniedMessage(
            permission, PermissionOutcome.permanentlyDenied);
        expect(message, contains('Settings'),
            reason: 'blocked $permission must offer a Settings route');
      }
    });

    test('a plain denial does not promise a Settings route', () {
      expect(
        PermissionCopy.deniedMessage(
            AppPermission.camera, PermissionOutcome.denied),
        isNot(contains('Open Settings')),
      );
    });

    test('denied camera still offers the gallery', () {
      expect(
        PermissionCopy.deniedMessage(
            AppPermission.camera, PermissionOutcome.denied),
        contains('gallery'),
      );
    });

    test('denied notifications confirm in-app updates still work', () {
      expect(
        PermissionCopy.deniedMessage(
            AppPermission.notifications, PermissionOutcome.denied),
        contains('inside SAHAAY'),
      );
    });

    test('service disabled has its own location message', () {
      expect(
        PermissionCopy.deniedMessage(
            AppPermission.location, PermissionOutcome.serviceDisabled),
        contains('turned off'),
      );
    });
  });
}
