/// The client report as a PDF: an A4 document or 16:9 slides. Pure Dart, so
/// it can be tested and rendered anywhere.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/money.dart';
import '../../../core/pdf_kit.dart';
import '../../../widgets/charts/chart_format.dart';
import '../../insights/analytics_models.dart';
import '../../insights/insights_rules.dart';
import 'client_report_model.dart';

const _confidential =
    'Confidential. Prepared for the named recipient only. Do not share without permission.';

// Fixed series colours that print well on paper and screen.
const _cSales = PdfColor.fromInt(0xFF0B6157);
const _cOther = PdfColor.fromInt(0xFFC27A12);
const _cIn = PdfColor.fromInt(0xFF1A7F4B);
const _cOut = PdfColor.fromInt(0xFFC27A12);
const _ageColors = [
  PdfColor.fromInt(0xFF1A7F4B),
  PdfColor.fromInt(0xFFD9A21B),
  PdfColor.fromInt(0xFFD9741B),
  PdfColor.fromInt(0xFFCB4B2A),
  PdfColor.fromInt(0xFF9E1C1C),
];

String _money(num? v) {
  final s = formatMoney(v ?? 0);
  return s.endsWith('.00') ? s.substring(0, s.length - 3) : s;
}

String _short(num? v) => formatCompact(v);

String _pctText(double? p) => p == null ? '' : formatDeltaPercent(p);

/// A4 report when [slides] is false, 16:9 slides when true.
Future<Uint8List> buildClientReportPdf(
  ClientReportInput input, {
  required bool slides,
}) {
  final b = _Builder(input);
  return slides ? b.slides() : b.document();
}

class _Builder {
  _Builder(this.i) : kit = PdfKit(brand: i.brand, theme: i.theme);

  final ClientReportInput i;
  final PdfKit kit;
  Analytics get a => i.analytics;
  PdfColor get brand => i.brand.color;

  String get _title => 'Business report';

  /// A chosen section with nothing to show is left out, here and in Contents.
  bool shows(ReportSection s) => switch (s) {
    _ when !i.has(s) => false,
    ReportSection.cash => a.cashFlow?.isNotEmpty ?? false,
    ReportSection.stock => i.stockRows.isNotEmpty,
    ReportSection.projects => i.projects.isNotEmpty,
    _ => true,
  };

  /// The same figure the stock table totals to, so the two cannot disagree.
  double get stockValue =>
      i.stockTotal ?? i.stockRows.fold<double>(0, (s, r) => s + r.value);

  // ----------------------------------------------------------------- shared

  pw.Widget t(
    String s, {
    double size = 10,
    bool bold = false,
    PdfColor color = kInk,
    pw.TextAlign? align,
    double? height,
  }) => kit.text(
    s,
    size: size,
    bold: bold,
    color: color,
    align: align,
    height: height,
  );

  pw.Widget legend(List<(String, PdfColor)> items, {double size = 8}) =>
      pw.Wrap(
        spacing: 14,
        runSpacing: 4,
        children: [
          for (final (n, c) in items)
            pw.Row(
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Container(width: 8, height: 8, color: c),
                pw.SizedBox(width: 4),
                t(n, size: size, color: kMuted),
              ],
            ),
        ],
      );

  /// Label, big figure and change against the previous period.
  pw.Widget kpiCard(
    String label,
    double value,
    double? prev, {
    bool upIsGood = true,
    double scale = 1,
    String? note,
  }) {
    final d = percentChange(value, prev);
    PdfColor dc = kMuted;
    if (d != null && d.abs() >= 0.5) dc = (d > 0) == upIsGood ? kGood : kDanger;
    return pw.Container(
      padding: pw.EdgeInsets.all(10 * scale),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        border: pw.Border(
          left: pw.BorderSide(color: brand, width: 3),
          top: const pw.BorderSide(color: kLine, width: 0.6),
          right: const pw.BorderSide(color: kLine, width: 0.6),
          bottom: const pw.BorderSide(color: kLine, width: 0.6),
        ),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          t(label, size: 8.5 * scale, color: kMuted),
          pw.SizedBox(height: 3 * scale),
          t(_short(value), size: 19 * scale, bold: true),
          pw.SizedBox(height: 2 * scale),
          if (d != null)
            pw.Row(
              children: [
                t(_pctText(d), size: 8.5 * scale, bold: true, color: dc),
                pw.SizedBox(width: 4),
                t('vs previous period', size: 7.5 * scale, color: kMuted),
              ],
            )
          else
            t(note ?? 'No earlier figure', size: 7.5 * scale, color: kMuted),
        ],
      ),
    );
  }

  List<(String, double, double?, bool)> kpis() {
    final c = a.current, p = a.previous;
    return [
      ('Sales', c.sales, p.sales, true),
      ('Purchases', c.purchases, p.purchases, false),
      if (c.netProfit != null) ('Net profit', c.netProfit!, p.netProfit, true),
      if (c.receivables != null)
        ('Receivables', c.receivables!, p.receivables, false),
      if (c.payables != null) ('Payables', c.payables!, p.payables, false),
      if (c.cashAndBank != null)
        ('Cash and bank', c.cashAndBank!, p.cashAndBank, true),
    ];
  }

  pw.Widget kpiGrid(int columns, {double scale = 1}) {
    final list = kpis();
    final rows = <pw.Widget>[];
    for (var r = 0; r < list.length; r += columns) {
      final slice = list.skip(r).take(columns).toList();
      rows.add(
        pw.Padding(
          padding: pw.EdgeInsets.only(bottom: 8 * scale),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (var k = 0; k < columns; k++) ...[
                if (k > 0) pw.SizedBox(width: 8 * scale),
                pw.Expanded(
                  child: k < slice.length
                      ? kpiCard(
                          slice[k].$1,
                          slice[k].$2,
                          slice[k].$3,
                          upIsGood: slice[k].$4,
                          scale: scale,
                        )
                      : pw.SizedBox(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return pw.Column(children: rows);
  }

  pw.Widget takeawayList({double size = 10, int limit = 6}) {
    if (i.takeaways.isEmpty) {
      return t(
        'Nothing to report for this period yet.',
        size: size,
        color: kMuted,
      );
    }
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        for (final k in i.takeaways.take(limit))
          pw.Padding(
            padding: pw.EdgeInsets.only(bottom: size * 0.7),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Container(
                  margin: pw.EdgeInsets.only(top: size * 0.4, right: 8),
                  width: 5,
                  height: 5,
                  color: switch (k.tone) {
                    TakeawayTone.good => kGood,
                    TakeawayTone.warning => kDanger,
                    TakeawayTone.neutral => kMuted,
                  },
                ),
                pw.Expanded(child: t(k.text, size: size, height: 2)),
              ],
            ),
          ),
      ],
    );
  }

  // ----------------------------------------------------------------- charts

  /// Half a slot of room at each end, so the first and last bars are not cut
  /// off and a single month still has a scale.
  pw.FixedAxis<num> _xAxis(List<String> labels) {
    final n = labels.length;
    final every = math.max(1, (n / 8).ceil());
    return pw.FixedAxis<num>(
      [-0.5, for (var k = 0; k < n; k++) k, n - 0.5],
      format: (v) => v is int && v % every == 0 ? labels[v] : '',
      textStyle: pw.TextStyle(fontSize: 7, color: kMuted),
      divisions: false,
      margin: 12,
    );
  }

  /// A line needs at least three points to show a trend; bars read better
  /// below that.
  pw.Widget trendChart(
    List<String> labels,
    List<(String, List<double>, PdfColor)> series,
    double chartWidth,
  ) => labels.length < 3
      ? groupedBars(labels, series, chartWidth)
      : lineChart(labels, series);

  pw.Widget lineChart(
    List<String> labels,
    List<(String, List<double>, PdfColor)> series,
  ) {
    if (labels.isEmpty) {
      return t('No data for this period.', color: kMuted);
    }
    var maxV = 0.0;
    for (final s in series) {
      for (final v in s.$2) {
        maxV = math.max(maxV, v);
      }
    }
    final top = niceCeil(maxV);
    return pw.Chart(
      grid: pw.CartesianGrid(
        xAxis: _xAxis(labels),
        yAxis: pw.FixedAxis<num>(
          [for (var k = 0; k <= 4; k++) top / 4 * k],
          format: (v) => _short(v),
          textStyle: pw.TextStyle(fontSize: 7, color: kMuted),
          divisions: true,
          divisionsColor: kLine,
          divisionsWidth: 0.5,
          margin: 8,
        ),
      ),
      datasets: [
        for (final (k, s) in series.indexed)
          pw.LineDataSet(
            data: [
              for (var j = 0; j < s.$2.length; j++)
                pw.PointChartValue(j.toDouble(), s.$2[j]),
            ],
            color: s.$3,
            lineWidth: 2,
            drawPoints: labels.length <= 14,
            pointSize: 2.6,
            drawSurface: k == 0,
            surfaceOpacity: 0.12,
            isCurved: false,
          ),
      ],
    );
  }

  pw.Widget groupedBars(
    List<String> labels,
    List<(String, List<double>, PdfColor)> series,
    double chartWidth,
  ) {
    if (labels.isEmpty) {
      return t('No data for this period.', color: kMuted);
    }
    var maxV = 0.0;
    for (final s in series) {
      for (final v in s.$2) {
        maxV = math.max(maxV, v);
      }
    }
    final top = niceCeil(maxV);
    final n = labels.length;
    final group = (chartWidth - 40) / math.max(1, n);
    final cap = n < 4 ? 36.0 : 18.0;
    final w = math.max(3.0, math.min(cap, (group - 8) / series.length));
    return pw.Chart(
      grid: pw.CartesianGrid(
        xAxis: _xAxis(labels),
        yAxis: pw.FixedAxis<num>(
          [for (var k = 0; k <= 4; k++) top / 4 * k],
          format: (v) => _short(v),
          textStyle: pw.TextStyle(fontSize: 7, color: kMuted),
          divisions: true,
          divisionsColor: kLine,
          divisionsWidth: 0.5,
          margin: 8,
        ),
      ),
      datasets: [
        for (final (k, s) in series.indexed)
          pw.BarDataSet(
            data: [
              for (var j = 0; j < s.$2.length; j++)
                pw.PointChartValue(j.toDouble(), math.max(0, s.$2[j])),
            ],
            color: s.$3,
            width: w,
            offset: (k - (series.length - 1) / 2) * (w + 1.5),
          ),
      ],
    );
  }

  /// Names above bars sized to the largest value.
  pw.Widget rankedBars(
    List<RankedRow> rows, {
    int max = 5,
    bool showShare = false,
    double size = 9,
  }) {
    final list = ([
      ...rows,
    ]..sort((x, y) => y.amount.compareTo(x.amount))).take(max).toList();
    if (list.isEmpty) {
      return t('No data for this period.', size: size, color: kMuted);
    }
    final top = list.first.amount <= 0 ? 1.0 : list.first.amount;
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        for (final r in list)
          pw.Padding(
            padding: pw.EdgeInsets.only(bottom: size * 0.8),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Row(
                  children: [
                    pw.Expanded(child: t(r.name, size: size)),
                    t(_short(r.amount), size: size, bold: true),
                    if (showShare && r.share != null) ...[
                      pw.SizedBox(width: 5),
                      t(
                        '${r.share!.round()}%',
                        size: size - 1.5,
                        color: kMuted,
                      ),
                    ],
                  ],
                ),
                pw.SizedBox(height: 2.5),
                pw.Row(
                  children: [
                    pw.Expanded(
                      flex: math.max(1, (r.amount / top * 1000).round()),
                      child: pw.Container(height: 6, color: brand),
                    ),
                    pw.Expanded(
                      flex: math.max(0, 1000 - (r.amount / top * 1000).round()),
                      child: pw.Container(height: 6, color: kStripe),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  pw.Widget ageingBlock(AgeingBuckets b, {double size = 9, double pie = 120}) {
    final labelled = b.labelled;
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.SizedBox(
          width: pie,
          height: pie,
          child: b.total <= 0
              ? pw.SizedBox()
              : pw.Chart(
                  grid: pw.PieGrid(),
                  datasets: [
                    for (final (k, s) in labelled.indexed)
                      if (s.$2 > 0)
                        pw.PieDataSet(
                          value: s.$2,
                          color: _ageColors[k],
                          innerRadius: pie * 0.28,
                          borderWidth: 1.5,
                        ),
                  ],
                ),
        ),
        pw.SizedBox(width: 14),
        pw.Expanded(
          child: pw.Column(
            children: [
              for (final (k, s) in labelled.indexed)
                pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
                  child: pw.Row(
                    children: [
                      pw.Container(width: 8, height: 8, color: _ageColors[k]),
                      pw.SizedBox(width: 6),
                      pw.Expanded(child: t(s.$1, size: size)),
                      t(_short(s.$2), size: size, bold: true),
                      pw.SizedBox(
                        width: 34,
                        child: t(
                          b.total > 0
                              ? '${(s.$2 / b.total * 100).round()}%'
                              : '',
                          size: size - 1,
                          color: kMuted,
                          align: pw.TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ),
              pw.Divider(color: kLine, height: 8, thickness: 0.6),
              pw.Row(
                children: [
                  pw.Expanded(
                    child: t('Total outstanding', size: size, bold: true),
                  ),
                  t(_short(b.total), size: size, bold: true),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ----------------------------------------------------------------- tables

  pw.Widget monthTable({double size = 8}) {
    final cash = {
      for (final c in a.cashFlow ?? const <CashPoint>[]) c.month: c,
    };
    return kit.table(
      fontSize: size,
      columns: [
        const PdfCol('Month', flex: 1.4),
        const PdfCol('Sales', flex: 1.4, right: true),
        const PdfCol('Purchases', flex: 1.4, right: true),
        const PdfCol('Expenses', flex: 1.4, right: true),
        if (a.cashFlow != null) const PdfCol('Cash in', flex: 1.4, right: true),
        if (a.cashFlow != null)
          const PdfCol('Cash out', flex: 1.4, right: true),
      ],
      rows: [
        for (final p in a.trend)
          [
            monthLabel(p.month, withYear: true),
            _money(p.sales),
            _money(p.purchases),
            _money(p.expenses),
            if (a.cashFlow != null) _money(cash[p.month]?.cashIn ?? 0),
            if (a.cashFlow != null) _money(cash[p.month]?.cashOut ?? 0),
          ],
      ],
      totals: [
        'Total',
        _money(a.trend.fold<double>(0, (s, p) => s + p.sales)),
        _money(a.trend.fold<double>(0, (s, p) => s + p.purchases)),
        _money(a.trend.fold<double>(0, (s, p) => s + p.expenses)),
        if (a.cashFlow != null)
          _money(a.cashFlow!.fold<double>(0, (s, p) => s + p.cashIn)),
        if (a.cashFlow != null)
          _money(a.cashFlow!.fold<double>(0, (s, p) => s + p.cashOut)),
      ],
    );
  }

  pw.Widget profitTable({double size = 8.5}) {
    final c = a.current, p = a.previous;
    final rows = <(String, double?, double?)>[
      ('Sales (before tax)', c.sales, p.sales),
      ('Purchases (before tax)', c.purchases, p.purchases),
      ('Gross profit', c.grossProfit, p.grossProfit),
      ('Expenses', c.expenses, p.expenses),
      ('Net profit', c.netProfit, p.netProfit),
    ].where((r) => r.$2 != null).toList();
    return kit.table(
      fontSize: size,
      columns: const [
        PdfCol('', flex: 3),
        PdfCol('This period', flex: 2, right: true),
        PdfCol('Previous period', flex: 2, right: true),
        PdfCol('Change', flex: 1.2, right: true),
      ],
      rows: [
        for (final r in rows)
          [
            r.$1,
            _money(r.$2),
            _money(r.$3),
            _pctText(percentChange(r.$2, r.$3)),
          ],
      ],
    );
  }

  pw.Widget ageingTable(String title, AgeingBuckets b, {double size = 8.5}) =>
      kit.table(
        fontSize: size,
        columns: [
          PdfCol(title, flex: 3),
          const PdfCol('Amount', flex: 2, right: true),
          const PdfCol('Share', flex: 1, right: true),
        ],
        rows: [
          for (final s in b.labelled)
            [
              s.$1,
              _money(s.$2),
              b.total > 0 ? '${(s.$2 / b.total * 100).round()}%' : '',
            ],
        ],
        totals: ['Total', _money(b.total), ''],
      );

  pw.Widget stockTable(int max, {double size = 8.5}) {
    final rows = ([
      ...i.stockRows,
    ]..sort((x, y) => y.value.compareTo(x.value))).take(max).toList();
    return kit.table(
      fontSize: size,
      columns: const [
        PdfCol('Item', flex: 4),
        PdfCol('Quantity', flex: 1.6, right: true),
        PdfCol('Average cost', flex: 1.8, right: true),
        PdfCol('Value', flex: 1.8, right: true),
      ],
      rows: [
        for (final r in rows)
          [
            r.name,
            '${formatQty(r.qty)} ${r.unit}',
            _money(r.avgCost),
            _money(r.value),
          ],
      ],
      totals: i.stockRows.length > max
          ? null
          : ['Total', '', '', _money(stockValue)],
    );
  }

  pw.Widget projectsTable(int max, {double size = 8.5}) {
    final rows = i.projects.take(max).toList();
    return kit.table(
      fontSize: size,
      columns: const [
        PdfCol('Project', flex: 3.4),
        PdfCol('Client', flex: 2.6),
        PdfCol('Status', flex: 1.4),
        PdfCol('Progress', flex: 1.2, right: true),
        PdfCol('Contract value', flex: 2, right: true),
      ],
      rows: [
        for (final p in rows)
          [
            p.name,
            p.clientName ?? '',
            p.status.label,
            '${p.progressPct.round()}%',
            _money(p.contractValue),
          ],
      ],
    );
  }

  // ------------------------------------------------------------ A4 document

  pw.Widget h1(String s, {String? lead}) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        children: [
          pw.Container(width: 4, height: 20, color: brand),
          pw.SizedBox(width: 8),
          t(s, size: 19, bold: true),
        ],
      ),
      if (lead != null)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 6, left: 12),
          child: t(lead, size: 10, color: kMuted, height: 2),
        ),
      pw.SizedBox(height: 14),
    ],
  );

  pw.Widget h2(String s) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
    child: t(s, size: 11.5, bold: true),
  );

  String salesLead() {
    final d = percentChange(a.current.sales, a.previous.sales);
    return 'Sales were ${_money(a.current.sales)}'
        '${d == null ? '.' : ', ${d >= 0 ? 'up' : 'down'} ${formatDeltaPercent(d.abs()).substring(1)} on the previous period.'}';
  }

  Future<Uint8List> document() async {
    final doc = kit.document(
      title: '$_title ${i.periodLabel}',
      subject: i.brand.companyName,
    );
    final fmt = PdfPageFormat.a4;
    doc.addPage(_cover(fmt));
    const margin = 40.0;
    final width = fmt.width - margin * 2;
    final body = <pw.Widget>[];

    // Kept on one page. A block must fit a page or the PDF fails to build, so
    // long tables stay out of here.
    pw.Widget keep(List<pw.Widget> children) => pw.Inseparable(
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: children,
      ),
    );

    // Sections run on from each other so short ones don't leave half a page
    // empty. [opening] is the heading and its first block.
    void section(
      ReportSection s,
      List<pw.Widget> opening, {
      List<pw.Widget> rest = const [],
      bool freshPage = false,
    }) {
      if (!shows(s)) return;
      if (body.isNotEmpty) {
        body.add(freshPage ? pw.NewPage() : pw.SizedBox(height: 26));
      }
      body.add(keep(opening));
      body.addAll(rest);
    }

    const shortTable = 8;
    final longStock = i.stockRows.length > shortTable;
    final longProjects = i.projects.length > shortTable;

    section(
      ReportSection.summary,
      [
        h1(
          'Summary',
          lead:
              'Key figures for ${i.periodLabel}, with the change against the previous period.',
        ),
        kpiGrid(3),
      ],
      rest: [
        keep([h2('What stands out'), takeawayList(size: 10.5)]),
        if (i.notes.trim().isNotEmpty) ...[
          h2(
            'Notes${i.preparedBy.trim().isEmpty ? '' : ' from ${i.preparedBy.trim()}'}',
          ),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: i.brand.tint,
              border: pw.Border(left: pw.BorderSide(color: brand, width: 3)),
            ),
            child: t(i.notes.trim(), size: 10, height: 3),
          ),
        ],
      ],
    );

    section(
      ReportSection.sales,
      [
        h1('Sales', lead: salesLead()),
        h2('Sales and purchases by month'),
        legend([('Sales', _cSales), ('Purchases', _cOther)]),
        pw.SizedBox(height: 6),
        pw.SizedBox(
          height: 190,
          child: trendChart(
            [
              for (final p in a.trend)
                monthLabel(p.month, withYear: a.trend.length > 12),
            ],
            [
              ('Sales', [for (final p in a.trend) p.sales], _cSales),
              ('Purchases', [for (final p in a.trend) p.purchases], _cOther),
            ],
            width,
          ),
        ),
      ],
      rest: [
        pw.SizedBox(height: 4),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  h2('Top customers'),
                  rankedBars(a.topCustomers, showShare: true),
                ],
              ),
            ),
            pw.SizedBox(width: 24),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [h2('Top items'), rankedBars(a.topItems)],
              ),
            ),
          ],
        ),
      ],
    );

    section(
      ReportSection.profit,
      [
        h1(
          'Profit',
          lead:
              'Net profit was ${_money(a.current.netProfit)} against ${_money(a.previous.netProfit)} in the previous period.',
        ),
        profitTable(),
      ],
      rest: [
        if (a.expensesByCategory.isNotEmpty)
          keep([
            h2('Where expenses went'),
            rankedBars(a.expensesByCategory, max: 6),
          ]),
        if (a.trend.length <= 24)
          keep([h2('Month by month'), monthTable()])
        else ...[
          h2('Month by month'),
          monthTable(),
        ],
      ],
    );

    section(
      ReportSection.cash,
      [
        h1('Cash', lead: _cashLead()),
        h2('Cash in and cash out by month'),
        legend([('Cash in', _cIn), ('Cash out', _cOut)]),
        pw.SizedBox(height: 6),
        pw.SizedBox(
          height: 200,
          child: groupedBars(
            [
              for (final c in a.cashFlow ?? const <CashPoint>[])
                monthLabel(c.month, withYear: (a.cashFlow?.length ?? 0) > 12),
            ],
            [
              (
                'Cash in',
                [for (final c in a.cashFlow ?? const <CashPoint>[]) c.cashIn],
                _cIn,
              ),
              (
                'Cash out',
                [for (final c in a.cashFlow ?? const <CashPoint>[]) c.cashOut],
                _cOut,
              ),
            ],
            width,
          ),
        ),
      ],
      rest: [
        if (a.current.cashAndBank != null) ...[
          pw.SizedBox(height: 10),
          pw.Row(
            children: [
              pw.Expanded(
                child: kpiCard(
                  'Cash and bank at period end',
                  a.current.cashAndBank!,
                  a.previous.cashAndBank,
                ),
              ),
              pw.SizedBox(width: 10),
              pw.Expanded(
                child: kpiCard(
                  'Collected from customers',
                  a.current.collections ?? 0,
                  a.previous.collections,
                ),
              ),
              pw.SizedBox(width: 10),
              pw.Expanded(
                child: kpiCard(
                  'Paid to suppliers',
                  a.current.payments ?? 0,
                  a.previous.payments,
                  upIsGood: false,
                ),
              ),
            ],
          ),
        ],
      ],
    );

    section(
      ReportSection.receivables,
      [
        h1(
          'Receivables',
          lead:
              '${_money(a.receivableAgeing.total)} is owed to the business as of ${i.periodLabel.split(' to ').last}.',
        ),
        h2('Money owed to us, by how late it is'),
        ageingBlock(a.receivableAgeing, size: 10, pie: 150),
      ],
      rest: [
        keep([
          pw.SizedBox(height: 12),
          ageingTable('Receivables', a.receivableAgeing, size: 9),
        ]),
        if (a.payableAgeing.total > 0)
          keep([
            h2('Money we owe suppliers'),
            ageingTable('Payables', a.payableAgeing, size: 9),
          ]),
      ],
    );

    section(
      ReportSection.stock,
      [
        h1('Stock', lead: 'Stock on hand is valued at ${_money(stockValue)}.'),
        if (!longStock) stockTable(25),
      ],
      freshPage: longStock,
      rest: [
        if (longStock) stockTable(25),
        if (i.stockRows.length > 25)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 6),
            child: t(
              'Showing the 25 items of highest value.',
              size: 8,
              color: kMuted,
            ),
          ),
      ],
    );

    section(
      ReportSection.projects,
      [
        h1(
          'Projects',
          lead:
              '${i.projects.length} ${i.projects.length == 1 ? 'project' : 'projects'} on the books.',
        ),
        if (!longProjects) projectsTable(30),
      ],
      freshPage: longProjects,
      rest: [if (longProjects) projectsTable(30)],
    );

    doc.addPage(
      pw.MultiPage(
        pageTheme: kit.pageTheme(format: fmt, margin: margin),
        header: (c) => kit.compactHeader('$_title  |  ${i.periodLabel}'),
        footer: (c) => kit.footer(c, left: _confidential),
        build: (_) => body.isEmpty ? [t('No sections were selected.')] : body,
      ),
    );
    return doc.save();
  }

  String _cashLead() {
    final cash = a.cashFlow ?? const <CashPoint>[];
    final inn = cash.fold<double>(0, (s, c) => s + c.cashIn);
    final out = cash.fold<double>(0, (s, c) => s + c.cashOut);
    return 'The business collected ${_money(inn)} and paid out ${_money(out)}, '
        '${inn >= out ? 'a net inflow' : 'a net outflow'} of ${_money((inn - out).abs())}.';
  }

  pw.Page _cover(PdfPageFormat fmt) {
    final logo = i.brand.logo;
    return pw.Page(
      pageTheme: kit.pageTheme(
        format: fmt,
        margin: 0,
        background: (c) => pw.Stack(
          children: [
            pw.Positioned(
              left: 0,
              top: 0,
              child: pw.Container(width: fmt.width, height: 300, color: brand),
            ),
            pw.Positioned(
              left: 0,
              top: 300,
              child: pw.Container(
                width: fmt.width,
                height: 4,
                color: i.brand.tint,
              ),
            ),
          ],
        ),
      ),
      build: (c) => pw.Padding(
        padding: const pw.EdgeInsets.fromLTRB(56, 56, 56, 48),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(
              height: 216,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (logo != null)
                    pw.Container(
                      padding: const pw.EdgeInsets.all(8),
                      decoration: pw.BoxDecoration(
                        color: PdfColors.white,
                        borderRadius: pw.BorderRadius.circular(4),
                      ),
                      child: pw.SizedBox(
                        height: 44,
                        child: pw.Image(logo, fit: pw.BoxFit.contain),
                      ),
                    )
                  else
                    t(
                      i.brand.companyName,
                      size: 16,
                      bold: true,
                      color: i.brand.onColor,
                    ),
                  pw.Spacer(),
                  t(
                    _title.toUpperCase(),
                    size: 11,
                    bold: true,
                    color: i.brand.onColor,
                  ),
                  pw.SizedBox(height: 8),
                  t(
                    i.periodLabel,
                    size: 28,
                    bold: true,
                    color: i.brand.onColor,
                    height: 3,
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 98),
            _coverRow(
              'Prepared for',
              i.recipient.trim().isEmpty ? '' : i.recipient.trim(),
            ),
            _coverRow(
              'Prepared by',
              i.preparedBy.trim().isEmpty
                  ? i.brand.companyName
                  : '${i.preparedBy.trim()}, ${i.brand.companyName}',
            ),
            _coverRow('Date', i.generatedOn),
            _coverRow(
              'Contents',
              [
                for (final s in ReportSection.values)
                  if (shows(s)) s.label,
              ].join(', '),
            ),
            pw.Spacer(),
            if (i.brand.idLine != null && i.brand.idLine!.isNotEmpty)
              t(i.brand.idLine!, size: 8, color: kMuted),
            if (i.brand.contactLine != null && i.brand.contactLine!.isNotEmpty)
              t(i.brand.contactLine!, size: 8, color: kMuted),
            pw.SizedBox(height: 10),
            pw.Divider(color: kLine, thickness: 0.6),
            t(_confidential, size: 8, color: kMuted),
          ],
        ),
      ),
    );
  }

  pw.Widget _coverRow(String k, String v) => v.isEmpty
      ? pw.SizedBox()
      : pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 12),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(width: 100, child: t(k, size: 10, color: kMuted)),
              pw.Expanded(child: t(v, size: 12, bold: true)),
            ],
          ),
        );

  // ----------------------------------------------------------------- slides

  Future<Uint8List> slides() async {
    const fmt = PdfPageFormat(960, 540);
    final doc = kit.document(
      title: '$_title ${i.periodLabel}',
      subject: i.brand.companyName,
    );
    final builders = <pw.Widget Function(int n, int total)>[];

    pw.Widget frame(
      String title,
      String? lead,
      pw.Widget body,
      int n,
      int total,
    ) => pw.Padding(
      padding: const pw.EdgeInsets.fromLTRB(48, 34, 48, 22),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(
            children: [
              pw.Container(width: 5, height: 28, color: brand),
              pw.SizedBox(width: 10),
              pw.Expanded(child: t(title, size: 26, bold: true)),
              t(i.periodLabel, size: 10, color: kMuted),
            ],
          ),
          if (lead != null)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 8, left: 15),
              child: t(lead, size: 13, color: kMuted),
            ),
          pw.SizedBox(height: 18),
          // Align takes the full height, so the footer stays at the bottom
          // however short the slide is.
          pw.Expanded(
            child: pw.Align(alignment: pw.Alignment.topLeft, child: body),
          ),
          pw.SizedBox(height: 8),
          pw.Divider(color: kLine, thickness: 0.6, height: 1),
          pw.SizedBox(height: 5),
          pw.Row(
            children: [
              pw.Expanded(
                child: t(
                  '${i.brand.companyName}  |  Confidential',
                  size: 8,
                  color: kMuted,
                ),
              ),
              t('$n of $total', size: 8, color: kMuted),
            ],
          ),
        ],
      ),
    );

    void slide(String title, String? lead, pw.Widget Function() body) =>
        builders.add((n, total) => frame(title, lead, body(), n, total));

    if (shows(ReportSection.summary)) {
      slide(
        'Summary',
        'Key figures with the change against the previous period.',
        () => pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(flex: 11, child: kpiGrid(2, scale: 1.25)),
            pw.SizedBox(width: 28),
            pw.Expanded(
              flex: 10,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  t('WHAT STANDS OUT', size: 9, bold: true, color: brand),
                  pw.SizedBox(height: 10),
                  takeawayList(size: 12.5, limit: 5),
                ],
              ),
            ),
          ],
        ),
      );
    }
    if (shows(ReportSection.sales)) {
      // One or two items would leave a slide nearly empty.
      final itemsSlide = a.topItems.length >= 3;
      slide(
        'Sales',
        salesLead(),
        () => pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              flex: 6,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  t('Sales and purchases by month', size: 11, bold: true),
                  pw.SizedBox(height: 4),
                  legend([('Sales', _cSales), ('Purchases', _cOther)]),
                  pw.SizedBox(height: 6),
                  pw.Expanded(
                    child: trendChart(
                      [
                        for (final p in a.trend)
                          monthLabel(p.month, withYear: a.trend.length > 12),
                      ],
                      [
                        ('Sales', [for (final p in a.trend) p.sales], _cSales),
                        (
                          'Purchases',
                          [for (final p in a.trend) p.purchases],
                          _cOther,
                        ),
                      ],
                      500,
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(width: 30),
            pw.Expanded(
              flex: 4,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  t('Top customers', size: 11, bold: true),
                  pw.SizedBox(height: 8),
                  rankedBars(a.topCustomers, showShare: true, size: 10),
                  if (a.topItems.isNotEmpty && !itemsSlide) ...[
                    pw.SizedBox(height: 14),
                    t('Top items', size: 11, bold: true),
                    pw.SizedBox(height: 8),
                    rankedBars(a.topItems, size: 10),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
      if (itemsSlide) {
        slide(
          'Top items',
          'Items that brought in the most sales.',
          () => rankedBars(a.topItems, max: 7, size: 12),
        );
      }
    }
    if (shows(ReportSection.profit)) {
      slide(
        'Profit',
        'Net profit was ${_money(a.current.netProfit)} against ${_money(a.previous.netProfit)} before.',
        () => pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(flex: 6, child: profitTable(size: 11)),
            if (a.expensesByCategory.isNotEmpty) ...[
              pw.SizedBox(width: 30),
              pw.Expanded(
                flex: 4,
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    t('Where expenses went', size: 11, bold: true),
                    pw.SizedBox(height: 8),
                    rankedBars(a.expensesByCategory, max: 5, size: 10),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    }
    if (shows(ReportSection.cash)) {
      final cash = a.cashFlow ?? const <CashPoint>[];
      slide(
        'Cash',
        _cashLead(),
        () => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            legend([('Cash in', _cIn), ('Cash out', _cOut)]),
            pw.SizedBox(height: 6),
            pw.Expanded(
              child: groupedBars(
                [
                  for (final c in cash)
                    monthLabel(c.month, withYear: cash.length > 12),
                ],
                [
                  ('Cash in', [for (final c in cash) c.cashIn], _cIn),
                  ('Cash out', [for (final c in cash) c.cashOut], _cOut),
                ],
                864,
              ),
            ),
          ],
        ),
      );
    }
    if (shows(ReportSection.receivables)) {
      slide(
        'Receivables',
        '${_money(a.receivableAgeing.total)} is owed to the business.',
        () => pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              flex: 6,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  t(
                    'Money owed to us, by how late it is',
                    size: 11,
                    bold: true,
                  ),
                  pw.SizedBox(height: 12),
                  ageingBlock(a.receivableAgeing, size: 11, pie: 190),
                ],
              ),
            ),
            pw.SizedBox(width: 30),
            pw.Expanded(
              flex: 3,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  kpiCard(
                    'Receivables',
                    a.receivableAgeing.total,
                    a.previous.receivables,
                    upIsGood: false,
                    scale: 1.2,
                  ),
                  pw.SizedBox(height: 10),
                  if (a.current.payables != null)
                    kpiCard(
                      'Payables',
                      a.current.payables!,
                      a.previous.payables,
                      upIsGood: false,
                      scale: 1.2,
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    if (shows(ReportSection.stock)) {
      slide(
        'Stock',
        'Stock on hand is valued at ${_money(stockValue)}.',
        () => stockTable(8, size: 11),
      );
    }
    if (shows(ReportSection.projects)) {
      slide(
        'Projects',
        '${i.projects.length} ${i.projects.length == 1 ? 'project' : 'projects'} on the books.',
        () => projectsTable(8, size: 11),
      );
    }
    if (i.notes.trim().isNotEmpty) {
      slide(
        'Notes',
        i.preparedBy.trim().isEmpty ? null : 'From ${i.preparedBy.trim()}',
        () => t(i.notes.trim(), size: 15, height: 5),
      );
    }

    // Cover first, then content slides.
    final total = builders.length + 1;
    doc.addPage(_slideCover(fmt, total));
    for (final (k, b) in builders.indexed) {
      doc.addPage(
        pw.Page(
          pageTheme: kit.pageTheme(format: fmt, margin: 0),
          build: (c) => b(k + 2, total),
        ),
      );
    }
    return doc.save();
  }

  pw.Page _slideCover(PdfPageFormat fmt, int total) {
    final logo = i.brand.logo;
    return pw.Page(
      pageTheme: kit.pageTheme(
        format: fmt,
        margin: 0,
        background: (c) =>
            pw.Container(width: fmt.width, height: fmt.height, color: brand),
      ),
      build: (c) => pw.Padding(
        padding: const pw.EdgeInsets.fromLTRB(64, 52, 64, 40),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (logo != null)
              pw.Container(
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                  color: PdfColors.white,
                  borderRadius: pw.BorderRadius.circular(4),
                ),
                child: pw.SizedBox(
                  height: 44,
                  child: pw.Image(logo, fit: pw.BoxFit.contain),
                ),
              )
            else
              t(
                i.brand.companyName,
                size: 18,
                bold: true,
                color: i.brand.onColor,
              ),
            pw.Spacer(),
            t(
              _title.toUpperCase(),
              size: 12,
              bold: true,
              color: i.brand.onColor,
            ),
            pw.SizedBox(height: 10),
            t(
              i.periodLabel,
              size: 40,
              bold: true,
              color: i.brand.onColor,
              height: 4,
            ),
            pw.SizedBox(height: 26),
            if (i.recipient.trim().isNotEmpty)
              t(
                'Prepared for ${i.recipient.trim()}',
                size: 15,
                color: i.brand.onColor,
              ),
            pw.SizedBox(height: 4),
            t(
              i.preparedBy.trim().isEmpty
                  ? '${i.brand.companyName}  |  ${i.generatedOn}'
                  : '${i.preparedBy.trim()}, ${i.brand.companyName}  |  ${i.generatedOn}',
              size: 12,
              color: i.brand.onColor,
            ),
            pw.Spacer(),
            t(_confidential, size: 8.5, color: i.brand.onColor),
          ],
        ),
      ),
    );
  }
}
