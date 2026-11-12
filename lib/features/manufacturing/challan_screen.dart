import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'mfg_models.dart';
import 'mfg_pdf.dart';
import 'mfg_perms.dart';
import 'mfg_repository.dart';
import 'mfg_widgets.dart';

/// `/manufacturing/jobwork/:id`: one challan, its receipts and a receive form.
class ChallanScreen extends ConsumerWidget {
  const ChallanScreen({super.key, required this.challanId});

  final String challanId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CGate(
    anyOf: const [MfgPerm.view],
    child: AsyncValueView(
      value: ref.watch(mfgChallanProvider(challanId)),
      onRetry: () => ref.invalidate(mfgChallanProvider(challanId)),
      data: (c) => _ChallanView(challan: c),
    ),
  );
}

class _ChallanView extends ConsumerStatefulWidget {
  const _ChallanView({required this.challan});

  final Challan challan;

  @override
  ConsumerState<_ChallanView> createState() => _ChallanViewState();
}

class _ChallanViewState extends ConsumerState<_ChallanView> {
  bool _busy = false;

  Challan get c => widget.challan;

  Future<void> _cancel() async {
    final reason = await askReason(
      context,
      title: 'Cancel ${c.number}?',
      action: 'Cancel challan',
    );
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    final ok = await mfgGuarded(context, () async {
      await ref.read(mfgRepositoryProvider).cancelChallan(c.id, reason);
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.bumpMfg();
      mfgToast(context, 'Cancelled. Stock is back.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final canIssue = ref.mfgCan(MfgPerm.issue);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: '${c.number} · ${c.partyName}',
          subtitle: c.process,
          actions: [StatusChip(c.status)],
        ),
        Expanded(
          child: mfgBody(context, [
            Padding(
              padding: const EdgeInsets.only(bottom: Space.md),
              child: Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                children: [
                  if (canIssue && c.canReceive)
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              final ok = await showFormDialog<bool>(
                                context: context,
                                builder: (_) => _ReceiveDialog(challan: c),
                              );
                              if (ok == true && context.mounted) {
                                ref.bumpMfg();
                                mfgToast(context, 'Receipt saved.');
                              }
                            },
                      child: const Text('Receive goods'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () => printChallan(context, ref, c),
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('Print challan'),
                  ),
                  if (canIssue && c.canCancel && c.status == 'open')
                    TextButton(
                      onPressed: _busy ? null : _cancel,
                      child: const Text('Cancel challan'),
                    ),
                ],
              ),
            ),
            MfgCard(
              title: 'Details',
              child: Column(
                children: [
                  MfgKv('Job worker', c.partyName),
                  if ((c.partyGstin ?? '').isNotEmpty)
                    MfgKv('GSTIN', c.partyGstin!),
                  MfgKv('Sent from', c.locationName),
                  MfgKv('Sent on', formatDate(c.challanDate)),
                  if (c.expectedReturn != null)
                    MfgKv('Back by', formatDate(c.expectedReturn)),
                  if ((c.vehicleNo ?? '').isNotEmpty)
                    MfgKv('Vehicle', c.vehicleNo!),
                  MfgKv('Days out', '${c.ageDays}'),
                  if ((c.cancelReason ?? '').isNotEmpty)
                    MfgKv('Cancelled because', c.cancelReason!),
                ],
              ),
            ),
            MfgCard(
              title: 'Goods',
              child: Column(
                children: [
                  for (final l in c.lines)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.name),
                      subtitle: Text(
                        'Sent ${qtyUnit(l.qtySent, l.unit)} · back ${formatQty(l.qtyReceived)}'
                        '${l.qtyScrap > 0 ? ' · scrap ${formatQty(l.qtyScrap)}' : ''}'
                        ' · pending ${formatQty(l.qtyPending)}',
                      ),
                    ),
                ],
              ),
            ),
          ]),
        ),
      ],
    );
  }
}

class _ReceiveDialog extends ConsumerStatefulWidget {
  const _ReceiveDialog({required this.challan});

  final Challan challan;

  @override
  ConsumerState<_ReceiveDialog> createState() => _ReceiveDialogState();
}

class _ReceiveDialogState extends ConsumerState<_ReceiveDialog> {
  final _key = GlobalKey<FormState>();
  late final _lines = widget.challan.lines
      .where((l) => l.qtyPending > 0)
      .toList();
  late final _back = [
    for (final l in _lines)
      TextEditingController(text: formatPlain(l.qtyPending)),
  ];
  late final _scrap = [for (final _ in _lines) TextEditingController()];
  final _note = TextEditingController();
  bool _busy = false;

  Future<void> _save() async {
    if (!_key.currentState!.validate()) return;
    final lines = [
      for (var i = 0; i < _lines.length; i++)
        if ((parseNumber(_back[i].text) ?? 0) +
                (parseNumber(_scrap[i].text) ?? 0) >
            0)
          {
            'lineId': _lines[i].id,
            'qtyReceived': parseNumber(_back[i].text) ?? 0,
            if ((parseNumber(_scrap[i].text) ?? 0) > 0)
              'qtyScrap': parseNumber(_scrap[i].text),
          },
    ];
    if (lines.isEmpty) {
      return mfgError(context, 'Enter a quantity for at least one item.');
    }
    setState(() => _busy = true);
    final ok = await mfgGuarded(context, () async {
      await ref.read(mfgRepositoryProvider).receive(widget.challan.id, {
        'lines': lines,
        if (trimmedOrNull(_note.text) != null) 'note': _note.text.trim(),
      });
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Receive goods'),
    content: SizedBox(
      width: 440,
      child: Form(
        key: _key,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _lines.length; i++) ...[
                Text(
                  '${_lines[i].name} (pending ${qtyUnit(_lines[i].qtyPending, _lines[i].unit)})',
                ),
                if (_lines[i].returnName != _lines[i].name)
                  Text(
                    'Comes back as ${_lines[i].returnName}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: Space.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: mfgNumberField(
                        controller: _back[i],
                        label: 'Received',
                        required: false,
                        allowZero: true,
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: mfgNumberField(
                        controller: _scrap[i],
                        label: 'Scrap',
                        required: false,
                        allowZero: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.md),
              ],
              TextFormField(
                controller: _note,
                decoration: const InputDecoration(labelText: 'Note'),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
    ],
  );
}
