import 'package:flutter/material.dart';
import 'package:provider/provider.dart' as p;

import '../../services/auth_controller.dart';
import '../shared/role_dashboard_scaffold.dart';

class VolunteerDashboardScreen extends StatelessWidget {
  const VolunteerDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = p.Provider.of<AuthController>(context).user;
    return RoleDashboardScaffold(
      title: 'Volunteer Dashboard',
      greetingName: user?.fullName ?? 'Volunteer',
      roleLabel: 'VOLUNTEER (OPTIONAL ROLE)',
      upcomingFeatures: const [
        'Nearby delivery opportunities (optional — never mandatory)',
        'Accept / Picked Up / In Transit / Delivered workflow',
        'Distance covered & deliveries completed stats',
        'Impact points, badges & reliability score',
      ],
    );
  }
}
