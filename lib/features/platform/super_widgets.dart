import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/status_chip.dart';
import 'super_models.dart';

/// `kirana` → `Kirana`, `real_estate` → `Real estate`.
String prettyKey(String? key) {
  if (key == null || key.isEmpty || key == 'none') return 'Not set';
  final t = key.replaceAll('_', ' ');
  return t[0].toUpperCase() + t.substring(1);
}

String whenText(DateTime? value) =>
    value == null ? 'Never' : formatDateTime(value.toLocal());

/// Active or Suspended.
class TenantStatusChip extends StatelessWidget {
  const TenantStatusChip(this.tenant, {super.key});

  final SuperTenant tenant;

  @override
  Widget build(BuildContext context) => StatusChip(
    tenant.status,
    label: tenant.suspended ? 'Suspended' : 'Active',
    tone: tenant.suspended ? StatusTone.danger : StatusTone.success,
  );
}

/// Asks for confirmation. Returns true when the admin agrees.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool danger = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          key: const Key('confirm-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-ok'),
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Asks for a reason of at least 3 characters. Returns it, or null on cancel.
Future<String?> askReason(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      _ReasonDialog(title: title, message: message, confirmLabel: confirmLabel),
);

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.length < 3) {
      setState(() => _error = 'Give a reason of at least 3 characters');
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: Space.md),
          TextField(
            key: const Key('reason-field'),
            controller: _controller,
            autofocus: true,
            maxLength: 500,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(labelText: 'Reason', errorText: _error),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const Key('reason-cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('reason-ok'),
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.error,
          foregroundColor: Theme.of(context).colorScheme.onError,
        ),
        onPressed: _submit,
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}

/// Shows a password reset link with a copy button.
Future<void> showResetLink(
  BuildContext context,
  SuperUser user,
  ResetLink l,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Password reset link'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Share this link with ${user.name}. It works once'
            '${l.expiresAt == null ? '' : ' and expires ${whenText(l.expiresAt)}'}.',
          ),
          const SizedBox(height: Space.md),
          SelectableText(l.link, key: const Key('reset-link-text')),
        ],
      ),
    ),
    actions: [
      TextButton.icon(
        key: const Key('reset-link-copy'),
        icon: const Icon(Icons.copy_outlined, size: 18),
        label: const Text('Copy link'),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: l.link));
          if (context.mounted) {
            ScaffoldMessenger.maybeOf(
              context,
            )?.showSnackBar(const SnackBar(content: Text('Link copied')));
          }
        },
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Done'),
      ),
    ],
  ),
);
