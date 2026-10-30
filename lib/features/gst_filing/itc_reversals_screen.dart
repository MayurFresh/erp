import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/busy.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../compliance/compliance_widgets.dart';
import '../filings/filing_widgets.dart';
import 'gst_filing_models.dart';
import 'gst_filing_repository.dart';

/// `/gst/itc-reversals`: Rule 37 reversal and reclaim statement.
class ItcReversalsScreen extends ConsumerStatefulWidget {
  const ItcReversalsScreen({super.key});

  @override
  ConsumerState<ItcReversalsScreen> createState() => _ItcReversalsState();
}

class _ItcReversalsState extends ConsumerState<ItcReversalsScreen> {
  String _period = previousMonth();

  Future<void> _csv() async {
    try {
      final text = await runBlocking(
        context,
        () => ref.read(gstFilingRepositoryProvider).itcReversalsCsv(_period),
      );
      if (text != null && mounted) await shareText(context, text, 'CSV');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(itcReversalsProvider(_period));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'ITC reversal and reclaim',
          subtitle: 'Statement for GSTR-3B tables 4B(2) and 4D(1)',
          actions: [
            BusyButton(
              onPressed: _csv,
              label: 'Share CSV',
              icon: Icons.ios_share,
            ),
          ],
        ),
        FilterBar(
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: MonthPicker(
                period: _period,
                onChanged: (p) => setState(() => _period = p),
              ),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView<ItcReversals>(
            value: value,
            onRetry: () => ref.invalidate(itcReversalsProvider(_period)),
            data: (r) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: UnverifiedBadge(r.unverified),
                ),
                SectionCard(
                  title: 'Totals',
                  child: TaxTable(
                    firstColumn: '',
                    showTaxable: false,
                    rows: [
                      ('Reversal (4B(2))', r.reversal),
                      ('Reclaim (4D(1))', r.reclaim),
                    ],
                  ),
                ),
                if (r.rows.isEmpty)
                  const EmptyView(message: 'No reversals or reclaims.')
                else
                  for (final row in r.rows)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        title: Text('${row.number} · ${row.partyName}'),
                        subtitle: Text(
                          [
                            row.kind == 'reversal' ? 'Reverse' : 'Reclaim',
                            'bill ${formatDate(row.billDate)}',
                            'day 180 ${formatDate(row.day180)}',
                            'IGST ${formatAmount(row.igst)}',
                            'CGST ${formatAmount(row.cgst)}',
                            'SGST ${formatAmount(row.sgst)}',
                          ].join(' · '),
                        ),
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
