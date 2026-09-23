import 'package:flutter/material.dart';

import '../../models/user_model.dart';
import '../../theme/app_theme.dart';
import 'register_ngo_screen.dart';
import 'register_provider_screen.dart';
import 'register_volunteer_screen.dart';

class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({super.key});

  void _goTo(BuildContext context, UserRole role) {
    Widget screen;
    switch (role) {
      case UserRole.provider:
        screen = const RegisterProviderScreen();
        break;
      case UserRole.ngo:
        screen = const RegisterNgoScreen();
        break;
      case UserRole.volunteer:
      case UserRole.admin: // admin has no public registration; default guard
        screen = const RegisterVolunteerScreen();
        break;
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join SAHAAY')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Choose how you want to help', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: AppSpacing.xs),
            const Text(
              "You can always add more details later from your profile.",
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.lg),
            _RoleCard(
              icon: Icons.restaurant_outlined,
              title: 'Food Provider',
              subtitle: 'Restaurant, hotel, caterer, cafeteria or institution donating surplus food.',
              color: AppColors.primary,
              onTap: () => _goTo(context, UserRole.provider),
            ),
            const SizedBox(height: AppSpacing.md),
            _RoleCard(
              icon: Icons.apartment_outlined,
              title: 'NGO',
              subtitle: 'Discover and claim available surplus food for your community.',
              color: AppColors.secondary,
              onTap: () => _goTo(context, UserRole.ngo),
            ),
            const SizedBox(height: AppSpacing.md),
            _RoleCard(
              icon: Icons.volunteer_activism_outlined,
              title: 'Volunteer',
              subtitle: 'Optionally help deliver food from providers to NGOs nearby.',
              color: AppColors.accentGreen,
              onTap: () => _goTo(context, UserRole.volunteer),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Container(
                height: 48,
                width: 48,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
