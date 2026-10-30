import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/money.dart';
import '../../core/pdf_fonts.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../compliance/compliance_widgets.dart' show recentFys, shareText;
import '../reports/report_widgets.dart'
    show ReportSectionTitle, StatRow, StatTile, tabularFigures;
import 'it_models.dart';
import 'it_repository.dart';
import 'it_widgets.dart';

/// `/itr-pack`: the numbers and steps to file ITR-3 or ITR-4 yourself.
class ItrPackScreen extends ConsumerStatefulWidget {
  const ItrPackScreen({super.key});

  @override
  ConsumerState<ItrPackScreen> createState() => _ItrPackScreenState();
}

class _ItrPackScreenState extends ConsumerState<ItrPackScreen> {
  String _taxYear = recentFys().first;
  String _form = 'itr3';

  Future<void> _csv() async {
    try {
      final text = await ref
          .read(incomeTaxRepositoryProvider)
          .itrPackCsv(_taxYear, _form);
      if (mounted) await shareText(context, text, 'ITR pack CSV');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _print(ItrPack p) async {
    try {
      final theme = await pdfTheme();
      final doc = pw.Document(theme: theme);
      pw.Widget table(String title, List<PackLine> lines) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(height: 8),
          pw.Text(title, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          pw.TableHelper.fromTextArray(
            headers: ['Schedule', 'Line', 'Amount'],
            data: [
              for (final l in lines)
                [l.schedule, l.label, formatAmount(l.amount)],
            ],
            cellAlignment: pw.Alignment.centerLeft,
          ),
        ],
      );
      doc.addPage(
        pw.MultiPage(
          build: (_) => [
            pw.Text(
              '${p.form.toUpperCase()} pack, tax year ${p.taxYear}',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text('${p.companyName}  PAN ${p.companyPan}'),
            table('Profit and loss', p.pnl.lines),
            table('Balance sheet', p.balanceSheet.lines),
            pw.SizedBox(height: 8),
            pw.Text(
              'Adjustments',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            for (final a in p.adjustments)
              pw.Text(
                '${a.kind == 'less' ? '-' : '+'} ${a.label}: ${formatAmount(a.amount)}',
              ),
            pw.SizedBox(height: 8),
            pw.Text(
              'Steps',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            for (var i = 0; i < p.steps.length; i++)
              pw.Text('${i + 1}. ${p.steps[i]}'),
          ],
        ),
      );
      final bytes = await doc.save();
      await Printing.layoutPdf(
        onLayout: (_) async => Uint8List.fromList(bytes),
        name: 'itr-pack-${p.taxYear}',
      );
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final key = (_taxYear, _form);
    final value = ref.watch(itrPackProvider(key));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'ITR pack',
          subtitle: 'Figures from your books, laid out for the return',
          actions: [
            OutlinedButton.icon(
              onPressed: _csv,
              icon: const Icon(Icons.ios_share),
              label: const Text('Copy CSV'),
            ),
            if (value.hasValue)
              FilledButton.icon(
                onPressed: () => _print(value.requireValue),
                icon: const Icon(Icons.print_outlined),
                label: const Text('Print / PDF'),
              ),
          ],
        ),
        FilterBar(
          children: [
            SizedBox(
              width: 170,
              child: DropdownButtonFormField<String>(
                initialValue: _taxYear,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Tax year'),
                items: [
                  for (final f in recentFys())
                    DropdownMenuItem(value: f, child: Text(f)),
                ],
                onChanged: (v) => setState(() => _taxYear = v ?? _taxYear),
              ),
            ),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'itr3', label: Text('ITR-3')),
                ButtonSegment(value: 'itr4', label: Text('ITR-4')),
              ],
              selected: {_form},
              onSelectionChanged: (s) => setState(() => _form = s.first),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView<ItrPack>(
            value: value,
            onRetry: () => ref.invalidate(itrPackProvider(key)),
            data: (p) => _PackBody(pack: p),
          ),
        ),
      ],
    );
  }
}

class _PackBody extends StatelessWidget {
  const _PackBody({required this.pack});

  final ItrPack pack;

  Widget _lines(List<PackLine> lines) => Column(
    children: [
      for (final l in lines)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text('${l.schedule}  ${l.label}')),
              const SizedBox(width: 8),
              Text(formatMoney(l.amount), style: tabularFigures),
            ],
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final p = pack;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        UnverifiedNote(p.unverified),
        for (final w in p.warnings)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber,
                  size: 18,
                  color: Colors.orange.shade800,
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(w)),
              ],
            ),
          ),
        SectionCard(
          title: '${p.form.toUpperCase()} · ${p.taxYear} · ${p.entity}',
          child: Wrap(
            spacing: 32,
            runSpacing: 12,
            children: [
              LabeledValue('Name', p.companyName),
              LabeledValue('PAN', p.companyPan),
              LabeledValue('GSTIN', p.companyGstin),
              LabeledValue('Address', p.companyAddress),
            ],
          ),
        ),
        StatRow(
          children: [
            StatTile(
              label: 'Net profit (books)',
              value: formatMoney(p.pnl.totals['netProfit']),
            ),
            StatTile(
              label: 'Income estimate',
              value: formatMoney(p.incomeEstimate),
            ),
          ],
        ),
        const ReportSectionTitle('Profit and loss'),
        _lines(p.pnl.lines),
        const ReportSectionTitle('Balance sheet'),
        _lines(p.balanceSheet.lines),
        if (p.presumptive != null) ...[
          const ReportSectionTitle('Presumptive income'),
          Text(
            'Digital receipts ${formatMoney(p.presumptive!['digitalReceipts'] as num?)}, '
            'cash receipts ${formatMoney(p.presumptive!['cashReceipts'] as num?)}, '
            'deemed income ${formatMoney(p.presumptive!['deemedIncome'] as num?)}',
          ),
        ],
        const ReportSectionTitle('Depreciation (income-tax blocks)'),
        if (p.depreciation.isEmpty)
          const Text('No fixed assets.')
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Block')),
                DataColumn(label: Text('Rate'), numeric: true),
                DataColumn(label: Text('Opening'), numeric: true),
                DataColumn(label: Text('Additions'), numeric: true),
                DataColumn(label: Text('Sales'), numeric: true),
                DataColumn(label: Text('Depreciation'), numeric: true),
                DataColumn(label: Text('Closing'), numeric: true),
              ],
              rows: [
                for (final b in p.depreciation)
                  DataRow(
                    cells: [
                      DataCell(Text(b.blockName)),
                      DataCell(Text('${b.rate.toStringAsFixed(0)}%')),
                      DataCell(Text(formatAmount(b.openingWdv))),
                      DataCell(
                        Text(formatAmount(b.additionsFull + b.additionsHalf)),
                      ),
                      DataCell(Text(formatAmount(b.saleValue))),
                      DataCell(Text(formatAmount(b.depreciation))),
                      DataCell(Text(formatAmount(b.closingWdv))),
                    ],
                  ),
              ],
            ),
          ),
        const ReportSectionTitle('Adjustments'),
        if (p.adjustments.isEmpty)
          const Text('None.')
        else
          for (final a in p.adjustments)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${a.kind == 'less' ? 'Less' : 'Add'}: ${a.label}'),
              subtitle: Text(a.reason),
              trailing: Text(formatMoney(a.amount), style: tabularFigures),
            ),
        const ReportSectionTitle('TDS credits'),
        if (p.tdsCredits.isEmpty)
          const Text('None.')
        else
          for (final t in p.tdsCredits)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.deductorName),
              subtitle: t.tan == null ? null : Text('TAN ${t.tan}'),
              trailing: Text(formatMoney(t.amount), style: tabularFigures),
            ),
        const ReportSectionTitle('Taxes paid'),
        if (p.taxesPaid.isEmpty)
          const Text('None.')
        else
          for (final t in p.taxesPaid)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${t.kindLabel} · ${formatDate(t.date)}'),
              subtitle: Text('BSR ${t.bsrCode} · serial ${t.challanSerial}'),
              trailing: Text(formatMoney(t.amount), style: tabularFigures),
            ),
        const ReportSectionTitle('Steps to file'),
        for (var i = 0; i < p.steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('${i + 1}. ${p.steps[i]}'),
          ),
      ],
    );
  }
}
