import 'package:flutter/material.dart';
import 'package:provider/provider.dart' as p;

import '../../services/auth_controller.dart';
import '../shared/role_dashboard_scaffold.dart';

class NgoDashboardScreen extends StatelessWidget {
  const NgoDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = p.Provider.of<AuthController>(context).user;
    return RoleDashboardScaffold(
      title: 'NGO Dashboard',
      greetingName: user?.fullName ?? 'NGO',
      roleLabel: 'NGO',
      upcomingFeatures: const [
        'Available donations nearby + interactive map',
        'AI-based NGO/donation matching & recommendations',
        'Claim donation workflow',
        'Delivery tracking',
      ],
    );
  }
}
