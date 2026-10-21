import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/india_states.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/state_dropdown.dart';
import 'auth_models.dart';
import 'auth_scaffold.dart';
import 'session.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _business = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _gstin = TextEditingController();
  String? _stateCode;
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    for (final c in [_business, _name, _email, _phone, _password, _gstin]) {
      c.dispose();
    }
    super.dispose();
  }

  void _gstinChanged(String value) {
    clearServerError('gstin');
    final derived = stateCodeFromGstin(value.trim().toUpperCase());
    if (isValidGstin(value) && derived != null && derived != _stateCode) {
      setState(() => _stateCode = derived);
    }
  }

  Future<void> _submit() async {
    setState(() => serverErrors = const {});
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(sessionProvider.notifier)
          .signup(
            SignupRequest(
              businessName: _business.text.trim(),
              name: _name.text.trim(),
              email: _email.text.trim(),
              password: _password.text,
              phone: trimmedOrNull(_phone.text),
              stateCode: _stateCode!,
              gstin: trimmedOrNull(_gstin.text.toUpperCase()),
            ),
          );
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Create your business account',
      maxWidth: 560,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _business,
              decoration: const InputDecoration(labelText: 'Business name'),
              textCapitalization: TextCapitalization.words,
              forceErrorText: serverError('businessName'),
              onChanged: (_) => clearServerError('businessName'),
              validator: (v) => requiredField(v, 'Business name'),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Your name'),
              textCapitalization: TextCapitalization.words,
              forceErrorText: serverError('name'),
              onChanged: (_) => clearServerError('name'),
              validator: (v) => requiredField(v, 'Your name'),
            ),
            const SizedBox(height: 16),
            FormRow(
              children: [
                TextFormField(
                  controller: _email,
                  decoration: const InputDecoration(labelText: 'Email'),
                  keyboardType: TextInputType.emailAddress,
                  forceErrorText: serverError('email'),
                  onChanged: (_) => clearServerError('email'),
                  validator: validateEmail,
                ),
                TextFormField(
                  controller: _phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone (optional)',
                  ),
                  keyboardType: TextInputType.phone,
                  forceErrorText: serverError('phone'),
                  onChanged: (_) => clearServerError('phone'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Password',
                helperText: 'At least 8 characters',
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              forceErrorText: serverError('password'),
              onChanged: (_) => clearServerError('password'),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Password is required';
                if (v.length < 8) return 'Use at least 8 characters';
                return null;
              },
            ),
            const SizedBox(height: 16),
            StateDropdown(
              value: _stateCode,
              label: 'State',
              errorText: serverError('stateCode'),
              onChanged: (v) {
                clearServerError('stateCode');
                setState(() => _stateCode = v);
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _gstin,
              decoration: const InputDecoration(
                labelText: 'GSTIN (optional)',
                helperText: 'Sets the state automatically',
              ),
              textCapitalization: TextCapitalization.characters,
              maxLength: 15,
              forceErrorText: serverError('gstin'),
              onChanged: _gstinChanged,
              validator: (v) {
                final error = validateGstin(v);
                if (error != null) return error;
                final code = stateCodeFromGstin(v?.trim().toUpperCase());
                if (code != null && _stateCode != null && code != _stateCode) {
                  return 'GSTIN belongs to state $code, not $_stateCode';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            BusyButton(
              busy: _busy,
              onPressed: _submit,
              icon: Icons.rocket_launch_outlined,
              label: 'Create account',
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Already have an account?'),
                TextButton(
                  onPressed: _busy ? null : () => context.go('/login'),
                  child: const Text('Sign in'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
