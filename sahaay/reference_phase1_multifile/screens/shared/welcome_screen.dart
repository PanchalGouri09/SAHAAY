import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/app_button.dart';
import '../../widgets/sahaay_logo.dart';
import '../auth/login_screen.dart';
import '../auth/role_selection_screen.dart';

/// The very first screen a new user sees: what SAHAAY is, and a way
/// forward into Register or Login.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            children: [
              const Spacer(),
              const SahaayLogo(size: 110),
              const SizedBox(height: AppSpacing.md),
              const Text(
                'Turning Surplus Food Into Hope.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'SAHAAY connects food providers with NGOs to reduce food '
                'waste and help communities in need.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, height: 1.4),
              ),
              const SizedBox(height: AppSpacing.lg),
              const _ConceptCard(
                emoji: '🍽️',
                title: 'PROVIDE',
                description: 'Restaurants and hotels can donate surplus food.',
              ),
              const SizedBox(height: AppSpacing.sm),
              const _ConceptCard(
                emoji: '🏢',
                title: 'RECEIVE',
                description: 'NGOs can discover and claim available food.',
              ),
              const SizedBox(height: AppSpacing.sm),
              const _ConceptCard(
                emoji: '👤',
                title: 'VOLUNTEER',
                description: 'People can help deliver food when needed.',
              ),
              const Spacer(),
              AppButton(
                label: 'GET STARTED',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RoleSelectionScreen()),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                ),
                child: const Text('Already have an account? Login'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConceptCard extends StatelessWidget {
  final String emoji;
  final String title;
  final String description;

  const _ConceptCard({required this.emoji, required this.title, required this.description});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(description, style: const TextStyle(color: AppColors.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
