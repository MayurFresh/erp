import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/validators.dart';
import '../../widgets/busy.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../compliance/compliance_repository.dart';
import '../compliance/compliance_widgets.dart';
import '../filings/filing_widgets.dart';
import 'gst_filing_models.dart';
import 'gst_filing_repository.dart';
import 'gst_form_widgets.dart';

/// Credit / cash ledger snapshot form (balances copied from the portal) and
/// the history of snapshots.
class LedgerSnapshotSection extends ConsumerStatefulWidget {
  const LedgerSnapshotSection({super.key, required this.canManage});

  final bool canManage;

  @override
  ConsumerState<LedgerSnapshotSection> createState() => _LedgerState();
}

class _LedgerState extends ConsumerState<LedgerSnapshotSection>
    with DirtyTracking {
  final _form = GlobalKey<FormState>();
  final _c = {for (final h in gstHeads) h: TextEditingController()};
  final _note = TextEditingController();
  String _ledger = 'credit';
  DateTime _asOf = DateTime.now();

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    try {
      await runBlocking(
        context,
        () => ref.read(gstFilingRepositoryProvider).addLedgerBalance({
          'ledger': _ledger,
          'asOf': apiDate(_asOf),
          for (final h in gstHeads) h: money(_c[h]!),
          if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
        }),
      );
      ref.read(gstFilingRevisionProvider.notifier).bump();
      for (final c in _c.values) {
        c.clear();
      }
      _note.clear();
      markSaved();
      if (mounted) showInfoSnackBar(context, 'Balance saved.');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(ledgerSnapshotsProvider);
    return track(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Portal ledger balances',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Text(
            'Copy the balances from the portal (Ledgers, Electronic credit '
            'or cash ledger). The latest snapshot is used for set-off.',
          ),
          if (widget.canManage) ...[
            const SizedBox(height: 8),
            Form(
              key: _form,
              onChanged: markDirty,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormRow(
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: _ledger,
                        decoration: const InputDecoration(labelText: 'Ledger'),
                        items: const [
                          DropdownMenuItem(
                            value: 'credit',
                            child: Text('Electronic credit ledger'),
                          ),
                          DropdownMenuItem(
                            value: 'cash',
                            child: Text('Electronic cash ledger'),
                          ),
                        ],
                        isExpanded: true,
                        onChanged: (v) {
                          markDirty();
                          setState(() => _ledger = v ?? _ledger);
                        },
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: DayButton(
                          label: 'As of',
                          value: _asOf,
                          onChanged: (d) {
                            markDirty();
                            setState(() => _asOf = d ?? _asOf);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FormRow(
                    breakpoint: 640,
                    children: [
                      for (final h in gstHeads)
                        MoneyField(controller: _c[h]!, label: headLabel(h)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _note,
                    decoration: const InputDecoration(labelText: 'Note'),
                    validator: validateNotes,
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: BusyButton(
                      onPressed: _save,
                      label: 'Save balance',
                      icon: Icons.save_outlined,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          AsyncValueView<List<LedgerSnapshot>>(
            value: history,
            onRetry: () => ref.invalidate(ledgerSnapshotsProvider),
            data: (rows) => rows.isEmpty
                ? const Text('No balances recorded yet.')
                : Column(
                    children: [
                      for (final r in rows.take(10))
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${r.ledger == 'credit' ? 'Credit' : 'Cash'} ledger'
                            ' · ${formatDate(r.asOf)}',
                          ),
                          subtitle: Text(
                            [
                              for (final h in gstHeads)
                                '${headLabel(h)} ${formatAmount(r.heads[h])}',
                              if (r.note.isNotEmpty) r.note,
                            ].join(' · '),
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

/// PMT-06 payments of the year, with cancel.
class GstPaymentsSection extends ConsumerWidget {
  const GstPaymentsSection({
    super.key,
    required this.fy,
    required this.canManage,
  });

  final String fy;
  final bool canManage;

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    GstPayment p,
  ) async {
    final reason = await askReason(context, 'Cancel payment ${p.number}?');
    if (reason == null || !context.mounted) return;
    try {
      await runBlocking(
        context,
        () => ref.read(gstFilingRepositoryProvider).cancelPayment(p.id, reason),
      );
      ref.read(gstFilingRevisionProvider.notifier).bump();
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(gstPaymentsProvider(fy));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('GST payments', style: Theme.of(context).textTheme.titleMedium),
        AsyncValueView<List<GstPayment>>(
          value: value,
          onRetry: () => ref.invalidate(gstPaymentsProvider(fy)),
          data: (rows) => rows.isEmpty
              ? const Text('No PMT-06 payments recorded for this year.')
              : Column(
                  children: [
                    for (final p in rows)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${p.number} · ${formatMoney(p.total)}'),
                        subtitle: Text(
                          [
                            formatDate(p.date),
                            if (p.period != null) periodLabel(p.period!),
                            p.paidFromAccountName,
                            if (p.cin.isNotEmpty) 'CIN ${p.cin}',
                          ].join(' · '),
                        ),
                        trailing: p.cancelled
                            ? const StatusPill('cancelled')
                            : canManage
                            ? TextButton(
                                onPressed: () => _cancel(context, ref, p),
                                child: const Text('Cancel'),
                              )
                            : null,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Records a PMT-06 challan paid. [prefill] fills the heads.
Future<GstPayment?> showGstPaymentDialog(
  BuildContext context,
  WidgetRef ref, {
  required String period,
  Heads prefill = const Heads(),
  double interest = 0,
  double lateFee = 0,
}) => showDialog<GstPayment>(
  context: context,
  builder: (_) => _PaymentDialog(
    ref: ref,
    period: period,
    prefill: prefill,
    interest: interest,
    lateFee: lateFee,
  ),
);

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({
    required this.ref,
    required this.period,
    required this.prefill,
    required this.interest,
    required this.lateFee,
  });

  final WidgetRef ref;
  final String period;
  final Heads prefill;
  final double interest;
  final double lateFee;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> with DirtyTracking {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _c = {
    for (final h in gstHeads)
      h: TextEditingController(
        text: widget.prefill[h] > 0 ? formatPlain(widget.prefill[h]) : '',
      ),
    'interest': TextEditingController(
      text: widget.interest > 0 ? formatPlain(widget.interest) : '',
    ),
    'lateFee': TextEditingController(
      text: widget.lateFee > 0 ? formatPlain(widget.lateFee) : '',
    ),
    'cpin': TextEditingController(),
    'cin': TextEditingController(),
  };
  DateTime _date = DateTime.now();
  AccountOption? _account;
  String? _error;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickAccount() async {
    final a = await pickAccount(
      context,
      widget.ref,
      title: 'Paid from',
      where: (a) => a.subtype == 'cash' || a.subtype == 'bank',
    );
    if (a != null) {
      markDirty();
      setState(() => _account = a);
    }
  }

  Future<void> _save() async {
    final ok = _form.currentState!.validate();
    final total = [
      for (final k in [...gstHeads, 'interest', 'lateFee']) money(_c[k]!),
    ].fold<double>(0, (a, b) => a + b);
    setState(() {
      _error = _account == null
          ? 'Choose the cash or bank account paid from'
          : total <= 0
          ? 'Enter at least one amount'
          : null;
    });
    if (!ok || _error != null) return;
    try {
      final p = await runBlocking(
        context,
        () => widget.ref.read(gstFilingRepositoryProvider).createPayment({
          'date': apiDate(_date),
          'period': widget.period,
          'paidFromAccountId': _account!.id,
          for (final h in gstHeads) h: money(_c[h]!),
          'interest': money(_c['interest']!),
          'lateFee': money(_c['lateFee']!),
          if (_c['cpin']!.text.trim().isNotEmpty)
            'cpin': _c['cpin']!.text.trim(),
          if (_c['cin']!.text.trim().isNotEmpty) 'cin': _c['cin']!.text.trim(),
        }),
      );
      if (p == null) return;
      widget.ref.read(gstFilingRevisionProvider.notifier).bump();
      markSaved();
      if (mounted) Navigator.of(context).pop(p);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => track(
    AlertDialog(
      title: const Text('Record PMT-06 payment'),
      content: SingleChildScrollView(
        child: Form(
          key: _form,
          onChanged: markDirty,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: DayButton(
                  label: 'Paid on',
                  value: _date,
                  onChanged: (d) {
                    markDirty();
                    setState(() => _date = d ?? _date);
                  },
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _pickAccount,
                icon: const Icon(Icons.account_balance_outlined),
                label: Text(
                  _account == null ? 'Paid from account' : _account!.label,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              for (final h in gstHeads) ...[
                const SizedBox(height: 8),
                MoneyField(controller: _c[h]!, label: headLabel(h)),
              ],
              const SizedBox(height: 8),
              MoneyField(controller: _c['interest']!, label: 'Interest'),
              const SizedBox(height: 8),
              MoneyField(controller: _c['lateFee']!, label: 'Late fee'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _c['cpin'],
                decoration: const InputDecoration(labelText: 'CPIN'),
                validator: (v) => maxLength(v, 30, 'CPIN'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _c['cin'],
                decoration: const InputDecoration(labelText: 'CIN'),
                validator: (v) => maxLength(v, 30, 'CIN'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        BusyButton(onPressed: _save, label: 'Record', icon: Icons.check),
      ],
    ),
  );
}
