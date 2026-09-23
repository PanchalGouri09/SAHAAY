import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The SAHAAY wordmark + tagline, matching the provided logo.
///
/// The full illustrated logo (hands + bowl) should be exported as a PNG/SVG
/// and placed at `assets/images/sahaay_logo.png` — see README_PHASE1.md.
/// Until that asset exists, this widget falls back to a simple drawn mark
/// so screens never show a broken-image icon during development.
class SahaayLogo extends StatelessWidget {
  final double size;
  final bool showWordmark;

  const SahaayLogo({super.key, this.size = 96, this.showWordmark = true});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/images/sahaay_icon.png',
          height: size,
          errorBuilder: (context, error, stack) => _FallbackMark(size: size),
        ),
        if (showWordmark) ...[
          const SizedBox(height: 12),
          Text(
            'SAHAAY',
            style: TextStyle(
              fontSize: size * 0.3,
              fontWeight: FontWeight.w800,
              color: AppColors.primary,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'CONNECTING SURPLUS WITH NEED',
            style: TextStyle(
              fontSize: size * 0.1,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ],
    );
  }
}

class _FallbackMark extends StatelessWidget {
  final double size;
  const _FallbackMark({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(Icons.volunteer_activism, color: Colors.white, size: size * 0.5),
    );
  }
}
