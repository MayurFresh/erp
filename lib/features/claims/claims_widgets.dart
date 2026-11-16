import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/money_text.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import 'claims_models.dart';

/// Runs [action], shows the API message when it fails. Returns true on success.
Future<bool> guarded(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
    return true;
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
    return false;
  }
}

/// Asks for one line of text. Returns null when cancelled.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  required String action,
  bool required = true,
}) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLines: 3,
        decoration: InputDecoration(labelText: label),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (required && c.text.trim().length < 3) return;
            Navigator.pop(ctx, c.text.trim());
          },
          child: Text(action),
        ),
      ],
    ),
  );
}

/// A tappable summary of one claim.
class ClaimTile extends StatelessWidget {
  const ClaimTile({super.key, required this.claim, required this.onTap, this.showEmployee = false});

  final Claim claim;
  final VoidCallback onTap;
  final bool showEmployee;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: Space.sm),
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Layout.touchTarget),
          child: Padding(
            padding: const EdgeInsets.all(Space.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        claim.purpose,
                        style: theme.textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    MoneyText(claim.total),
                  ],
                ),
                const SizedBox(height: Space.xs),
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusChip(claim.status),
                    Text(
                      '${claim.number}  ${formatDate(claim.claimDate)}${showEmployee ? '  ${claim.employeeName}' : ''}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Picks the cash or bank account for a payment.
Future<String?> pickAccount(BuildContext context, List<(String, String)> accounts) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Pay from'),
      children: [
        for (final a in accounts)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, a.$1),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.sm),
              child: Text(a.$2),
            ),
          ),
      ],
    ),
  );
}
