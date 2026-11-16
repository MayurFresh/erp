import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'claims_models.dart';
import 'claims_repository.dart';
import 'claims_widgets.dart';

/// `/claims/categories`: claim categories with optional limits.
class ClaimCategoriesScreen extends ConsumerWidget {
  const ClaimCategoriesScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, ClaimCategory? c) async {
    final name = TextEditingController(text: c?.name ?? '');
    final perClaim = TextEditingController(text: c?.perClaimLimit?.toString() ?? '');
    final monthly = TextEditingController(text: c?.monthlyLimit?.toString() ?? '');
    var itc = c?.gstItcAllowed ?? false;
    var receipt = c?.requiresReceipt ?? false;
    var active = c?.isActive ?? true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(c == null ? 'New category' : 'Edit category'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
                TextField(
                  controller: perClaim,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Limit for one claim (blank for none)'),
                ),
                TextField(
                  controller: monthly,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Limit for a month (blank for none)'),
                ),
                SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Bill needs a receipt'), value: receipt, onChanged: (v) => setS(() => receipt = v)),
                SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Claim GST input credit'), value: itc, onChanged: (v) => setS(() => itc = v)),
                if (c != null)
                  SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('In use'), value: active, onChanged: (v) => setS(() => active = v)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final body = {
      'name': name.text.trim(),
      'perClaimLimit': double.tryParse(perClaim.text.trim()),
      'monthlyLimit': double.tryParse(monthly.text.trim()),
      'requiresReceipt': receipt,
      'gstItcAllowed': itc,
      if (c != null) 'isActive': active,
    };
    if (await guarded(context, () => ref.read(claimsRepositoryProvider).saveCategory(c?.id, body))) {
      ref.read(claimsRevisionProvider.notifier).bump();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(claimCategoriesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Claim categories',
          subtitle: 'Limits are per employee',
          actions: [
            FilledButton.icon(
              onPressed: () => _edit(context, ref, null),
              icon: const Icon(Icons.add),
              label: const Text('New category'),
            ),
          ],
        ),
        Expanded(
          child: async.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(claimCategoriesProvider)),
            data: (cats) => ListView(
              padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
              children: [
                for (final c in cats)
                  Card(
                    margin: const EdgeInsets.only(bottom: Space.sm),
                    child: ListTile(
                      minVerticalPadding: Space.md,
                      title: Text(c.isActive ? c.name : '${c.name} (not in use)'),
                      subtitle: Text([
                        c.perClaimLimit == null ? 'No claim limit' : 'Claim up to ${formatMoney(c.perClaimLimit)}',
                        c.monthlyLimit == null ? 'No monthly limit' : 'Month up to ${formatMoney(c.monthlyLimit)}',
                        if (c.requiresReceipt) 'Receipt needed',
                        if (c.gstItcAllowed) 'Input credit',
                      ].join(', ')),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () => _edit(context, ref, c),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
