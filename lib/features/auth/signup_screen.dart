import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_profile.dart';
import '../../core/india_states.dart';
import '../business/business_repository.dart';
import '../business/type_picker.dart';
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
  int _step = 0;
  String _type = 'general';
  String _plan = 'business';
  String _country = 'IN';

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
    if (!validateAndReveal(_formKey)) return;
    if (_country == 'IN' && _stateCode == null) {
      setState(() => serverErrors = const {'stateCode': 'Choose a state'});
      return;
    }
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
              stateCode: _country == 'IN' ? _stateCode : null,
              gstin: _country == 'IN'
                  ? trimmedOrNull(_gstin.text.toUpperCase())
                  : null,
              businessType: _type,
              plan: _plan,
              country: _country,
            ),
          );
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _typeStep() {
    final catalogue = ref.watch(businessCatalogueProvider);
    return catalogue.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (c) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('What kind of business do you run?'),
          const SizedBox(height: 8),
          if (c.types.isEmpty)
            const Text(
              'The list could not be loaded. You can continue as a general '
              'business and change this later in Settings.',
            )
          else
            BusinessTypePicker(
              catalogue: c,
              selected: _type,
              onSelected: (t) => setState(() => _type = t.id),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => setState(() => _step = 1),
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Next'),
          ),
          _signInLink(),
        ],
      ),
    );
  }

  Widget _planStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Choose a plan. You can change it later.'),
        const SizedBox(height: 8),
        for (final p in kPlans)
          Card(
            color: p.id == _plan
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            child: ListTile(
              key: Key('plan-${p.id}'),
              selected: p.id == _plan,
              leading: Icon(
                p.id == _plan
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(p.name),
              subtitle: Text(p.features.join(' · ')),
              onTap: () => setState(() => _plan = p.id),
            ),
          ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: const Key('country'),
          initialValue: _country,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Country'),
          items: [
            for (final c in kCountries)
              DropdownMenuItem(
                value: c.code,
                child: Text('${c.name} (${c.currency})'),
              ),
          ],
          onChanged: (v) => setState(() => _country = v ?? 'IN'),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton(
              onPressed: () => setState(() => _step = 0),
              child: const Text('Back'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => setState(() => _step = 2),
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Next'),
              ),
            ),
          ],
        ),
        _signInLink(),
      ],
    );
  }

  Widget _signInLink() => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      const Text('Already have an account?'),
      TextButton(
        onPressed: _busy ? null : () => context.go('/login'),
        child: const Text('Sign in'),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final titles = ['Your kind of business', 'Plan and country'];
    return AuthScaffold(
      title: _step < 2 ? titles[_step] : 'Create your business account',
      maxWidth: _step == 0 ? 720 : 560,
      child: _step == 0
          ? _typeStep()
          : _step == 1
          ? _planStep()
          : _form(),
    );
  }

  Widget _form() {
    return Form(
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
                validator: validatePhone,
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
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
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
          if (_country == 'IN') ...[
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
          ],
          BusyButton(
            busy: _busy,
            onPressed: _submit,
            icon: Icons.arrow_forward,
            label: 'Create account',
          ),
          TextButton(
            onPressed: _busy ? null : () => setState(() => _step = 1),
            child: const Text('Back'),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.start,
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
    );
  }
}
