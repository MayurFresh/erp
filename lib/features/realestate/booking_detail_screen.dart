import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import 're_models.dart';
import 're_perms.dart';
import 're_repository.dart';
import 're_widgets.dart';

/// `/bookings/:id`: schedule, totals and the sales actions.
class BookingDetailScreen extends ConsumerWidget {
  const BookingDetailScreen({super.key, required this.bookingId});

  final String bookingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(rRevisionProvider(RKind.bookings), (_, _) {
      ref.invalidate(bookingProvider(bookingId));
    });
    return CGate(
      anyOf: const [RePerm.bookingsView],
      child: AsyncValueView(
        value: ref.watch(bookingProvider(bookingId)),
        onRetry: () => ref.invalidate(bookingProvider(bookingId)),
        data: (b) => _BookingBody(booking: b),
      ),
    );
  }
}

class _BookingBody extends ConsumerWidget {
  const _BookingBody({required this.booking});

  final Booking booking;

  void _changed(WidgetRef ref) => ref.bumpR(const [
    RKind.bookings,
    RKind.units,
    RKind.demands,
  ], money: true);

  Future<void> _raiseDemand(BuildContext context, WidgetRef ref) async {
    final demand = await showDialog<Demand>(
      context: context,
      builder: (_) => RaiseDemandDialog(booking: booking),
    );
    if (demand == null) return;
    _changed(ref);
    if (context.mounted) {
      showSuccess(context, 'Demand ${demand.number} raised');
      context.go('/demands/${demand.id}');
    }
  }

  Future<void> _agreement(BuildContext context, WidgetRef ref) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => AgreementDialog(booking: booking),
    );
    if (done == true) {
      _changed(ref);
      if (context.mounted) showSuccess(context, 'Agreement recorded');
    }
  }

  Future<void> _possession(BuildContext context, WidgetRef ref) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => PossessionDialog(booking: booking),
    );
    if (done == true) {
      _changed(ref);
      if (context.mounted) showSuccess(context, 'Possession recorded');
    }
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final reason = await showReasonDialog(
      context,
      title: 'Cancel booking ${booking.number}?',
      message:
          'The unit goes back on sale. Open demands are cancelled only if '
          'nothing has been received against them.',
      confirmLabel: 'Cancel booking',
    );
    if (reason == null || !context.mounted) return;
    final ok = await guarded(
      context,
      () => ref
          .read(realEstateRepositoryProvider)
          .cancelBooking(booking.id, reason),
    );
    if (ok) {
      _changed(ref);
      if (context.mounted) showSuccess(context, 'Booking cancelled');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final perms = ref.watch(permissionsProvider);
    final manage = perms.can(RePerm.bookingsManage);
    final b = booking;
    final live = !b.isCancelled;
    final actions = <DocAction>[
      if (manage && live && b.status != BookingStatus.possession)
        DocAction(
          label: 'Raise demand',
          icon: Icons.request_quote_outlined,
          primary: true,
          onPressed: b.undemandedStages.isEmpty
              ? () => showInfoSnackBar(context, 'Every stage is demanded.')
              : () => _raiseDemand(context, ref),
        ),
      if (manage && b.status == BookingStatus.booked)
        DocAction(
          label: 'Record agreement',
          icon: Icons.handshake_outlined,
          onPressed: () => _agreement(context, ref),
        ),
      if (manage && b.status == BookingStatus.agreement)
        DocAction(
          label: 'Record possession',
          icon: Icons.key_outlined,
          primary: true,
          onPressed: () => _possession(context, ref),
        ),
      if (manage && live && b.status != BookingStatus.possession)
        DocAction(
          label: 'Cancel booking',
          icon: Icons.cancel_outlined,
          destructive: true,
          onPressed: () => _cancel(context, ref),
        ),
    ];
    return CPage(
      maxWidth: 1000,
      children: [
        DocHeader(
          title: b.number,
          pills: bookingStatusPill(b.status),
          actions: actions,
          facts: [
            LabeledValue('Date', formatDate(parseApiDate(b.date))),
            LabeledValue('Project', b.projectName),
            LabeledValue('Unit', b.unitCode),
            LabeledValue('Customer', b.customerName),
            LabeledValue('Agreement value', formatMoney(b.agreementValue)),
            LabeledValue('GST', '${formatPlain(b.gstPct)}%'),
            LabeledValue('Plan', b.paymentPlanName ?? '—'),
            if (b.agreementNo != null)
              LabeledValue(
                'Agreement',
                '${b.agreementNo} · '
                    '${formatDate(parseApiDate(b.agreementDate))}',
              ),
            if (b.possessionDate != null)
              LabeledValue(
                'Possession',
                formatDate(parseApiDate(b.possessionDate)),
              ),
          ],
        ),
        if (b.isCancelled)
          Card(
            color: theme.colorScheme.errorContainer,
            margin: const EdgeInsets.only(bottom: 16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Cancelled ${formatDateTime(b.cancelledAt)}'
                '${(b.cancelReason ?? '').isEmpty ? '' : ': ${b.cancelReason}'}',
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ),
        SectionCard(
          title: 'Summary',
          child: Wrap(
            spacing: 32,
            runSpacing: 12,
            children: [
              LabeledValue('Demanded', formatMoney(b.totals.demanded)),
              LabeledValue('GST on demands', formatMoney(b.totals.gst)),
              LabeledValue('Received', formatMoney(b.totals.received)),
              LabeledValue('Due', formatMoney(b.totals.due)),
              LabeledValue(
                'Not yet demanded',
                formatMoney(b.totals.undemanded),
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Payment schedule',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (b.status == BookingStatus.booked && live)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Before the agreement is recorded, demands may total at '
                    'most ${formatMoney(b.preAgreementCap)} (10% of the '
                    'agreement value).',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              for (final s in b.stages) _StageRow(stage: s),
            ],
          ),
        ),
      ],
    );
  }
}

class _StageRow extends ConsumerWidget {
  const _StageRow({required this.stage});

  final BookingStage stage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canOpen =
        stage.demandId != null &&
        ref.watch(permissionsProvider).can(RePerm.bookingsView);
    return InkWell(
      onTap: canOpen ? () => context.go('/demands/${stage.demandId}') : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${stage.name} · ${formatPlain(stage.pct)}%',
                    style: theme.textTheme.bodyLarge,
                  ),
                  if (stage.isDemanded)
                    Text(
                      'Demand ${stage.demandNumber ?? ''}',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Wrap(
                spacing: 8,
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    formatMoney(stage.amount),
                    style: theme.textTheme.bodyLarge,
                  ),
                  Pill(
                    stage.isDemanded ? 'Demanded' : 'Not demanded',
                    color: stage.isDemanded
                        ? Colors.green.shade700
                        : Colors.grey,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Multi-select of the undemanded stages. Pops the new [Demand].
class RaiseDemandDialog extends ConsumerStatefulWidget {
  const RaiseDemandDialog({super.key, required this.booking});

  final Booking booking;

  @override
  ConsumerState<RaiseDemandDialog> createState() => _RaiseDemandDialogState();
}

class _RaiseDemandDialogState extends ConsumerState<RaiseDemandDialog> {
  final Set<String> _selected = {};
  DateTime _date = today();
  DateTime? _due;
  bool _busy = false;

  double get _total => widget.booking.stages
      .where((s) => _selected.contains(s.id))
      .fold(0, (a, s) => a + s.amount);

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final demand = await ref
          .read(realEstateRepositoryProvider)
          .raiseDemand(
            widget.booking.id,
            stageIds: _selected.toList(),
            date: apiDate(_date),
            dueDate: _due == null ? null : apiDate(_due!),
          );
      if (mounted) Navigator.of(context).pop(demand);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.booking;
    final open = b.undemandedStages;
    final theme = Theme.of(context);
    final cap = b.status == BookingStatus.booked;
    final overCap = cap && b.totals.demanded + _total > b.preAgreementCap;
    return AlertDialog(
      title: const Text('Raise demand'),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final s in open)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _selected.contains(s.id),
                onChanged: (v) => setState(
                  () =>
                      v == true ? _selected.add(s.id) : _selected.remove(s.id),
                ),
                title: Text('${s.name} · ${formatPlain(s.pct)}%'),
                secondary: Text(formatMoney(s.amount)),
              ),
            const Divider(),
            Text(
              'Selected: ${formatMoney(_total)} before GST',
              style: theme.textTheme.titleSmall,
            ),
            if (cap)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Until the agreement is recorded, demands may total at most '
                  '${formatMoney(b.preAgreementCap)} (10%).',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: overCap ? theme.colorScheme.error : null,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            DateField(
              label: 'Demand date',
              value: _date,
              onChanged: (d) => setState(() => _date = d),
            ),
            const SizedBox(height: 16),
            DateField(
              label: 'Due date (default: date + 15 days)',
              value: _due,
              onChanged: (d) => setState(() => _due = d),
              onCleared: () => setState(() => _due = null),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        BusyButton(
          busy: _busy,
          onPressed: _selected.isEmpty ? null : _submit,
          label: 'Raise demand',
        ),
      ],
    );
  }
}

/// Registered agreement number and date. Pops `true`.
class AgreementDialog extends ConsumerStatefulWidget {
  const AgreementDialog({super.key, required this.booking});

  final Booking booking;

  @override
  ConsumerState<AgreementDialog> createState() => _AgreementDialogState();
}

class _AgreementDialogState extends ConsumerState<AgreementDialog> {
  final _formKey = GlobalKey<FormState>();
  final _no = TextEditingController();
  DateTime _date = today();
  bool _busy = false;

  @override
  void dispose() {
    _no.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(realEstateRepositoryProvider)
          .recordAgreement(
            widget.booking.id,
            agreementNo: _no.text.trim(),
            agreementDate: apiDate(_date),
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Record agreement'),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _no,
              decoration: const InputDecoration(labelText: 'Agreement number'),
              validator: (v) => requiredField(v, 'Agreement number'),
            ),
            const SizedBox(height: 16),
            DateField(
              label: 'Agreement date',
              value: _date,
              onChanged: (d) => setState(() => _date = d),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      BusyButton(busy: _busy, onPressed: _submit, label: 'Record'),
    ],
  );
}

/// Possession date. Pops `true`.
class PossessionDialog extends ConsumerStatefulWidget {
  const PossessionDialog({super.key, required this.booking});

  final Booking booking;

  @override
  ConsumerState<PossessionDialog> createState() => _PossessionDialogState();
}

class _PossessionDialogState extends ConsumerState<PossessionDialog> {
  DateTime _date = today();
  bool _busy = false;

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(realEstateRepositoryProvider)
          .recordPossession(widget.booking.id, apiDate(_date));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.booking.undemandedStages.length;
    return AlertDialog(
      title: const Text('Record possession'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              pending > 0
                  ? '$pending stage${pending == 1 ? ' is' : 's are'} not '
                        'demanded yet. Raise demands for every stage first.'
                  : 'Every stage is demanded. Possession posts the sale to '
                        'the books.',
            ),
            const SizedBox(height: 16),
            DateField(
              label: 'Possession date',
              value: _date,
              onChanged: (d) => setState(() => _date = d),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        BusyButton(busy: _busy, onPressed: _submit, label: 'Record'),
      ],
    );
  }
}
