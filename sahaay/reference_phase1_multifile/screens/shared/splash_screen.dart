import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/sahaay_logo.dart';
import 'welcome_screen.dart';
import '../../main.dart' show RoleRouter;

/// Shown for a moment on cold start while [AuthController] resolves
/// whether a user is already signed in, then routes accordingly.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _decideNextScreen();
  }

  Future<void> _decideNextScreen() async {
    // Small delay purely for brand presentation — not blocking real logic.
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;

    final auth = context.read<AuthController>();
    Widget next;
    if (auth.status == AuthStatus.authenticated && auth.user != null) {
      next = const RoleRouter();
    } else {
      next = const WelcomeScreen();
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => next),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SahaayLogo(size: 140),
            const SizedBox(height: 40),
            const SizedBox(
              height: 28,
              width: 28,
              child: CircularProgressIndicator(strokeWidth: 2.6, color: AppColors.primary),
            ),
          ],
        ),
      ),
    );
  }
}
