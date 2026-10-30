import 'package:flutter/material.dart';

import '../compliance/compliance_models.dart' show Tax;
import 'gst_filing_models.dart';
import 'gst_form_widgets.dart';

class WorksheetRow {
  const WorksheetRow(this.code, this.label, this.figures);

  final String code;
  final String label;
  final List<(String, double)> figures;
}

List<(String, double)> _tax(Tax t, {bool taxable = false}) => [
  if (taxable) ('Taxable', t.taxable),
  ('IGST', t.igst),
  ('CGST', t.cgst),
  ('SGST', t.sgst),
];

List<(String, double)> _heads(Heads h) => [
  for (final k in gstHeads) (headLabel(k), h[k]),
];

/// GSTR-3B figures in the order of the portal's tables.
List<WorksheetRow> worksheetRows(Gstr3bSheet s, Setoff? so) {
  final netAB = Tax(
    igst: s.itcNet.igst - s.reclaimed.igst,
    cgst: s.itcNet.cgst - s.reclaimed.cgst,
    sgst: s.itcNet.sgst - s.reclaimed.sgst,
  );
  return [
    WorksheetRow(
      '3.1(a)',
      'Outward taxable supplies (other than zero rated, nil rated and exempted)',
      _tax(s.outward, taxable: true),
    ),
    WorksheetRow(
      '3.1(b)',
      'Outward taxable supplies (zero rated)',
      _tax(s.zeroRated, taxable: true),
    ),
    WorksheetRow('3.1(c)', 'Other outward supplies (nil rated, exempted)', [
      ('Taxable', s.zeroNil),
    ]),
    WorksheetRow(
      '3.1(d)',
      'Inward supplies (liable to reverse charge)',
      _tax(s.inwardRcm, taxable: true),
    ),
    WorksheetRow('3.1(e)', 'Non-GST outward supplies', [('Taxable', s.nonGst)]),
    if (s.interState.isEmpty)
      const WorksheetRow(
        '3.2',
        'Inter-State supplies to unregistered persons',
        [],
      )
    else
      for (final r in s.interState)
        WorksheetRow(
          '3.2',
          'Inter-State to unregistered persons, place of supply ${r.pos}',
          [('Taxable', r.taxable), ('IGST', r.igst)],
        ),
    WorksheetRow(
      '4A(3)',
      'ITC: inward supplies liable to reverse charge',
      _tax(s.itcRcm),
    ),
    WorksheetRow('4A(5)', 'ITC: all other ITC', _tax(s.itcOthers)),
    WorksheetRow('4B(1)', 'ITC reversed: rules 38, 42 and 43', _tax(s.rule42)),
    WorksheetRow('4B(2)', 'ITC reversed: others (Rule 37)', _tax(s.rule37)),
    WorksheetRow('4C', 'Net ITC available (A) - (B)', _tax(netAB)),
    WorksheetRow(
      '4D(1)',
      'ITC reclaimed (reversed earlier under 4B(2))',
      _tax(s.reclaimed),
    ),
    if (s.others2b != null)
      WorksheetRow('2B', 'For comparison: ITC in GSTR-2B', _tax(s.others2b!)),
    WorksheetRow('5', 'Inward supplies from composition, exempt, nil rated', [
      ('Inter-State', s.inwardExemptInter),
      ('Intra-State', s.inwardExemptIntra),
    ]),
    if (so != null) ...[
      WorksheetRow('6.1', 'Tax payable', [
        for (final k in gstHeads) (headLabel(k), so.liability[k] + so.rcm[k]),
      ]),
      WorksheetRow('6.1', 'Paid through ITC', _heads(so.creditUsed)),
      WorksheetRow('6.1', 'Paid in cash', _heads(so.cashTax)),
      WorksheetRow('6.1', 'Interest', [('Interest', so.cashInterest)]),
      WorksheetRow('6.1', 'Late fee', [('Late fee', so.cashLateFee)]),
    ],
  ];
}

/// Worksheet with a local "portal shows" tick per row and tap-to-copy
/// figures. The ticks are not saved.
class WorksheetView extends StatefulWidget {
  const WorksheetView({super.key, required this.sheet, this.setoff});

  final Gstr3bSheet sheet;
  final Setoff? setoff;

  @override
  State<WorksheetView> createState() => _WorksheetViewState();
}

class _WorksheetViewState extends State<WorksheetView> {
  final _ticked = <int>{};

  @override
  Widget build(BuildContext context) {
    final rows = worksheetRows(widget.sheet, widget.setoff);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Tap a figure to copy it. Tick a row when the portal shows the same '
          'number. ${_ticked.length} of ${rows.length} checked.',
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < rows.length; i++)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    key: ValueKey('tick-$i'),
                    value: _ticked.contains(i),
                    semanticLabel: 'Portal shows ${rows[i].code}',
                    onChanged: (v) => setState(
                      () => v == true ? _ticked.add(i) : _ticked.remove(i),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            '${rows[i].code}  ${rows[i].label}',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        if (rows[i].figures.isEmpty)
                          const Text('Nothing to enter')
                        else
                          Wrap(
                            children: [
                              for (final (l, v) in rows[i].figures)
                                CopyAmount(label: l, value: v),
                            ],
                          ),
                      ],
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
