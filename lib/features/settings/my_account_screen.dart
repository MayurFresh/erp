import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'settings_repository.dart';
import '../../widgets/busy.dart';
import 'user_edit_screen.dart' show PasswordFields;

/// `/account`: the signed-in user's details and password change. Open to
/// every signed-in user.
class MyAccountScreen extends ConsumerStatefulWidget {
  const MyAccountScreen({super.key});

  @override
  ConsumerState<MyAccountScreen> createState() => _MyAccountScreenState();
}

class _MyAccountScreenState extends ConsumerState<MyAccountScreen>
    with ServerFieldErrors, DirtyTracking<MyAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscureCurrent = true;
  bool _saving = false;

  @override
  void dispose() {
    _current.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => serverErrors = const {});
    if (!_formKey.currentState!.validate()) return;
    if (_password.text == _current.text) {
      setState(
        () => serverErrors = {
          'newPassword': 'Choose a password different from the current one',
        },
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(settingsRepositoryProvider)
          .changeMyPassword(_current.text, _password.text);
      if (!mounted) return;
      _formKey.currentState!.reset();
      for (final c in [_current, _password, _confirm]) {
        c.clear();
      }
      markSaved();
      showInfoSnackBar(context, 'Password changed');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final session = ref.watch(sessionProvider).value;
    final user = session?.user;
    final roles = session?.company?.roles.map((r) => r.name).join(', ') ?? '';
    final theme = Theme.of(context);
    return Form(
      key: _formKey,
      onChanged: markDirty,
      child: FormPage(
        maxWidth: 640,
        children: [
          Text('My account', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 16),
          if (user != null)
            SectionCard(
              child: Wrap(
                spacing: 32,
                runSpacing: 12,
                children: [
                  LabeledValue('Name', user.name),
                  LabeledValue('Email', user.email),
                  LabeledValue('Phone', user.phone ?? ''),
                  if (session?.company != null)
                    LabeledValue('Role in ${session!.company!.name}', roles),
                ],
              ),
            ),
          SectionCard(
            title: 'Change password',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _current,
                  obscureText: _obscureCurrent,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: 'Current password',
                    suffixIcon: IconButton(
                      tooltip: _obscureCurrent
                          ? 'Show password'
                          : 'Hide password',
                      icon: Icon(
                        _obscureCurrent
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                      onPressed: () =>
                          setState(() => _obscureCurrent = !_obscureCurrent),
                    ),
                  ),
                  forceErrorText: serverError('currentPassword'),
                  onChanged: (_) => clearServerError('currentPassword'),
                  validator: (v) => (v == null || v.isEmpty)
                      ? 'Enter your current password'
                      : null,
                ),
                const SizedBox(height: 16),
                PasswordFields(
                  password: _password,
                  confirm: _confirm,
                  errorText: serverError('newPassword'),
                  onChanged: () => clearServerError('newPassword'),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: BusyButton(
                    busy: _saving,
                    onPressed: _submit,
                    label: 'Change password',
                    icon: Icons.lock_reset,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
