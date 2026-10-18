import 'package:flutter/material.dart';

import '../services/distance.dart';
import '../services/geo_service.dart';

/// Displays an existing address, or resolves a real coordinate pair once per
/// process. A failed lookup remains an explicit unavailable label.
class ReadableAddressText extends StatelessWidget {
  const ReadableAddressText({
    super.key,
    required this.address,
    this.latitude,
    this.longitude,
    this.style,
  });

  final String? address;
  final double? latitude;
  final double? longitude;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final storedAddress = readableAddressOrUnavailable(address);
    if (storedAddress != 'Address unavailable' ||
        !coordinateIsUsable(latitude, longitude)) {
      return Text(storedAddress, style: style);
    }

    return FutureBuilder<PlaceAddress?>(
      future: reverseGeocodeCoordinates(latitude!, longitude!),
      builder: (context, snapshot) {
        final resolved = snapshot.data?.address.trim();
        final displayAddress = resolved == null || resolved.isEmpty
            ? snapshot.connectionState == ConnectionState.waiting
                ? 'Resolving address…'
                : 'Address unavailable'
            : resolved;
        return Text(displayAddress, style: style);
      },
    );
  }
}
