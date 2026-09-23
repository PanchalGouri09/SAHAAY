import 'package:flutter/material.dart';
import 'package:provider/provider.dart' as p;

import '../../services/auth_controller.dart';
import '../shared/role_dashboard_scaffold.dart';

class AdminDashboardScreen extends StatelessWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = p.Provider.of<AuthController>(context).user;
    return RoleDashboardScaffold(
      title: 'Admin Dashboard',
      greetingName: user?.fullName ?? 'Admin',
      roleLabel: 'ADMIN',
      upcomingFeatures: const [
        'Platform-wide totals (users, providers, NGOs, deliveries)',
        'User / provider / NGO / volunteer management',
        'Live donation, claim & delivery monitoring',
        'Reports & analytics',
      ],
    );
  }
}
