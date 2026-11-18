import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/file_save.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../compliance/compliance_widgets.dart' show recentFys;
import 'tds_forms_repository.dart';
import 'tds_forms_widgets.dart';

/// `/tds-returns`: quarterly data for 24Q / Form 138 (salary) and 26Q /
/// Form 140 (other payments), with validation results.
class TdsReturnsScreen extends ConsumerStatefulWidget {
  const TdsReturnsScreen({super.key});

  @override
  ConsumerState<TdsReturnsScreen> createState() => _TdsReturnsScreenState();
}

class _TdsReturnsScreenState extends ConsumerState<TdsReturnsScreen> {
  String _kind = 'salary';
  late String _fy = recentFys().first;
  int _quarter = 1;

  Future<void> _csv(String form) async {
    try {
      final text = await ref
          .read(tdsFormsRepositoryProvider)
          .tdsReturnCsv(_kind, _fy, _quarter);
      await saveTextFile('tds-$form-$_fy-q$_quarter-working.csv', text);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(tdsReturnProvider((_kind, _fy, _quarter)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'TDS returns',
          subtitle: 'Quarterly data and checks before you file',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'salary', label: Text('Salary')),
              ButtonSegment(value: 'non_salary', label: Text('Other payments')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
        ),
        PeriodBar(
          fy: _fy,
          onFy: (v) => setState(() => _fy = v),
          quarter: _quarter,
          onQuarter: (v) => setState(() => _quarter = v),
        ),
        Expanded(
          child: AsyncValueView(
            value: data,
            onRetry: () =>
                ref.invalidate(tdsReturnProvider((_kind, _fy, _quarter))),
            data: (d) {
              final fee = asJson(d['lateFee']);
              final interest = asJson(d['lateInterest']);
              final form = asString(d['form']);
              return ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${_kind == 'salary' ? '24Q' : '26Q'} is Form $form '
                          'for this period. ${asString(d['periodLabel'])}.',
                        ),
                        if (d['unconfirmed'] == true) const UnconfirmedBadge(),
                      ],
                    ),
                  ),
                  ListTile(
                    title: const Text('Tax deducted in the quarter'),
                    trailing: Text(formatMoney(asDouble(d['totalTds']))),
                  ),
                  ListTile(
                    title: const Text('Late deposit interest'),
                    subtitle: const Text('1.5% a month or part, unconfirmed'),
                    trailing: Text(formatMoney(asDouble(interest['total']))),
                  ),
                  ListTile(
                    title: Text(
                      'Late filing fee (${asInt(fee['daysLate'])} days after '
                      '${formatDate(asString(fee['dueDate']))})',
                    ),
                    subtitle: const Text('Rs 200 a day, up to the tax'),
                    trailing: Text(formatMoney(asDouble(fee['lateFee']))),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('Checks'),
                  ),
                  for (final c in asJsonList(d['checks'])) CheckTile(check: c),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: () => _csv(form),
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('Download working CSV'),
                        ),
                        const SizedBox(
                          width: 320,
                          child: Text(
                            'The CSV is OneMatrix\'s own layout. It is not the '
                            'Protean RPU import format, which could not be '
                            'confirmed. Use it to key the return into the '
                            'RPU, then run the FVU.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
