import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, bigOutlinedButton, showSuccess;
import '../items/item_picker.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'timesheet_models.dart';
import 'timesheet_repository.dart';

/// `/timesheets/billing`: bill unbilled time, hourly rates and settings.
class BillingScreen extends ConsumerStatefulWidget {
  const BillingScreen({super.key});

  @override
  ConsumerState<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends ConsumerState<BillingScreen> {
  bool _busy = false;

  Future<void> _guard(Future<void> Function() job, String done) async {
    setState(() => _busy = true);
    try {
      await job();
      ref.read(timesheetRevisionProvider.notifier).bump();
      if (mounted) showSuccess(context, done);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bill(List<String> parties) => _guard(() async {
    final r = await ref.read(timesheetRepositoryProvider).bill(parties);
    final skipped = asJsonList(r['skipped']);
    if (skipped.isNotEmpty && mounted) {
      showInfoSnackBar(
        context,
        '${skipped.length} customer(s) skipped: no hourly rate set.',
      );
    }
  }, 'Invoices created');

  Future<void> _addRate() async {
    Party? party;
    String? userId;
    final rate = TextEditingController();
    final staff = ref.read(timesheetStaffProvider).value ?? const [];
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Hourly rate'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String?>(
                  initialValue: userId,
                  decoration: const InputDecoration(labelText: 'Person'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Anyone')),
                    for (final s in staff)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => set(() => userId = v),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  style: bigOutlinedButton,
                  onPressed: () async {
                    final p = await pickParty(
                      ctx,
                      ref,
                      type: PartyType.customer,
                    );
                    if (p != null) set(() => party = p);
                  },
                  child: Text(party?.name ?? 'Any customer'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: rate,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Rate per hour'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).maybePop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    final value = parseIndianNumber(rate.text);
    if (ok != true || value == null || (userId == null && party == null)) {
      return;
    }
    await _guard(
      () async => ref.read(timesheetRepositoryProvider).saveRate({
        'userId': ?userId,
        if (party != null) 'partyId': party!.id,
        'rate': value,
      }),
      'Rate saved',
    );
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final canBill = perms.can(Perm.timesheetsBill);
    final unbilled = ref.watch(unbilledProvider);
    final settings = ref.watch(timesheetSettingsProvider);
    final rates = ref.watch(ratesProvider);
    final gutter = pageGutter(context);
    return CGate(
      anyOf: const [Perm.timesheetsBill],
      child: ListView(
        padding: EdgeInsets.only(bottom: gutter),
        children: [
          const PageHeader(title: 'Bill time'),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionCard(
                  title: 'Approved time not yet billed',
                  child: AsyncValueView<List<Json>>(
                    value: unbilled,
                    data: (list) => list.isEmpty
                        ? const Text('Nothing to bill.')
                        : Column(
                            children: [
                              for (final u in list)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(asString(u['partyName'])),
                                  subtitle: Text(
                                    '${hoursText(asDouble(u['hours']))} h, '
                                    '${formatMoney(asDouble(u['amount']))} before GST',
                                  ),
                                  trailing: OutlinedButton(
                                    style: bigOutlinedButton,
                                    onPressed: _busy
                                        ? null
                                        : () => _bill([asString(u['partyId'])]),
                                    child: const Text('Bill'),
                                  ),
                                ),
                              const SizedBox(height: 8),
                              FilledButton(
                                style: bigButton,
                                onPressed: _busy
                                    ? null
                                    : () => _bill([
                                        for (final u in list)
                                          asString(u['partyId']),
                                      ]),
                                child: const Text('Bill all customers'),
                              ),
                            ],
                          ),
                  ),
                ),
                SectionCard(
                  title: 'Billing settings',
                  child: AsyncValueView<Json>(
                    value: settings,
                    data: (s) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          s['serviceItemId'] == null
                              ? 'No service item chosen yet.'
                              : 'A service item is set for bills.',
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          style: bigOutlinedButton,
                          onPressed: _busy
                              ? null
                              : () async {
                                  final i = await pickItem(context, ref);
                                  if (i == null) return;
                                  await _guard(
                                    () async => ref
                                        .read(timesheetRepositoryProvider)
                                        .saveSettings({'serviceItemId': i.id}),
                                    'Service item saved',
                                  );
                                },
                          child: const Text('Choose the service item'),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Hours need approval before billing',
                          ),
                          value: asBool(s['approvalRequired'], true),
                          onChanged: _busy
                              ? null
                              : (v) => _guard(
                                  () async => ref
                                      .read(timesheetRepositoryProvider)
                                      .saveSettings({'approvalRequired': v}),
                                  'Saved',
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                SectionCard(
                  title: 'Hourly rates',
                  trailing: TextButton(
                    onPressed: _busy ? null : _addRate,
                    child: const Text('Add rate'),
                  ),
                  child: AsyncValueView<List<Json>>(
                    value: rates,
                    data: (list) => list.isEmpty
                        ? const Text(
                            'No rates yet. Hours without a rate bill at zero and are skipped.',
                          )
                        : Column(
                            children: [
                              for (final r in list)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    '${r['userName'] ?? 'Anyone'}'
                                    ' for ${r['partyName'] ?? 'any customer'}',
                                  ),
                                  subtitle: Text(
                                    '${formatMoney(asDouble(r['rate']))} per hour',
                                  ),
                                  trailing: IconButton(
                                    tooltip: 'Remove rate',
                                    constraints: const BoxConstraints(
                                      minWidth: 48,
                                      minHeight: 48,
                                    ),
                                    onPressed: !canBill || _busy
                                        ? null
                                        : () => _guard(
                                            () => ref
                                                .read(
                                                  timesheetRepositoryProvider,
                                                )
                                                .deleteRate(asString(r['id'])),
                                            'Rate removed',
                                          ),
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                                ),
                            ],
                          ),
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
