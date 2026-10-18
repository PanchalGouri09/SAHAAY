/// SAHAAY's one location picker.
///
/// Every screen that needs a real place — provider/NGO registration, donation
/// pickup, delivery endpoints — opens this instead of writing its own
/// coordinate logic. It offers three honest ways to choose a location and
/// nothing else:
///
///  1. **Search** — real Google Places Autocomplete (see
///     [PlacesGateway]); there is no bundled or fabricated suggestion list.
///  2. **Current location** — the device fix, behind the same
///     [PermissionService] flow used everywhere else in SAHAAY.
///  3. **Tap the map** — fine-tune a pin, reverse-geocoded into an address.
///
/// A free-typed query is also an acceptable selection (address only, no
/// coordinates), because many providers legitimately know an address but have
/// never pinned it. Coordinates are only ever returned when they came from
/// Google, the device, or the user's own tap — never invented.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/distance.dart';
import '../services/geo_service.dart';
import '../services/places_service.dart';
import '../services/permission_service.dart';
import 'sahaay_google_map.dart';

/// What the caller gets back from the picker.
///
/// [address] is always non-empty: either a resolved readable address or the
/// label "Address unavailable" when reverse geocoding had no result.
@immutable
class LocationSelectionResult {
  const LocationSelectionResult({
    this.latitude,
    this.longitude,
    required this.address,
    this.city,
    this.addressIsCoordinates = false,
  });

  final double? latitude;
  final double? longitude;
  final String address;
  final String? city;
  final bool addressIsCoordinates;

  bool get hasCoordinates =>
      latitude != null &&
      longitude != null &&
      latitude! >= -90 &&
      latitude! <= 90 &&
      longitude! >= -180 &&
      longitude! <= 180;
}

/// Opens the picker full-screen. Returns null when the user backs out.
Future<LocationSelectionResult?> showLocationPicker(
  BuildContext context, {
  String title = 'Choose location',
  double? latitude,
  double? longitude,
  String? address,
}) {
  return Navigator.of(context).push<LocationSelectionResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => LocationPickerScreen(
        title: title,
        initialLatitude: latitude,
        initialLongitude: longitude,
        initialAddress: address,
      ),
    ),
  );
}

/// Debounce before a keystroke becomes an autocomplete request. Short enough
/// to feel live, long enough that a fast typist fires one call, not eight.
const Duration _kAutocompleteDebounce = Duration(milliseconds: 350);

/// Minimum characters before autocomplete is attempted; below this Google
/// returns noise anyway and the request would cost quota for nothing.
const int _kMinimumQueryLength = 2;

class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({
    super.key,
    this.title = 'Choose location',
    this.initialLatitude,
    this.initialLongitude,
    this.initialAddress,
  });

  final String title;
  final double? initialLatitude;
  final double? initialLongitude;
  final String? initialAddress;

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final TextEditingController _query = TextEditingController();
  final PermissionService _permissions = activePermissionService();

  Timer? _debounce;
  int _requestSerial = 0;

  List<PlaceSuggestion> _suggestions = const <PlaceSuggestion>[];
  bool _searching = false;
  String? _searchError;

  double? _latitude;
  double? _longitude;
  String _address = '';
  String? _city;
  bool _addressIsCoordinates = false;

  bool _resolving = false;
  bool _locating = false;
  String? _statusError;

  @override
  void initState() {
    super.initState();
    final initial = (widget.initialAddress ?? '').trim();
    _latitude = widget.initialLatitude;
    _longitude = widget.initialLongitude;
    _address = initial;
    _addressIsCoordinates = false;
    _query.text = initial;
    if (_hasPoint) _resolveCityForCurrentPoint();
    // A fresh autocomplete session per picker open, so Google bills a place
    // detail as part of the session instead of as an unrelated lookup.
    activePlacesGateway().newSession();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  bool get _hasPoint => _latitude != null && _longitude != null;

  bool get _canConfirm => _address.trim().isNotEmpty && !_resolving;

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < _kMinimumQueryLength) {
      if (_suggestions.isNotEmpty || _searchError != null) {
        setState(() {
          _suggestions = const <PlaceSuggestion>[];
          _searchError = null;
        });
      }
      return;
    }
    _debounce =
        Timer(_kAutocompleteDebounce, () => _runAutocomplete(query));
  }

  Future<void> _runAutocomplete(String query) async {
    final serial = ++_requestSerial;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final results = await activePlacesGateway().autocomplete(query);
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _suggestions = results;
        _searching = false;
      });
    } on PlacesException catch (e) {
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _suggestions = const <PlaceSuggestion>[];
        _searching = false;
        _searchError = e.message;
      });
    } catch (_) {
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _suggestions = const <PlaceSuggestion>[];
        _searching = false;
        _searchError = 'Place search is unavailable right now.';
      });
    }
  }

  Future<void> _selectSuggestion(PlaceSuggestion suggestion) async {
    _debounce?.cancel();
    _requestSerial++;
    if (!mounted) return;
    setState(() {
      _resolving = true;
      _statusError = null;
      _searchError = null;
    });
    try {
      final details = await activePlacesGateway()
          .placeDetails(suggestion.placeId);
      if (!mounted) return;
      if (details == null) {
        setState(() {
          _resolving = false;
          _statusError =
              'That place has no coordinates on Google Maps. Try another result.';
        });
        return;
      }
      setState(() {
        _latitude = details.latitude;
        _longitude = details.longitude;
        _address = details.address;
        _addressIsCoordinates = false;
        _city = null;
        _suggestions = const <PlaceSuggestion>[];
        _query.text = details.address;
        _resolving = false;
      });
      await _resolveCityForCurrentPoint();
    } on PlacesException catch (e) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _statusError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _statusError = 'Could not look up that place.';
      });
    }
  }

  /// Best-effort city lookup for the point we already have. A failure leaves
  /// [_city] null, which is honest — city is optional everywhere it is stored.
  Future<void> _resolveCityForCurrentPoint() async {
    final lat = _latitude;
    final lng = _longitude;
    if (lat == null || lng == null) return;
    final resolved = await reverseGeocodeCoordinates(lat, lng);
    if (!mounted || resolved == null) return;
    if (_latitude != lat || _longitude != lng) return;
    setState(() => _city = resolved.city);
  }

  Future<void> _useMyCurrentLocation() async {
    if (_locating || !mounted) return;
    setState(() {
      _locating = true;
      _statusError = null;
    });
    try {
      final outcome = await _permissions.request(AppPermission.location);
      if (!mounted) return;

      if (outcome == PermissionOutcome.serviceDisabled) {
        setState(() => _locating = false);
        final open = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text(PermissionCopy.locationTitle),
            content: const Text(PermissionCopy.locationServiceOff),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Not now'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Open Settings'),
              ),
            ],
          ),
        );
        if (open == true) await _permissions.openLocationSettings();
        return;
      }

      if (outcome != PermissionOutcome.granted) {
        setState(() => _locating = false);
        await _explainLocationRefusal(outcome);
        return;
      }

      final position = await readDevicePosition();
      if (!mounted) return;
      if (position == null) {
        setState(() {
          _locating = false;
          _statusError =
              'Could not read your location. Search for a place instead.';
        });
        return;
      }
      await _adoptPoint(
        latitude: position.latitude,
        longitude: position.longitude,
        fromDevice: true,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _locating = false;
        _statusError =
            'Could not read your location. Search for a place instead.';
      });
    }
  }

  Future<void> _explainLocationRefusal(PermissionOutcome outcome) async {
    final blocked = _permissions.needsSettings(outcome);
    final action = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(PermissionCopy.locationTitle),
        content: Text(
            PermissionCopy.deniedMessage(AppPermission.location, outcome)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(blocked ? 'Not now' : 'Search instead'),
          ),
          if (blocked)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Open Settings'),
            ),
        ],
      ),
    );
    if (action == true) await _permissions.openAppSettings();
  }

  Future<void> _onMapTapped(double latitude, double longitude) =>
      _adoptPoint(latitude: latitude, longitude: longitude);

  /// Adopts a real coordinate and resolves it into readable text.
  ///
  /// When reverse geocoding has no answer, keep the real pin and show an honest
  /// unavailable label instead of exposing raw coordinates as an address.
  Future<void> _adoptPoint({
    required double latitude,
    required double longitude,
    bool fromDevice = false,
  }) async {
    if (!coordinateIsUsable(latitude, longitude)) {
      setState(() {
        _locating = false;
        _statusError = 'That location is not a valid point on Earth.';
      });
      return;
    }
    setState(() {
      _locating = fromDevice;
      _resolving = !fromDevice;
      _statusError = null;
      _latitude = latitude;
      _longitude = longitude;
      _suggestions = const <PlaceSuggestion>[];
    });
    final resolved = await reverseGeocodeCoordinates(latitude, longitude);
    if (!mounted) return;
    if (_latitude != latitude || _longitude != longitude) return;
    setState(() {
      _locating = false;
      _resolving = false;
      if (resolved != null && resolved.address.trim().isNotEmpty) {
        _address = resolved.address;
        _addressIsCoordinates = false;
        _city = resolved.city;
        _query.text = resolved.address;
      } else {
        _address = 'Address unavailable';
        _addressIsCoordinates = true;
        _city = null;
        _query.text = _address;
      }
    });
  }

  void _confirm() {
    final address = _address.trim();
    if (address.isEmpty || _resolving) return;
    Navigator.of(context).pop(LocationSelectionResult(
      latitude: _hasPoint ? _latitude : null,
      longitude: _hasPoint ? _longitude : null,
      address: address,
      city: _city,
      addressIsCoordinates: _addressIsCoordinates,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          TextButton(
            onPressed: _canConfirm ? _confirm : null,
            child: const Text('CONFIRM'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
              child: TextField(
                controller: _query,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: 'Search for a place or address',
                  hintText: 'e.g. Kothrud, Pune',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : (_query.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _query.clear();
                                _onQueryChanged('');
                              },
                            )),
                ),
                onChanged: _onQueryChanged,
                onSubmitted: (value) {
                  _debounce?.cancel();
                  final query = value.trim();
                  if (query.length >= _kMinimumQueryLength) {
                    _runAutocomplete(query);
                  }
                },
              ),
            ),
            if (_searchError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
                child: Text(
                  _searchError!,
                  style: TextStyle(color: c.danger, fontSize: 12.5),
                ),
              ),
            if (_suggestions.isNotEmpty)
              Container(
                margin: const EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
                constraints: const BoxConstraints(maxHeight: 220),
                decoration: BoxDecoration(
                  color: c.surface,
                  border: Border.all(color: c.border),
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: _suggestions.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: c.border),
                  itemBuilder: (context, index) {
                    final suggestion = _suggestions[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(Icons.location_on_outlined,
                          size: 20, color: c.bluePrimary),
                      title: Text(
                        suggestion.primaryText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14, color: c.textPrimary),
                      ),
                      subtitle: suggestion.secondaryText.isEmpty
                          ? null
                          : Text(
                              suggestion.secondaryText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12, color: c.textSecondary),
                            ),
                      onTap: () => _selectSuggestion(suggestion),
                    );
                  },
                ),
              ),
            if (_statusError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
                child: Text(
                  _statusError!,
                  style: TextStyle(color: c.danger, fontSize: 12.5),
                ),
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_hasPoint) ...[
                      SahaayGoogleMap(
                        height: 200,
                        latitude: _latitude,
                        longitude: _longitude,
                        markerTitle: _addressIsCoordinates ? null : _address,
                        markerSnippet: _city,
                        onPointSelected: _onMapTapped,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        'Tap the map to fine-tune the pin.',
                        style: TextStyle(
                            fontSize: 11.5, color: c.textSecondary),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ] else
                      Container(
                        height: 140,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          borderRadius:
                              BorderRadius.circular(AppRadius.card),
                          border: Border.all(color: c.border),
                          color: c.surfaceAlt,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.location_searching_outlined,
                                size: 34,
                                color: c.textSecondary
                                    .withValues(alpha: 0.5)),
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              'Search for a place, use your location,\n'
                              'or type an address above.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: c.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed:
                                _locating ? null : _useMyCurrentLocation,
                            icon: _locating
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.my_location, size: 18),
                            label: const Text('Use my current location'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        if (_hasPoint)
                          IconButton(
                            tooltip: 'Clear pin',
                            onPressed: () => setState(() {
                              _latitude = null;
                              _longitude = null;
                              _city = null;
                              _addressIsCoordinates = false;
                            }),
                            icon: const Icon(Icons.close, size: 18),
                          ),
                      ],
                    ),
                    if (_resolving)
                      const Padding(
                        padding: EdgeInsets.only(top: AppSpacing.md),
                        child: Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                    const SizedBox(height: AppSpacing.lg),
                    FilledButton(
                      onPressed: _canConfirm ? _confirm : null,
                      child: const Text('Use this location'),
                    ),
                    if (_addressIsCoordinates)
                      Padding(
                        padding:
                            const EdgeInsets.only(top: AppSpacing.sm),
                        child: Text(
                          'No readable address was found for this pin. The '
                          'location pin will still be saved; you can type the '
                          'address if you know it.',
                          style: TextStyle(
                              fontSize: 11.5, color: c.textSecondary),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
