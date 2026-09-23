import 'package:flutter/material.dart';
import 'package:provider/provider.dart' as p;

import '../../services/auth_controller.dart';
import '../shared/role_dashboard_scaffold.dart';

/// Phase 1 scope: this confirms the Provider is correctly authenticated
/// and routed here. The real dashboard (stats, AI surplus prediction,
/// donation list, quick-create button) is built in PHASE 2.
class ProviderDashboardScreen extends StatelessWidget {
  const ProviderDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = p.Provider.of<AuthController>(context).user;
    return RoleDashboardScaffold(
      title: 'Provider Dashboard',
      greetingName: user?.fullName ?? 'Provider',
      roleLabel: 'FOOD PROVIDER',
      upcomingFeatures: const [
        'Food donated today / active donations / meals saved',
        'AI food surplus prediction card',
        'Recent donations list',
        '+ Create New Donation button',
      ],
    );
  }
}
