import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../platform/platform_models.dart';
import 'auth_models.dart';
import 'auth_repository.dart';
import 'auth_scaffold.dart';
import 'session.dart';

/// Single sign-on only works in the browser (v1.7 has no mobile SSO).
final ssoSupportedProvider = Provider<bool>((_) => kIsWeb);

/// Sends the browser to [url] in the same tab. Tests override it.
final ssoLauncherProvider = Provider<Future<void> Function(String url)>(
  (_) =>
      (url) async => launchUrl(Uri.parse(url), webOnlyWindowName: '_self'),
);

/// Message for the `ssoError` codes the callback redirects with.
String ssoErrorMessage(String code) => switch (code) {
  'SSO_STATE_INVALID' => 'The sign-in link expired. Try again.',
  'SSO_TOKEN_INVALID' => 'Your identity provider sent an invalid response.',
  'SSO_DOMAIN_MISMATCH' => "This email's domain is not allowed for this SSO.",
  'SSO_USER_LIMIT' =>
    'The company has reached its user limit. Ask an administrator.',
  'SSO_NO_ACCOUNT' => 'No account matches this email. Ask an administrator.',
  'SSO_IDP_ERROR' => 'Your identity provider reported an error.',
  'ACCOUNT_DISABLED' => 'This account is disabled.',
  _ => 'Single sign-on failed. Try again.',
};

/// Friendlier text for sign-in failures that carry data.
String signInErrorMessage(Object error) {
  final api = apiError(error);
  if (api != null && api.code == 'ACCOUNT_LOCKED') {
    final until = DateTime.tryParse('${api.details['lockedUntil']}')?.toLocal();
    return until == null
        ? 'This account is locked. Try again later.'
        : 'This account is locked until '
              '${DateFormat('d MMM, h:mm a').format(until)}. '
              'Try again then, or reset your password.';
  }
  return errorMessage(error);
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _emailFocus = FocusNode();
  bool _busy = false;
  bool _obscure = true;
  MfaChallenge? _challenge;
  bool _recovery = false;
  SsoDiscovery? _sso;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _emailFocus.addListener(() {
      if (!_emailFocus.hasFocus) _discover(silent: true);
    });
    final api = ref.read(apiClientProvider);
    final notice = api.sessionNotice;
    if (notice != null) {
      api.sessionNotice = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showInfoSnackBar(context, notice);
      });
    }
    final ssoError = GoRouter.maybeOf(
      context,
    )?.routeInformationProvider.value.uri.queryParameters['ssoError'];
    if (ssoError != null) _notice = ssoErrorMessage(ssoError);
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  Future<void> _discover({bool silent = false}) async {
    if (!ref.read(ssoSupportedProvider)) return;
    final email = _email.text.trim();
    if (validateEmail(email) != null) {
      if (!silent) _formKey.currentState!.validate();
      return;
    }
    try {
      final found = await ref.read(authRepositoryProvider).discoverSso(email);
      if (!mounted) return;
      setState(() => _sso = found);
      if (!silent && found.providers.isEmpty) {
        showInfoSnackBar(
          context,
          'No single sign-on is set up for this email.',
        );
      }
    } catch (e) {
      if (!silent && mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _startSso(String id) async {
    var returnTo = '';
    try {
      returnTo = '${Uri.base.origin}/';
    } catch (_) {
      // Not on the web.
    }
    final url = ref.read(authRepositoryProvider).ssoStartUrl(id, returnTo);
    await ref.read(ssoLauncherProvider)(url);
  }

  Future<void> _submit() async {
    if (!validateAndReveal(_formKey)) return;
    setState(() => _busy = true);
    try {
      // The router redirects away from /login once signed in.
      final challenge = await ref
          .read(sessionProvider.notifier)
          .signIn(_email.text.trim(), _password.text);
      if (challenge != null && mounted) {
        setState(() {
          _challenge = challenge;
          _code.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        if (apiError(e)?.code == 'SSO_REQUIRED') await _discover(silent: true);
        if (mounted) showSnack(signInErrorMessage(e), e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void showSnack(String message, Object error) {
    final api = apiError(error);
    if (api != null && api.code == 'ACCOUNT_LOCKED') {
      setState(() => _notice = message);
      return;
    }
    showErrorSnackBar(context, error);
  }

  Future<void> _verify() async {
    if (_busy) return;
    final text = _code.text.trim();
    if (text.isEmpty) {
      showInfoSnackBar(
        context,
        _recovery ? 'Enter a recovery code' : 'Enter the 6-digit code',
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(sessionProvider.notifier)
          .completeMfa(
            _challenge!.mfaToken,
            code: _recovery ? null : text,
            recoveryCode: _recovery ? text : null,
          );
    } catch (e) {
      if (!mounted) return;
      final api = apiError(e);
      if (api != null && api.code == 'UNAUTHORIZED') {
        // Too many wrong codes: the challenge is dead.
        setState(() {
          _challenge = null;
          _notice = 'Too many wrong codes. Sign in again.';
        });
      } else {
        showSnack(signInErrorMessage(e), e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_challenge != null) return _mfaStep(context);
    final sso = _sso;
    final enforced = sso?.enforced ?? false;
    return AuthScaffold(
      title: 'Sign in',
      child: Form(
        key: _formKey,
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_notice != null) _NoticeBanner(_notice!),
              TextFormField(
                key: const Key('login.email'),
                controller: _email,
                focusNode: _emailFocus,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                onChanged: (_) {
                  if (_sso != null) setState(() => _sso = null);
                },
                validator: validateEmail,
              ),
              if (!enforced) ...[
                const SizedBox(height: Space.lg),
                TextFormField(
                  key: const Key('login.password'),
                  controller: _password,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'Password',
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
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Password is required' : null,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const Key('login.forgot'),
                    onPressed: _busy
                        ? null
                        : () => context.go('/forgot-password'),
                    child: const Text('Forgot password?'),
                  ),
                ),
                const SizedBox(height: 8),
                BusyButton(
                  key: const Key('login.submit'),
                  busy: _busy,
                  onPressed: _submit,
                  icon: Icons.login,
                  label: 'Sign in',
                ),
              ] else
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Your organisation requires single sign-on for this email.',
                  ),
                ),
              if (sso != null)
                for (final p in sso.providers) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: Key('login.sso.${p.id}'),
                    onPressed: () => _startSso(p.id),
                    icon: const Icon(Icons.vpn_key_outlined),
                    label: Text('Continue with ${p.name}'),
                  ),
                ],
              if (ref.watch(ssoSupportedProvider) &&
                  (sso == null || sso.providers.isEmpty))
                TextButton(
                  key: const Key('login.sso'),
                  onPressed: _busy ? null : () => _discover(),
                  child: const Text('Sign in with SSO'),
                ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.start,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('New to OneMatrix?'),
                  TextButton(
                    onPressed: _busy ? null : () => context.go('/signup'),
                    child: const Text('Create a business account'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mfaStep(BuildContext context) => AuthScaffold(
    title: 'Two-step verification',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _recovery
              ? 'Enter one of your recovery codes. Each works once.'
              : 'Enter the 6-digit code from your authenticator app.',
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('mfa.code'),
          controller: _code,
          autofocus: true,
          keyboardType: _recovery ? TextInputType.text : TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          decoration: InputDecoration(
            labelText: _recovery ? 'Recovery code' : 'Code',
          ),
          onSubmitted: (_) => _verify(),
        ),
        const SizedBox(height: 16),
        BusyButton(
          key: const Key('mfa.submit'),
          busy: _busy,
          onPressed: _verify,
          icon: Icons.verified_user_outlined,
          label: 'Verify',
        ),
        if (_challenge!.hasRecovery)
          TextButton(
            key: const Key('mfa.toggle'),
            onPressed: _busy
                ? null
                : () => setState(() {
                    _recovery = !_recovery;
                    _code.clear();
                  }),
            child: Text(
              _recovery ? 'Use authenticator code' : 'Use a recovery code',
            ),
          ),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                  _challenge = null;
                  _recovery = false;
                }),
          child: const Text('Back to sign in'),
        ),
      ],
    ),
  );
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: Space.lg),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: colors.dangerContainer,
        borderRadius: Radii.mediumAll,
      ),
      child: Text(
        message,
        key: const Key('login.notice'),
        style: TextStyle(color: colors.onDangerContainer),
      ),
    );
  }
}
