import 'package:flutter/material.dart';
import 'package:provider/provider.dart' as p;

import '../../models/user_model.dart';
import '../../services/auth_controller.dart';
import '../../services/location_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_text_field.dart';
import '../../main.dart' show RoleRouter;

const _weekDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

class RegisterVolunteerScreen extends StatefulWidget {
  const RegisterVolunteerScreen({super.key});

  @override
  State<RegisterVolunteerScreen> createState() => _RegisterVolunteerScreenState();
}

class _RegisterVolunteerScreenState extends State<RegisterVolunteerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _cityController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  double _preferredDistanceKm = 5;
  final Set<String> _availableDays = {};
  double? _lat;
  double? _lng;
  bool _locating = false;

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _cityController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    setState(() => _locating = true);
    try {
      final pos = await LocationService.getCurrentLocation();
      setState(() {
        _lat = pos.latitude;
        _lng = pos.longitude;
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(backgroundColor: AppColors.success, content: Text('Location captured.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: AppColors.danger, content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_passwordController.text != _confirmPasswordController.text) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(backgroundColor: AppColors.danger, content: Text('Passwords do not match.')));
      return;
    }

    final auth = p.Provider.of<AuthController>(context, listen: false);
    final ok = await auth.register(
      email: _emailController.text.trim(),
      password: _passwordController.text,
      fullName: _fullNameController.text.trim(),
      phone: _phoneController.text.trim(),
      role: UserRole.volunteer,
      extra: {
        'city': _cityController.text.trim(),
        'preferredDistanceKm': _preferredDistanceKm.round(),
        'availableDays': _availableDays.toList(),
        'latitude': _lat,
        'longitude': _lng,
      },
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context)
          .pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const RoleRouter()), (route) => false);
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(backgroundColor: AppColors.danger, content: Text(auth.errorMessage ?? 'Registration failed.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = p.Provider.of<AuthController>(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Register as Volunteer')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppTextField(
                  label: 'Full Name',
                  controller: _fullNameController,
                  prefixIcon: Icons.person_outline,
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  label: 'Email',
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  prefixIcon: Icons.email_outlined,
                  validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  label: 'Phone',
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  prefixIcon: Icons.phone_outlined,
                  validator: (v) => (v == null || v.trim().length < 10) ? 'Enter a valid phone number' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  label: 'City / Area',
                  controller: _cityController,
                  prefixIcon: Icons.location_city_outlined,
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: _lat == null ? 'Use Current Location' : 'Location Captured ✓',
                  outlined: true,
                  isLoading: _locating,
                  icon: Icons.my_location,
                  onPressed: _useCurrentLocation,
                ),
                const SizedBox(height: AppSpacing.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Preferred Delivery Distance: ${_preferredDistanceKm.round()} km',
                      style: Theme.of(context).textTheme.bodyLarge),
                ),
                Slider(
                  value: _preferredDistanceKm,
                  min: 1,
                  max: 20,
                  divisions: 19,
                  label: '${_preferredDistanceKm.round()} km',
                  onChanged: (v) => setState(() => _preferredDistanceKm = v),
                ),
                const SizedBox(height: AppSpacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Available Days', style: Theme.of(context).textTheme.bodyLarge),
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _weekDays.map((d) {
                    final selected = _availableDays.contains(d);
                    return FilterChip(
                      label: Text(d),
                      selected: selected,
                      onSelected: (v) => setState(() {
                        v ? _availableDays.add(d) : _availableDays.remove(d);
                      }),
                    );
                  }).toList(),
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  label: 'Password',
                  controller: _passwordController,
                  obscureText: true,
                  prefixIcon: Icons.lock_outline,
                  validator: (v) => (v == null || v.length < 6) ? 'Minimum 6 characters' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  label: 'Confirm Password',
                  controller: _confirmPasswordController,
                  obscureText: true,
                  prefixIcon: Icons.lock_outline,
                  validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppButton(label: 'CREATE VOLUNTEER ACCOUNT', isLoading: auth.isLoading, onPressed: _submit),
                const SizedBox(height: AppSpacing.md),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
