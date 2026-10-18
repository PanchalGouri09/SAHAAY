import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../main.dart';

/// One real coordinate supplied by the SAHAAY backend.
///
/// Points are never synthesised: a caller that cannot fill both [latitude] and
/// [longitude] from backend data simply does not create a point, and the map
/// falls back to its honest "location unavailable" state instead.
@immutable
class SahaayMapPoint {
  final double latitude;
  final double longitude;
  final String? title;
  final String? snippet;

  /// Optional `BitmapDescriptor.hue*` value; null renders the default red pin.
  final double? markerHue;

  /// Hue reserved for a destination pin (the NGO's own registered location),
  /// so it reads differently from the red food-pickup markers.
  static const double destinationHue = BitmapDescriptor.hueAzure;

  const SahaayMapPoint({
    required this.latitude,
    required this.longitude,
    this.title,
    this.snippet,
    this.markerHue,
  });

  /// A coordinate is only usable if it is a real, in-range WGS-84 value.
  /// Guarding here means an out-of-range number coming from anywhere upstream
  /// is dropped instead of reaching the `LatLng` assertions below.
  bool get isUsable =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;
}

/// SAHAAY's Google Map card.
///
/// * No coordinates (or only out-of-range ones) → an honest, clearly labelled
///   "Location unavailable" state. Nothing is ever invented and the user's own
///   location is never used as a substitute for a donation/NGO coordinate.
/// * One coordinate → a map pinned to that point.
/// * Several coordinates → one marker each, with the camera fitted to the
///   bounds once the map has been created.
///
/// The Google Maps API key is NOT read here: it is injected into
/// `AndroidManifest.xml` by the Secrets Gradle Plugin from the gitignored
/// `android/secrets.properties`, so Dart never sees the secret.
class SahaayGoogleMap extends StatefulWidget {
  final double height;

  /// Single-coordinate mode. Both must be present and in range, otherwise the
  /// widget renders the unavailable state.
  final double? latitude;
  final double? longitude;
  final String? markerTitle;
  final String? markerSnippet;

  /// Multi-coordinate mode (e.g. "Food Available Near You"). Merged with the
  /// single-coordinate fields when both are supplied.
  final List<SahaayMapPoint> points;

  /// When set, the map becomes interactive for choosing a location: a tap
  /// reports the tapped WGS-84 coordinates. Callers use it to move a pin.
  /// Null keeps the map display-only.
  final void Function(double latitude, double longitude)? onPointSelected;

  /// Called when the user taps a marker's info window. Caller should launch
  /// the Google Maps app with the given coordinates.
  final void Function(double latitude, double longitude)? onMarkerInfoWindowTap;

  const SahaayGoogleMap({
    super.key,
    this.height = 160,
    this.latitude,
    this.longitude,
    this.markerTitle,
    this.markerSnippet,
    this.points = const <SahaayMapPoint>[],
    this.onPointSelected,
    this.onMarkerInfoWindowTap,
  });

  @visibleForTesting
  List<SahaayMapPoint> get resolvedPoints {
    final resolved = <SahaayMapPoint>[
      for (final point in points)
        if (point.isUsable) point,
    ];
    final single = latitude != null && longitude != null
        ? SahaayMapPoint(
            latitude: latitude!,
            longitude: longitude!,
            title: markerTitle,
            snippet: markerSnippet,
          )
        : null;
    if (single != null && single.isUsable) resolved.add(single);
    return resolved;
  }

  @override
  State<SahaayGoogleMap> createState() => _SahaayGoogleMapState();
}

class _SahaayGoogleMapState extends State<SahaayGoogleMap> {
  static const Duration _mapLoadTimeout = Duration(seconds: 20);

  GoogleMapController? _controller;
  Timer? _mapLoadTimer;
  bool _mapLoaded = false;
  bool _mapLoadFailed = false;
  int _mapGeneration = 0;
  int _shownSignature = 0;

  @override
  void initState() {
    super.initState();
    if (widget.resolvedPoints.isNotEmpty) _startMapLoadTimeout();
  }

  @override
  void didUpdateWidget(covariant SahaayGoogleMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hadPoints = oldWidget.resolvedPoints.isNotEmpty;
    final hasPoints = widget.resolvedPoints.isNotEmpty;
    if (!hadPoints && hasPoints) {
      _mapLoaded = false;
      _mapLoadFailed = false;
      _startMapLoadTimeout();
    } else if (hadPoints && !hasPoints) {
      _mapLoadTimer?.cancel();
      _controller = null;
      _mapLoaded = false;
      _mapLoadFailed = false;
    }
    _moveToNewPointIfChanged();
  }

  @override
  void dispose() {
    _mapLoadTimer?.cancel();
    super.dispose();
  }

  void _startMapLoadTimeout() {
    _mapLoadTimer?.cancel();
    _mapLoadTimer = Timer(_mapLoadTimeout, () {
      if (mounted && !_mapLoaded) {
        setState(() => _mapLoadFailed = true);
      }
    });
  }

  void _onMapLoaded() {
    _mapLoadTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _mapLoaded = true;
      _mapLoadFailed = false;
    });
  }

  void _retryMap() {
    setState(() {
      _mapGeneration++;
      _controller = null;
      _mapLoaded = false;
      _mapLoadFailed = false;
    });
    _startMapLoadTimeout();
  }

  /// Keeps an existing map pinned to the newest point: picking a second place
  /// after the map has already been created must move the camera, not leave
  /// the old pin off-screen.
  void _moveToNewPointIfChanged() {
    final controller = _controller;
    if (controller == null) return;
    final points = widget.resolvedPoints;
    final signature = Object.hashAll([
      for (final point in points) Object.hash(point.latitude, point.longitude),
    ]);
    if (points.isEmpty || signature == _shownSignature) return;
    _shownSignature = signature;
    try {
      controller.animateCamera(
        CameraUpdate.newLatLngZoom(
          LatLng(points.first.latitude, points.first.longitude),
          points.length > 1 ? 11.5 : 15,
        ),
      );
    } catch (_) {
      // Best effort — the markers still land in the right place.
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final points = widget.resolvedPoints;

    // No real coordinate → say so plainly instead of faking a location.
    if (points.isEmpty) return _locationUnavailable(c);

    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
        color: c.surfaceAlt,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.card - 1),
            child: GoogleMap(
              key: ValueKey(_mapGeneration),
              initialCameraPosition: CameraPosition(
                target: _centerOf(points),
                zoom: points.length > 1 ? 11.5 : 15,
              ),
              markers: _buildMarkers(points),
              onMapCreated: _onMapCreated,
              onCameraIdle: _onMapLoaded,
              // Pan + zoom are the useful gestures in a card this size; rotate/tilt
              // only make a small embedded map harder to read.
              scrollGesturesEnabled: true,
              zoomGesturesEnabled: true,
              rotateGesturesEnabled: false,
              tiltGesturesEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
              compassEnabled: false,
              onTap: widget.onPointSelected == null
                  ? null
                  : (LatLng latLng) {
                      widget.onPointSelected!(
                          latLng.latitude, latLng.longitude);
                      if (widget.onMarkerInfoWindowTap != null &&
                          points.length == 1 &&
                          latLng.latitude == points.first.latitude &&
                          latLng.longitude == points.first.longitude) {
                        widget.onMarkerInfoWindowTap!(
                          latLng.latitude,
                          latLng.longitude,
                        );
                      }
                    },
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              liteModeEnabled: false,
            ),
          ),
          if (!_mapLoaded && !_mapLoadFailed)
            Positioned(
              top: 10,
              left: 0,
              right: 0,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                    border: Border.all(color: c.border),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('Loading map…'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (_mapLoadFailed)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context)
                    .colorScheme
                    .surface
                    .withValues(alpha: 0.92),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.map_outlined),
                        const SizedBox(height: 8),
                        const Text(
                          'Map could not be initialized. Check your connection and retry.',
                          textAlign: TextAlign.center,
                        ),
                        TextButton.icon(
                          onPressed: _retryMap,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry map'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              shape: const CircleBorder(),
              child: IconButton(
                tooltip: 'Reload map',
                onPressed: _retryMap,
                icon: const Icon(Icons.refresh),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  border: Border.all(color: c.border),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onMapCreated(GoogleMapController controller) {
    _controller = controller;
    final points = widget.resolvedPoints;
    _shownSignature = Object.hashAll([
      for (final point in points) Object.hash(point.latitude, point.longitude),
    ]);
    if (points.length < 2) return;
    // Fitting bounds needs a laid-out map, so it runs one frame later; every
    // failure is swallowed because the markers themselves are already placed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        controller.animateCamera(
          CameraUpdate.newLatLngBounds(_boundsOf(points), 64),
        );
      } catch (_) {
        // Best effort only — the initial camera position still shows the area.
      }
    });
  }

  Set<Marker> _buildMarkers(List<SahaayMapPoint> points) {
    final markers = <Marker>{};
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final titled = (point.title ?? '').trim();
      markers.add(Marker(
        markerId: MarkerId('sahaay_point_$i'),
        position: LatLng(point.latitude, point.longitude),
        icon: point.markerHue == null
            ? BitmapDescriptor.defaultMarker
            : BitmapDescriptor.defaultMarkerWithHue(point.markerHue!),
        infoWindow: titled.isEmpty
            ? InfoWindow.noText
            : InfoWindow(title: titled, snippet: point.snippet),
      ));
    }
    return markers;
  }

  LatLng _centerOf(List<SahaayMapPoint> points) {
    if (points.length == 1) {
      return LatLng(points.first.latitude, points.first.longitude);
    }
    final bounds = _boundsOf(points);
    return LatLng(
      (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
      (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
    );
  }

  LatLngBounds _boundsOf(List<SahaayMapPoint> points) {
    var minLat = points.first.latitude, maxLat = points.first.latitude;
    var minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final point in points) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  /// The same rounded, bordered card shell the placeholder used, so swapping
  /// placeholder → real map does not change the surrounding layout.
  Widget _locationUnavailable(AppColors c) {
    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
        color: c.surfaceAlt,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.location_off_outlined,
            size: 40,
            color: c.textSecondary.withValues(alpha: 0.5),
          ),
          Positioned(
            bottom: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(AppRadius.chip),
                border: Border.all(color: c.border),
              ),
              child: Text(
                'Location unavailable — no coordinates for this item',
                style: TextStyle(fontSize: 10.5, color: c.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
