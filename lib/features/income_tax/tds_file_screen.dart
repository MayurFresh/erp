import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../compliance/compliance_widgets.dart' show recentFys, shareText;
import '../compliance/tax_perms.dart';
import '../filings/filing_models.dart';
import '../filings/filing_widgets.dart';
import '../reports/report_widgets.dart'
    show ReportSectionTitle, StatRow, StatTile;
import 'it_models.dart';
import 'it_repository.dart';
import 'it_widgets.dart';

const tdsFileSteps = <String>[
  'Pay the challan.',
  'Record it in Progen (TDS, Challans).',
  'Download the .txt file below.',
  'Run the FVU (Protean) with the challan CSI file.',
  'Upload the zip on incometax.gov.in.',
  'Note the token number.',
  'Mark the return filed here, with the token number.',
  'Download Form 131 (TDS certificate) from TRACES.',
  'Keep the acknowledgement PDF.',
];

/// `/tds/file?fy=&quarter=`: TDS filing pack for one quarter (API v1.6 §5).
class TdsFileScreen extends ConsumerStatefulWidget {
  const TdsFileScreen({super.key, this.fy, this.quarter});

  final String? fy;
  final int? quarter;

  @override
  ConsumerState<TdsFileScreen> createState() => _TdsFileScreenState();
}

class _TdsFileScreenState extends ConsumerState<TdsFileScreen> {
  late String _fy = widget.fy ?? recentFys().first;
  late int _quarter = (widget.quarter ?? 1).clamp(1, 4);
  List<PrefileCheck>? _blockers;
  bool _filed = false;

  Future<void> _download() async {
    setState(() => _blockers = null);
    try {
      final text = await ref
          .read(incomeTaxRepositoryProvider)
          .tdsStatementTxt(_fy, _quarter);
      if (mounted) await shareText(context, text, 'Form 140 .txt (BETA)');
    } catch (e) {
      final err = apiError(e);
      if (err?.code == 'PREFILE_FAILED') {
        final checks = asJsonList(
          err!.details['checks'],
        ).map(PrefileCheck.fromJson).toList();
        if (mounted) setState(() => _blockers = checks);
        return;
      }
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _markFiled() async {
    final f = await showMarkFiledDialog(
      context,
      ref,
      returnType: 'tds_140',
      period: '$_fy-Q$_quarter',
      arnLabel: 'Token number',
    );
    if (f != null && mounted) {
      setState(() => _filed = true);
      showInfoSnackBar(context, 'Marked as filed.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(TaxPerm.tdsManage);
    final key = (_fy, _quarter);
    final prefile = ref.watch(tdsPrefileProvider(key));
    final defaults = ref.watch(tdsDefaultsProvider(_fy));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'File TDS return',
          subtitle: 'Form 140, FY $_fy, Q$_quarter',
          actions: [
            OutlinedButton(
              onPressed: () => context.go('/tds'),
              child: const Text('Back'),
            ),
          ],
        ),
        FilterBar(
          children: [
            SizedBox(
              width: 150,
              child: DropdownButtonFormField<String>(
                initialValue: _fy,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Financial year'),
                items: [
                  for (final f in {...recentFys(), _fy})
                    DropdownMenuItem(value: f, child: Text(f)),
                ],
                onChanged: (v) => setState(() {
                  _fy = v ?? _fy;
                  _blockers = null;
                }),
              ),
            ),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('Q1')),
                ButtonSegment(value: 2, label: Text('Q2')),
                ButtonSegment(value: 3, label: Text('Q3')),
                ButtonSegment(value: 4, label: Text('Q4')),
              ],
              selected: {_quarter},
              onSelectionChanged: (s) => setState(() {
                _quarter = s.first;
                _blockers = null;
              }),
            ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              const ReportSectionTitle('1. Checks'),
              AsyncValueView<TdsPrefile>(
                value: prefile,
                onRetry: () => ref.invalidate(tdsPrefileProvider(key)),
                data: (p) => PrefileChecksList(checks: p.checks),
              ),
              const ReportSectionTitle('2. Late deposit and filing defaults'),
              AsyncValueView<TdsDefaults>(
                value: defaults,
                onRetry: () => ref.invalidate(tdsDefaultsProvider(_fy)),
                data: (d) => _DefaultsView(defaults: d, quarter: _quarter),
              ),
              Row(
                children: [
                  const Expanded(child: ReportSectionTitle('3. Download')),
                  Pill('BETA', color: Colors.orange.shade800),
                ],
              ),
              const Text(
                'This .txt is a draft. Validate it with the FVU before '
                'upload. If the FVU rejects the first comment line, remove it.',
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _download,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Copy .txt file'),
                ),
              ),
              if (_blockers != null) ...[
                const SizedBox(height: 8),
                const Text(
                  'The file was not produced. Fix these first:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                PrefileChecksList(checks: _blockers!),
              ],
              const ReportSectionTitle('4. Steps'),
              for (var i = 0; i < tdsFileSteps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('${i + 1}. ${tdsFileSteps[i]}'),
                ),
              const ReportSectionTitle('5. Mark filed'),
              if (_filed)
                const Text('Recorded as filed.')
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: manage ? _markFiled : null,
                    icon: const Icon(Icons.check),
                    label: const Text('Mark filed'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DefaultsView extends StatelessWidget {
  const _DefaultsView({required this.defaults, required this.quarter});

  final TdsDefaults defaults;
  final int quarter;

  @override
  Widget build(BuildContext context) {
    final d = defaults;
    final st = d.statements.where((s) => s.quarter == quarter).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UnverifiedNote(d.unverified),
        StatRow(
          children: [
            StatTile(
              label: 'Late deposit interest',
              value: formatMoney(d.interest),
            ),
            StatTile(label: 'Late filing fee', value: formatMoney(d.lateFee)),
          ],
        ),
        const Text('Add these to the challan when you pay.'),
        for (final s in st)
          Text(
            'Q${s.quarter} due ${formatDate(s.dueDate)}'
            '${s.daysLate > 0 ? ', ${s.daysLate} days late, fee ${formatMoney(s.lateFee)}' : ''}',
          ),
        for (final x in d.deposits.where((x) => x.monthsLate > 0))
          Text(
            '${x.month}: ${x.monthsLate} month(s) late, interest ${formatMoney(x.interest)}',
          ),
      ],
    );
  }
}
