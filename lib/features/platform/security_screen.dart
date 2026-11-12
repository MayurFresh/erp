import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'platform_models.dart';
import 'platform_repository.dart';
import '../../widgets/form_support.dart';

final securityProvider = FutureProvider.autoDispose<SecurityInfo>(
  (ref) => ref.watch(platformRepositoryProvider).security(),
);

final mySessionsProvider = FutureProvider.autoDispose<List<UserSession>>(
  (ref) => ref.watch(platformRepositoryProvider).sessions(),
);

final notificationPrefsProvider =
    FutureProvider.autoDispose<List<NotificationPref>>(
      (ref) => ref.watch(platformRepositoryProvider).prefs(),
    );

String formatStamp(String? iso) {
  final d = DateTime.tryParse(iso ?? '')?.toLocal();
  return d == null ? '' : DateFormat('d MMM y, h:mm a').format(d);
}

Future<void> copyText(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showInfoSnackBar(context, '$what copied');
}

/// `/account/security`: two-factor sign-in, active sessions and notification
/// preferences of the signed-in user. Open to every signed-in user (it is
/// also the only screen a user who must enrol in 2FA can use).
class AccountSecurityScreen extends ConsumerWidget {
  const AccountSecurityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => FormPage(
    maxWidth: 720,
    children: [
      Text('Security', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 16),
      const TwoFactorCard(),
      const SessionsCard(),
      const NotificationPrefsCard(),
    ],
  );
}

class TwoFactorCard extends ConsumerStatefulWidget {
  const TwoFactorCard({super.key});

  @override
  ConsumerState<TwoFactorCard> createState() => _TwoFactorCardState();
}

class _TwoFactorCardState extends ConsumerState<TwoFactorCard> {
  TotpSetup? _setup;
  List<String>? _codes;
  final _code = TextEditingController();
  String? _codeError;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  PlatformRepository get _repo => ref.read(platformRepositoryProvider);

  Future<void> _start() async {
    try {
      final setup = await _repo.setup2fa();
      if (mounted) setState(() => _setup = setup);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _enable() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _codeError = 'Enter the 6-digit code');
      return;
    }
    try {
      final codes = await _repo.enable2fa(code);
      _code.clear();
      ref.invalidate(securityProvider);
      await ref.read(sessionProvider.notifier).reloadMe();
      if (mounted) {
        setState(() {
          _setup = null;
          _codes = codes;
          _codeError = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      final message = apiError(e)?.details['code'];
      if (message != null) {
        setState(() => _codeError = '$message');
      } else {
        showErrorSnackBar(context, e);
      }
    }
  }

  /// Asks for the password and a code; `null` when cancelled.
  Future<({String password, String code})?> _confirm(
    String title,
    String action,
  ) => showFormDialog<({String password, String code})>(
    context: context,
    builder: (_) => _PasswordCodeDialog(title: title, action: action),
  );

  Future<void> _disable() async {
    final input = await _confirm('Turn off two-step verification', 'Turn off');
    if (input == null) return;
    try {
      await _repo.disable2fa(input.password, input.code);
      ref.invalidate(securityProvider);
      await ref.read(sessionProvider.notifier).reloadMe();
      if (mounted) showInfoSnackBar(context, 'Two-step verification is off');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _regenerate() async {
    final input = await _confirm('New recovery codes', 'Generate');
    if (input == null) return;
    try {
      final codes = await _repo.newRecoveryCodes(input.password, input.code);
      ref.invalidate(securityProvider);
      if (mounted) setState(() => _codes = codes);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final security = ref.watch(securityProvider);
    return SectionCard(
      title: 'Two-step verification',
      child: AsyncValueView<SecurityInfo>(
        value: security,
        onRetry: () => ref.invalidate(securityProvider),
        data: (info) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (info.mustEnrol2fa)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  key: const Key('security.mustEnrol'),
                  'Your company requires two-step verification. Set it up to '
                  'continue using Progen.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_codes != null) _recoveryCodes(context, _codes!),
            if (_setup != null)
              _setupPanel(context, _setup!)
            else if (info.twoFactorEnabled) ...[
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Pill('On'),
                  Text(
                    'Since ${formatStamp(info.twoFactorEnabledAt)}. '
                    '${info.recoveryCodesLeft} recovery codes left.',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const Key('2fa.regenerate'),
                    onPressed: _regenerate,
                    icon: const Icon(Icons.refresh),
                    label: const Text('New recovery codes'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('2fa.disable'),
                    onPressed: _disable,
                    icon: const Icon(Icons.no_encryption_outlined),
                    label: const Text('Turn off'),
                  ),
                ],
              ),
            ] else ...[
              const Text(
                'Ask for a code from an authenticator app when you sign in.',
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const Key('2fa.setup'),
                  onPressed: _start,
                  icon: const Icon(Icons.shield_outlined),
                  label: const Text('Set up'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _setupPanel(BuildContext context, TotpSetup setup) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        '1. In your authenticator app choose "Enter a setup key" and type '
        'this key, or open the link on this device.',
      ),
      const SizedBox(height: 8),
      SelectableText(
        setup.secret,
        key: const Key('2fa.secret'),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
      ),
      const SizedBox(height: 4),
      SelectableText(
        setup.otpauthUri,
        key: const Key('2fa.uri'),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed: () => copyText(context, setup.secret, 'Key'),
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy key'),
          ),
          TextButton.icon(
            onPressed: () => copyText(context, setup.otpauthUri, 'Link'),
            icon: const Icon(Icons.link, size: 18),
            label: const Text('Copy link'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      const Text('2. Enter the 6-digit code it shows.'),
      const SizedBox(height: 8),
      TextField(
        key: const Key('2fa.code'),
        controller: _code,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: 'Code', errorText: _codeError),
        onChanged: (_) {
          if (_codeError != null) setState(() => _codeError = null);
        },
        onSubmitted: (_) => _enable(),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          BusyButton(
            key: const Key('2fa.enable'),
            onPressed: _enable,
            label: 'Turn on',
            icon: Icons.verified_user_outlined,
          ),
          TextButton(
            onPressed: () => setState(() => _setup = null),
            child: const Text('Cancel'),
          ),
        ],
      ),
    ],
  );

  Widget _recoveryCodes(BuildContext context, List<String> codes) => Card(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Recovery codes', style: Theme.of(context).textTheme.titleSmall),
          const Text(
            'Save these now. Each works once and they are not shown again.',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              for (final c in codes)
                SelectableText(
                  c,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('2fa.copyCodes'),
                onPressed: () =>
                    copyText(context, codes.join('\n'), 'Recovery codes'),
                icon: const Icon(Icons.copy),
                label: const Text('Copy all'),
              ),
              TextButton(
                key: const Key('2fa.savedCodes'),
                onPressed: () => setState(() => _codes = null),
                child: const Text("I've saved them"),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _PasswordCodeDialog extends StatefulWidget {
  const _PasswordCodeDialog({required this.title, required this.action});

  final String title;
  final String action;

  @override
  State<_PasswordCodeDialog> createState() => _PasswordCodeDialogState();
}

class _PasswordCodeDialogState extends State<_PasswordCodeDialog> {
  final _password = TextEditingController();
  final _code = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('2fa.password'),
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('2fa.confirmCode'),
            controller: _code,
            decoration: const InputDecoration(
              labelText: 'Authenticator or recovery code',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('2fa.confirm'),
        onPressed: _password.text.isEmpty || _code.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, (
                password: _password.text,
                code: _code.text.trim(),
              )),
        child: Text(widget.action),
      ),
    ],
  );
}

class SessionsCard extends ConsumerWidget {
  const SessionsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(mySessionsProvider);
    Future<void> run(Future<void> Function() call, String done) async {
      try {
        await call();
        ref.invalidate(mySessionsProvider);
        if (context.mounted) showInfoSnackBar(context, done);
      } catch (e) {
        if (context.mounted) showErrorSnackBar(context, e);
      }
    }

    final repo = ref.read(platformRepositoryProvider);
    return SectionCard(
      title: 'Where you are signed in',
      child: AsyncValueView<List<UserSession>>(
        value: sessions,
        onRetry: () => ref.invalidate(mySessionsProvider),
        data: (list) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final s in list)
              ListTile(
                key: Key('session.${s.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  s.method == 'sso'
                      ? Icons.vpn_key_outlined
                      : Icons.devices_outlined,
                ),
                title: Text(
                  s.userAgent == null || s.userAgent!.isEmpty
                      ? 'Unknown device'
                      : s.userAgent!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${s.ip ?? ''}  Last used ${formatStamp(s.lastUsedAt)}'
                  '${s.current ? '  This device' : ''}',
                ),
                trailing: s.current
                    ? null
                    : TextButton(
                        key: Key('session.revoke.${s.id}'),
                        onPressed: () =>
                            run(() => repo.revokeSession(s.id), 'Signed out'),
                        child: const Text('Sign out'),
                      ),
              ),
            if (list.any((s) => !s.current))
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('session.revokeOthers'),
                  onPressed: () => run(
                    repo.revokeOtherSessions,
                    'Signed out everywhere else',
                  ),
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out everywhere else'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class NotificationPrefsCard extends ConsumerWidget {
  const NotificationPrefsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(notificationPrefsProvider);
    Future<void> save(String template, {bool? email, bool? whatsapp}) async {
      try {
        await ref
            .read(platformRepositoryProvider)
            .savePref(template, email: email, whatsapp: whatsapp);
        ref.invalidate(notificationPrefsProvider);
      } catch (e) {
        if (context.mounted) showErrorSnackBar(context, e);
      }
    }

    return SectionCard(
      title: 'Notifications',
      child: AsyncValueView<List<NotificationPref>>(
        value: prefs,
        onRetry: () => ref.invalidate(notificationPrefsProvider),
        data: (list) => Column(
          children: [
            for (final p in list)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 160),
                      child: Text(p.label),
                    ),
                    FilterChip(
                      key: Key('pref.${p.template}.email'),
                      label: const Text('Email'),
                      selected: p.email,
                      onSelected: p.mandatory
                          ? null
                          : (v) => save(p.template, email: v),
                    ),
                    if (p.whatsapp != null)
                      FilterChip(
                        key: Key('pref.${p.template}.whatsapp'),
                        label: const Text('WhatsApp'),
                        selected: p.whatsapp!,
                        onSelected: (v) => save(p.template, whatsapp: v),
                      ),
                    if (p.mandatory) const Pill('Required'),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
