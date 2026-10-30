import 'package:flutter/material.dart';

import '../../core/money.dart';
import '../compliance/compliance_widgets.dart';
import '../filings/filing_widgets.dart';
import 'gst_filing_models.dart';
import 'gst_form_widgets.dart';

/// The set-off result: summary by head, the utilisation matrix and the
/// PMT-06 amounts. Pure display; the caller owns the IGST-split toggle.
class SetoffView extends StatelessWidget {
  const SetoffView({
    super.key,
    required this.setoff,
    required this.split,
    required this.onSplit,
    this.onRecordPayment,
  });

  final Setoff setoff;
  final String split;
  final ValueChanged<String> onSplit;
  final VoidCallback? onRecordPayment;

  static DataCell _n(double v) => DataCell(Text(formatAmount(v)));

  @override
  Widget build(BuildContext context) {
    final s = setoff;
    final theme = Theme.of(context);
    final matrix = <String, double>{
      for (final m in s.matrix) '${m.from}>${m.to}': m.amount,
    };
    final pmt = [
      for (final h in gstHeads)
        if (s.pmt06[h] > 0) (headLabel(h), s.pmt06[h]),
      if (s.pmt06Interest > 0) ('Interest', s.pmt06Interest),
      if (s.pmt06LateFee > 0) ('Late fee', s.pmt06LateFee),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Set-off for ${periodLabel(s.period)}',
                style: theme.textTheme.titleMedium,
              ),
            ),
            UnverifiedBadge(s.unverified),
          ],
        ),
        const SizedBox(height: 8),
        const Text('Balance of IGST credit is used against'),
        const SizedBox(height: 4),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'cgst_first', label: Text('CGST first')),
            ButtonSegment(value: 'sgst_first', label: Text('SGST first')),
          ],
          selected: {split},
          onSelectionChanged: (v) => onSplit(v.first),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 40,
            dataRowMinHeight: 36,
            columns: [
              const DataColumn(label: Text('')),
              for (final h in gstHeads)
                DataColumn(label: Text(headLabel(h)), numeric: true),
            ],
            rows: [
              for (final (label, heads) in [
                ('Liability', s.liability),
                ('RCM (cash only)', s.rcm),
                ('Credit available', s.creditTotal),
                ('Credit used', s.creditUsed),
                ('Credit carried forward', s.creditCarryForward),
                ('Cash tax', s.cashTax),
              ])
                DataRow(
                  cells: [
                    DataCell(Text(label)),
                    for (final h in gstHeads) _n(heads[h]),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text('Credit utilisation matrix', style: theme.textTheme.titleSmall),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 40,
            dataRowMinHeight: 36,
            columns: [
              const DataColumn(label: Text('Credit of / pays')),
              for (final h in gstHeads)
                DataColumn(label: Text(headLabel(h)), numeric: true),
            ],
            rows: [
              for (final from in gstHeads)
                DataRow(
                  cells: [
                    DataCell(Text(headLabel(from))),
                    for (final to in gstHeads) _n(matrix['$from>$to'] ?? 0),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            Text('Cash needed ${formatMoney(s.cashTotal)}'),
            Text('Cash ledger (books) ${formatMoney(s.booksCash)}'),
            if (s.portalCash != null)
              Text('Cash ledger (portal) ${formatMoney(s.portalCash!.total)}'),
            if (s.daysLate > 0)
              Text('${s.daysLate} days late; due ${formatDate(s.dueDate)}'),
          ],
        ),
        if (s.shortfallTotal > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: WarningsBanner([
              'Cash shortfall ${formatMoney(s.shortfallTotal)}. Pay it on '
                  'PMT-06 first.',
            ], error: true),
          ),
        const SizedBox(height: 12),
        Text('PMT-06 amounts', style: theme.textTheme.titleSmall),
        if (pmt.isEmpty)
          const Text('No cash payment is needed.')
        else
          Wrap(
            children: [
              for (final (l, v) in pmt) CopyAmount(label: l, value: v),
            ],
          ),
        if (s.steps.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (var i = 0; i < s.steps.length; i++)
            Text('${i + 1}. ${s.steps[i]}'),
        ],
        if (onRecordPayment != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.tonalIcon(
                onPressed: onRecordPayment,
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Record PMT-06 payment'),
              ),
            ),
          ),
      ],
    );
  }
}
