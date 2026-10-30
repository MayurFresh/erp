import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';

import '../../core/money.dart';
import '../../core/pdf_fonts.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import '../documents/document_widgets.dart';
import 'demand_pdf.dart';
import 're_models.dart';
import 're_perms.dart';
import 're_repository.dart';
import 're_widgets.dart';

/// `/demands/:id`.
class DemandDetailScreen extends ConsumerWidget {
  const DemandDetailScreen({super.key, required this.demandId});

  final String demandId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(rRevisionProvider(RKind.demands), (_, _) {
      ref.invalidate(demandProvider(demandId));
    });
    return CGate(
      anyOf: const [RePerm.bookingsView],
      child: AsyncValueView(
        value: ref.watch(demandProvider(demandId)),
        onRetry: () => ref.invalidate(demandProvider(demandId)),
        data: (d) => _DemandBody(demand: d),
      ),
    );
  }
}

class _DemandBody extends ConsumerWidget {
  const _DemandBody({required this.demand});

  final Demand demand;

  Future<List<int>> _pdf(WidgetRef ref) async {
    Company? company;
    try {
      company = await ref.read(companyRepositoryProvider).get();
    } catch (_) {
      company = ref.read(sessionProvider).value?.company;
    }
    return buildDemandPdf(
      demand,
      company ?? const Company(id: '', name: 'Company', stateCode: ''),
      theme: await pdfTheme(),
    );
  }

  Future<void> _print(BuildContext context, WidgetRef ref) async {
    try {
      final bytes = await _pdf(ref);
      await Printing.layoutPdf(
        onLayout: (_) async => Uint8List.fromList(bytes),
        name: demandFileName(demand),
      );
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _share(BuildContext context, WidgetRef ref) async {
    try {
      final bytes = await _pdf(ref);
      await Printing.sharePdf(
        bytes: Uint8List.fromList(bytes),
        filename: demandFileName(demand),
      );
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final reason = await showReasonDialog(
      context,
      title: 'Cancel demand ${demand.number}?',
      message:
          'The stages become undemanded again. A demand with receipts '
          'against it cannot be cancelled.',
      confirmLabel: 'Cancel demand',
    );
    if (reason == null || !context.mounted) return;
    final ok = await guarded(
      context,
      () => ref
          .read(realEstateRepositoryProvider)
          .cancelDemand(demand.id, reason),
    );
    if (ok) {
      ref.bumpR(const [RKind.demands, RKind.bookings], money: true);
      if (context.mounted) showSuccess(context, 'Demand cancelled');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final perms = ref.watch(permissionsProvider);
    final d = demand;
    final actions = [
      DocAction(
        label: 'Print',
        icon: Icons.print_outlined,
        primary: true,
        onPressed: () => _print(context, ref),
      ),
      DocAction(
        label: 'Share PDF',
        icon: Icons.ios_share,
        onPressed: () => _share(context, ref),
      ),
      if (perms.can(RePerm.bookingsView))
        DocAction(
          label: 'Open booking',
          icon: Icons.event_available_outlined,
          onPressed: () => context.go('/bookings/${d.bookingId}'),
        ),
      if (perms.can(RePerm.bookingsManage) && !d.isCancelled)
        DocAction(
          label: 'Cancel demand',
          icon: Icons.cancel_outlined,
          destructive: true,
          onPressed: () => _cancel(context, ref),
        ),
    ];
    return CPage(
      maxWidth: 900,
      children: [
        DocHeader(
          title: d.number,
          pills: demandStatusPills(d),
          actions: actions,
          facts: [
            LabeledValue('Date', formatDate(parseApiDate(d.date))),
            LabeledValue('Due date', formatDate(parseApiDate(d.dueDate))),
            LabeledValue('Booking', d.bookingNumber),
            LabeledValue('Unit', d.unitCode),
            LabeledValue('Customer', d.partyName),
            LabeledValue('Total', formatMoney(d.total)),
            LabeledValue('Received', formatMoney(d.amountPaid)),
            LabeledValue('Balance', formatMoney(d.amountDue)),
          ],
        ),
        if (d.isCancelled)
          Card(
            color: theme.colorScheme.errorContainer,
            margin: const EdgeInsets.only(bottom: 16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Cancelled ${formatDateTime(d.cancelledAt)}'
                '${(d.cancelReason ?? '').isEmpty ? '' : ': ${d.cancelReason}'}',
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ),
        SectionCard(
          title: 'Stages',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final s in d.stages)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${s.name} · ${formatPlain(s.pct)}%'),
                  trailing: Text(formatMoney(s.amount)),
                ),
              const Divider(),
              _line('Amount', d.amount),
              if (d.cgst > 0) _line('CGST', d.cgst),
              if (d.sgst > 0) _line('SGST', d.sgst),
              _line('Total', d.total, strong: true),
            ],
          ),
        ),
      ],
    );
  }

  Widget _line(String label, double value, {bool strong = false}) {
    final style = strong ? const TextStyle(fontWeight: FontWeight.w700) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: 8),
          Text(formatMoney(value), style: style),
        ],
      ),
    );
  }
}
