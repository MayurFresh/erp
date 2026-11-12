import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../settings/user_edit_screen.dart' show PasswordFields;
import 'auth_repository.dart';
import 'auth_scaffold.dart';

/// `/reset-password?token=`: sets a new password from the emailed link.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key, required this.token});

  final String? token;

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _done = false;
  bool _invalid = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(authRepositoryProvider)
          .resetPassword(widget.token!, _password.text);
      if (mounted) setState(() => _done = true);
    } catch (e) {
      if (!mounted) return;
      final api = apiError(e);
      if (api != null && api.code == 'RESET_TOKEN_INVALID') {
        setState(() => _invalid = true);
      } else {
        // Password policy: `details: { newPassword: message }`.
        final message = api?.details['newPassword'] ?? api?.details['password'];
        if (message != null) {
          setState(() => serverErrors = {'newPassword': '$message'});
        }
        showErrorSnackBar(context, e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final missing = widget.token == null || widget.token!.isEmpty;
    if (missing || _invalid) {
      return AuthScaffold(
        title: 'Reset password',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              key: Key('reset.invalid'),
              'This reset link is invalid or has expired. Ask for a new one.',
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => context.go('/forgot-password'),
              child: const Text('Send a new link'),
            ),
          ],
        ),
      );
    }
    if (_done) {
      return AuthScaffold(
        title: 'Password changed',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              key: Key('reset.done'),
              'Your password has been changed. Sign in with the new password.',
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => context.go('/login'),
              child: const Text('Sign in'),
            ),
          ],
        ),
      );
    }
    return AuthScaffold(
      title: 'Reset password',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PasswordFields(
              password: _password,
              confirm: _confirm,
              errorText: serverError('newPassword'),
              onChanged: () => clearServerError('newPassword'),
            ),
            const SizedBox(height: 16),
            BusyButton(
              key: const Key('reset.submit'),
              busy: _busy,
              onPressed: _submit,
              icon: Icons.lock_reset,
              label: 'Set new password',
            ),
          ],
        ),
      ),
    );
  }
}
