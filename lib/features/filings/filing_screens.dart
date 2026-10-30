import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/busy.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/states.dart';
import '../compliance/compliance_widgets.dart';
import 'filing_models.dart';
import 'filing_widgets.dart';
import 'filings_repository.dart';

const _returnTypes = {
  'gstr1': 'GSTR-1',
  'gstr3b': 'GSTR-3B',
  'pmt06': 'PMT-06',
  'gstr9': 'GSTR-9',
  'tds_140': 'TDS Form 140',
  'itr': 'ITR',
};

/// `/filings`: register of filed returns, with cancel.
class FilingRegisterScreen extends ConsumerStatefulWidget {
  const FilingRegisterScreen({super.key});

  @override
  ConsumerState<FilingRegisterScreen> createState() => _RegisterState();
}

class _RegisterState extends ConsumerState<FilingRegisterScreen> {
  String? _type;
  String _fy = contractFy(DateTime.now());
  late final PagedController<Filing> _controller;

  @override
  void initState() {
    super.initState();
    _controller = PagedController<Filing>((_, _) async {
      final rows = await ref
          .read(filingsRepositoryProvider)
          .list(returnType: _type, fy: _fy);
      return Paged(rows, rows.length);
    })..refresh();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _cancel(Filing f) async {
    final reason = await askReason(
      context,
      'Cancel ${returnTypeLabel(f.returnType)} ${f.period}?',
    );
    if (reason == null || !mounted) return;
    try {
      await runBlocking(
        context,
        () => ref.read(filingsRepositoryProvider).cancel(f.id, reason),
      );
      ref.read(filingsRevisionProvider.notifier).bump();
      await _controller.refresh();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Widget _status(Filing f) => StatusPill(f.status);

  Widget _cancelButton(Filing f) => f.cancelled
      ? const SizedBox.shrink()
      : TextButton(onPressed: () => _cancel(f), child: const Text('Cancel'));

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      PageHeader(
        title: 'Filing register',
        subtitle: 'Returns you have filed on the portal',
        actions: [
          OutlinedButton.icon(
            onPressed: () => context.go('/filings/calendar'),
            icon: const Icon(Icons.event_outlined),
            label: const Text('Calendar'),
          ),
        ],
      ),
      FilterBar(
        children: [
          FilterDropdown<String>(
            width: 140,
            label: 'Return',
            value: _type,
            options: _returnTypes,
            onChanged: (v) {
              setState(() => _type = v);
              _controller.refresh();
            },
          ),
          FilterDropdown<String>(
            width: 140,
            label: 'Year',
            value: _fy,
            options: {for (final y in recentFys()) y: y},
            onChanged: (v) {
              setState(() => _fy = v ?? _fy);
              _controller.refresh();
            },
          ),
        ],
      ),
      Expanded(
        child: AdaptiveDataList<Filing>(
          controller: _controller,
          emptyMessage: 'No filings recorded.',
          columns: [
            TableColumnSpec(
              'Return',
              (f) => Text(returnTypeLabel(f.returnType)),
            ),
            TableColumnSpec('Period', (f) => Text(f.period)),
            TableColumnSpec('Filed on', (f) => Text(formatDate(f.filedOn))),
            TableColumnSpec('ARN', (f) => Text(f.arn ?? '—'), maxWidth: 200),
            TableColumnSpec(
              'Paid',
              (f) =>
                  Text(f.amountPaid == null ? '—' : formatAmount(f.amountPaid)),
              numeric: true,
            ),
            TableColumnSpec('Status', _status),
            TableColumnSpec('', _cancelButton),
          ],
          cardBuilder: (context, f) => Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '${returnTypeLabel(f.returnType)} · ${f.period}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      _status(f),
                    ],
                  ),
                  Text(
                    [
                      'Filed ${formatDate(f.filedOn)}',
                      if (f.arn != null && f.arn!.isNotEmpty) f.arn!,
                      if (f.amountPaid != null) formatMoney(f.amountPaid),
                    ].join(' · '),
                  ),
                  if (f.cancelled && f.cancelReason != null)
                    Text('Cancelled: ${f.cancelReason}'),
                  if (f.acknowledgedFailures.isNotEmpty)
                    Text(
                      '${f.acknowledgedFailures.length} failed check(s) '
                      'acknowledged',
                    ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: _cancelButton(f),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

/// `/filings/calendar`: every due date of a financial year.
class FilingCalendarScreen extends ConsumerStatefulWidget {
  const FilingCalendarScreen({super.key});

  @override
  ConsumerState<FilingCalendarScreen> createState() => _CalendarState();
}

class _CalendarState extends ConsumerState<FilingCalendarScreen> {
  String _fy = contractFy(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(filingCalendarProvider(_fy));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Filing calendar',
          subtitle: 'Due dates for FY $_fy',
          actions: [
            OutlinedButton.icon(
              onPressed: () => context.go('/filings'),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Register'),
            ),
          ],
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              width: 140,
              label: 'Year',
              value: _fy,
              options: {for (final y in recentFys()) y: y},
              onChanged: (v) => setState(() => _fy = v ?? _fy),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView<List<FilingCalendarRow>>(
            value: rows,
            onRetry: () => ref.invalidate(filingCalendarProvider(_fy)),
            data: (list) => list.isEmpty
                ? const EmptyView(message: 'No due dates for this year.')
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _CalendarTile(row: list[i]),
                  ),
          ),
        ),
      ],
    );
  }
}

class _CalendarTile extends StatelessWidget {
  const _CalendarTile({required this.row});

  final FilingCalendarRow row;

  @override
  Widget build(BuildContext context) {
    final route = filingRoute(row.returnType, row.period);
    final est = row.estimateLateFee == null
        ? null
        : 'Late fee ${formatMoney(row.estimateLateFee)}, interest '
              '${formatMoney(row.estimateInterest)}';
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        title: Text(row.label),
        subtitle: Text(
          [
            'Due ${formatDate(row.dueDate)}',
            if (row.daysLate != null && row.daysLate! > 0)
              '${row.daysLate} days late',
            ?est,
          ].join(' · '),
        ),
        trailing: Wrap(
          spacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            StatusPill(row.status),
            if (route != null && row.status != 'filed')
              const Icon(Icons.chevron_right),
          ],
        ),
        onTap: route == null ? null : () => context.go(route),
      ),
    );
  }
}
