import 'package:flutter/material.dart';
import 'package:provider/provider.dart' as p;

import '../../models/user_model.dart';
import '../../services/auth_controller.dart';
import '../../services/location_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_text_field.dart';
import '../../main.dart' show RoleRouter;

const _foodCategories = [
  'Cooked Meals',
  'Rice',
  'Bread',
  'Fruits',
  'Vegetables',
  'Packaged Food',
  'Bakery',
  'Other',
];

class RegisterNgoScreen extends StatefulWidget {
  const RegisterNgoScreen({super.key});

  @override
  State<RegisterNgoScreen> createState() => _RegisterNgoScreenState();
}

class _RegisterNgoScreenState extends State<RegisterNgoScreen> {
  final _formKey = GlobalKey<FormState>();
  final _ngoNameController = TextEditingController();
  final _regIdController = TextEditingController();
  final _contactPersonController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressController = TextEditingController();
  final _capacityController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  final Set<String> _selectedCategories = {};
  double? _lat;
  double? _lng;
  bool _locating = false;

  @override
  void dispose() {
    _ngoNameController.dispose();
    _regIdController.dispose();
    _contactPersonController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    _capacityController.dispose();
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
    if (_selectedCategories.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(backgroundColor: AppColors.danger, content: Text('Select at least one food category.')),
      );
      return;
    }

    final auth = p.Provider.of<AuthController>(context, listen: false);
    final ok = await auth.register(
      email: _emailController.text.trim(),
      password: _passwordController.text,
      fullName: _contactPersonController.text.trim(),
      phone: _phoneController.text.trim(),
      role: UserRole.ngo,
      extra: {
        'ngoName': _ngoNameController.text.trim(),
        'registrationId': _regIdController.text.trim(),
        'address': _addressController.text.trim(),
        'capacityServed': int.tryParse(_capacityController.text.trim()) ?? 0,
        'foodCategoriesAccepted': _selectedCategories.toList(),
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
      appBar: AppBar(title: const Text('Register as NGO')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppTextField(
                  label: 'NGO Name',
                  controller: _ngoNameController,
                  prefixIcon: Icons.apartment_outlined,
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  label: 'Registration / Organization ID',
                  controller: _regIdController,
                  prefixIcon: Icons.badge_outlined,
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  label: 'Contact Person',
                  controller: _contactPersonController,
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
                  label: 'Address',
                  controller: _addressController,
                  maxLines: 2,
                  prefixIcon: Icons.location_on_outlined,
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
                AppTextField(
                  label: 'Capacity Served (people/day)',
                  controller: _capacityController,
                  keyboardType: TextInputType.number,
                  prefixIcon: Icons.groups_outlined,
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Food Categories Accepted', style: Theme.of(context).textTheme.bodyLarge),
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _foodCategories.map((c) {
                    final selected = _selectedCategories.contains(c);
                    return FilterChip(
                      label: Text(c),
                      selected: selected,
                      onSelected: (v) => setState(() {
                        v ? _selectedCategories.add(c) : _selectedCategories.remove(c);
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
                AppButton(label: 'CREATE NGO ACCOUNT', isLoading: auth.isLoading, onPressed: _submit),
                const SizedBox(height: AppSpacing.md),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
