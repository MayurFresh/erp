import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../auth/session.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_picker.dart';
import '../../widgets/states.dart';
import '../reports/report_widgets.dart' show StatRow, StatTile, tabularFigures;
import 'compliance_models.dart';
import 'compliance_repository.dart';
import 'compliance_widgets.dart';
import 'tax_perms.dart';

/// `/gst-2b`: import GSTR-2B and reconcile it with the purchase books.
class Gst2bScreen extends ConsumerStatefulWidget {
  const Gst2bScreen({super.key});

  @override
  ConsumerState<Gst2bScreen> createState() => _Gst2bScreenState();
}

class _Gst2bScreenState extends ConsumerState<Gst2bScreen> {
  String _period = previousMonth();
  ReconStatus? _filter;
  bool _busy = false;

  Future<void> _import() async {
    try {
      final file = await pickTextFile(const ['json', 'csv']);
      if (file == null) return;
      setState(() => _busy = true);
      final isCsv = file.name.toLowerCase().endsWith('.csv');
      final result = await ref
          .read(complianceRepositoryProvider)
          .import2b(
            period: _period,
            fileName: file.name,
            data: isCsv ? null : jsonDecode(file.text),
            csv: isCsv ? file.text : null,
          );
      ref.read(complianceRevisionProvider.notifier).bump();
      if (!mounted) return;
      showInfoSnackBar(
        context,
        'Imported ${result['lines']} lines: ${result['matched']} matched, '
        '${result['mismatch']} mismatched, ${result['missingInBooks']} '
        'missing in books.',
      );
    } on FormatException {
      if (mounted) showErrorSnackBar(context, 'That is not a valid JSON file.');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _patch(ReconRow row, Map<String, dynamic> body) async {
    try {
      await ref.read(complianceRepositoryProvider).patch2bLine(row.id!, body);
      ref.read(complianceRevisionProvider.notifier).bump();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _link(ReconRow row) async {
    final repo = ref.read(complianceRepositoryProvider);
    final p = await showSearchPicker<PurchaseOption>(
      context: context,
      title: 'Link to purchase',
      hintText: 'Bill number, supplier invoice or supplier',
      search: (q) => repo.purchases(q: q),
      titleBuilder: (_, p) => Text('${p.number} · ${p.partyName}'),
      subtitleBuilder: (_, p) => Text(
        '${p.supplierInvoiceNo.isEmpty ? '' : 'Inv ${p.supplierInvoiceNo} · '}'
        '${formatDate(p.billDate)}',
      ),
      trailingBuilder: (_, p) => Text(formatMoney(p.total)),
    );
    if (p != null) await _patch(row, {'purchaseId': p.id});
  }

  @override
  Widget build(BuildContext context) {
    final can = ref.watch(permissionsProvider).can(TaxPerm.gstManage);
    final value = ref.watch(reconProvider(_period));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'GSTR-2B reconciliation',
          subtitle: 'Supplier-reported input tax against your purchases',
          actions: [
            if (can)
              BusyButton(
                busy: _busy,
                onPressed: _import,
                label: 'Import 2B file',
                icon: Icons.upload_file,
              ),
          ],
        ),
        FilterBar(
          children: [
            MonthPicker(
              period: _period,
              onChanged: (p) => setState(() => _period = p),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView<Recon>(
            value: value,
            onRetry: () => ref.invalidate(reconProvider(_period)),
            data: (r) => _content(r, can),
          ),
        ),
      ],
    );
  }

  Widget _content(Recon r, bool can) {
    final rows = _filter == null
        ? r.rows
        : r.rows.where((x) => x.status == _filter).toList();
    final s = r.summary;
    int count(ReconStatus st) => switch (st) {
      ReconStatus.matched => s.matched,
      ReconStatus.mismatch => s.mismatch,
      ReconStatus.missingInBooks => s.missingInBooks,
      ReconStatus.missingIn2b => s.missingIn2b,
    };
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        const WarningsBanner([
          'No action in IMS may count as accepted on the GST portal. '
              'Reject or hold invoices you do not agree with before filing.',
        ]),
        if (r.importedAt == null)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'No GSTR-2B has been imported for this month. Books-only rows '
              'are shown as missing in 2B.',
            ),
          ),
        StatRow(
          children: [
            StatTile(
              label: 'Matched',
              value: '${s.matched}',
              caption: 'ITC ${formatMoney(s.itcMatched.tax)}',
            ),
            StatTile(label: 'Mismatch', value: '${s.mismatch}'),
            StatTile(label: 'Missing in books', value: '${s.missingInBooks}'),
            StatTile(label: 'Missing in 2B', value: '${s.missingIn2b}'),
            StatTile(
              label: 'ITC at risk',
              value: formatMoney(s.itcAtRisk.tax),
              color: s.itcAtRisk.tax > 0
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            ChoiceChip(
              label: Text('All (${r.rows.length})'),
              selected: _filter == null,
              onSelected: (_) => setState(() => _filter = null),
            ),
            for (final st in ReconStatus.values)
              ChoiceChip(
                label: Text('${st.label} (${count(st)})'),
                selected: _filter == st,
                onSelected: (_) => setState(() => _filter = st),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('No rows for this filter.')),
          ),
        for (final row in rows)
          _ReconCard(
            row: row,
            canManage: can,
            onIms: (a) => _patch(row, {'imsAction': a}),
            onLink: () => _link(row),
            onUnlink: () => _patch(row, {'purchaseId': null}),
          ),
      ],
    );
  }
}

class _ReconCard extends StatelessWidget {
  const _ReconCard({
    required this.row,
    required this.canManage,
    required this.onIms,
    required this.onLink,
    required this.onUnlink,
  });

  final ReconRow row;
  final bool canManage;
  final ValueChanged<String> onIms;
  final VoidCallback onLink;
  final VoidCallback onUnlink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final diff = row.diff;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      StatusPill(row.status.wire, label: row.status.label),
                      if (row.imsAction != 'none')
                        Pill('IMS: ${row.imsAction}'),
                      Text(
                        row.supplierName.isEmpty
                            ? row.supplierGstin
                            : row.supplierName,
                        style: theme.textTheme.titleSmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${row.supplierGstin} · ${row.docType} ${row.docNo} · '
                    '${formatDate(row.docDate)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 16,
                    children: [
                      Text(
                        'Taxable ${formatAmount(row.tax.taxable)}',
                        style: tabularFigures,
                      ),
                      Text(
                        'Tax ${formatAmount(row.tax.tax)}',
                        style: tabularFigures,
                      ),
                      if (row.purchaseNumber != null)
                        Text('Books: ${row.purchaseNumber}'),
                    ],
                  ),
                  if (diff != null && row.status == ReconStatus.mismatch)
                    Text(
                      'Difference vs books: taxable ${formatAmount(diff.taxable)}, '
                      'tax ${formatAmount(diff.tax)}',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  if (row.note.isNotEmpty)
                    Text(row.note, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            if (canManage && row.id != null)
              PopupMenuButton<String>(
                tooltip: 'IMS action and link',
                onSelected: (v) => switch (v) {
                  'link' => onLink(),
                  'unlink' => onUnlink(),
                  _ => onIms(v),
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    enabled: false,
                    child: Text('IMS action'),
                  ),
                  for (final a in const ['accept', 'reject', 'pending', 'none'])
                    CheckedPopupMenuItem(
                      value: a,
                      checked: row.imsAction == a,
                      child: Text(a[0].toUpperCase() + a.substring(1)),
                    ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'link',
                    child: Text('Link to purchase'),
                  ),
                  if (row.purchaseId != null)
                    const PopupMenuItem(
                      value: 'unlink',
                      child: Text('Remove link'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
