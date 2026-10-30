import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/busy.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../compliance/compliance_widgets.dart' show recentFys;
import '../compliance/tax_perms.dart';
import '../income_tax/it_widgets.dart';
import '../reports/report_widgets.dart' show tabularFigures;
import 'fa_models.dart';
import 'fa_repository.dart';

/// Friendly text for the depreciation-run errors of API v1.6 §7.
String depreciationErrorMessage(Object error) {
  final code = apiError(error)?.code;
  return switch (code) {
    'RUN_OVERLAP' =>
      'Every asset is already depreciated up to that date. Pick a later date.',
    'NOT_LATEST' =>
      'Only the latest posted run can be cancelled. Cancel the later runs '
          'first.',
    'ALREADY_CANCELLED' => 'This run is already cancelled.',
    _ => errorMessage(error),
  };
}

class DepreciationTab extends ConsumerStatefulWidget {
  const DepreciationTab({super.key});

  @override
  ConsumerState<DepreciationTab> createState() => _DepreciationTabState();
}

class _DepreciationTabState extends ConsumerState<DepreciationTab> {
  late String _fy = recentFys().first;

  Future<void> _run() async {
    final run = await showDialog<DepRun>(
      context: context,
      builder: (_) => const DepreciationRunDialog(),
    );
    if (run == null || !mounted) return;
    ref.read(faRevisionProvider.notifier).bump();
    showInfoSnackBar(
      context,
      'Depreciation ${run.number} posted: ${formatMoney(run.total)}',
    );
  }

  Future<void> _cancel(DepRun run) async {
    final reason = await askReasonDialog(
      context,
      title: 'Cancel ${run.number}?',
      helper: 'The journal is reversed and the assets roll back.',
      confirmLabel: 'Cancel run',
    );
    if (reason == null || !mounted) return;
    try {
      await runBlocking(
        context,
        () => ref.read(fixedAssetRepositoryProvider).cancelRun(run.id!, reason),
      );
      ref.read(faRevisionProvider.notifier).bump();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(depreciationErrorMessage(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(TaxPerm.assetsManage);
    final runs = ref.watch(depRunsProvider(_fy));
    return Column(
      children: [
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Financial year',
              value: _fy,
              options: {for (final f in recentFys()) f: f},
              anyLabel: _fy,
              width: 180,
              onChanged: (v) => setState(() => _fy = v ?? _fy),
            ),
            if (manage)
              FilledButton.icon(
                onPressed: _run,
                icon: const Icon(Icons.calculate_outlined),
                label: const Text('Run depreciation'),
              ),
          ],
        ),
        Expanded(
          child: AsyncValueView<List<DepRun>>(
            value: runs,
            onRetry: () => ref.invalidate(depRunsProvider(_fy)),
            data: (list) => list.isEmpty
                ? const EmptyView(
                    message: 'No depreciation runs in this year.',
                    icon: Icons.trending_down,
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final r = list[i];
                      return Card(
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          title: Text(
                            '${r.number} · up to ${formatDate(r.toDate)}',
                          ),
                          subtitle: Text(
                            '${r.lines.length} assets${r.cancelled ? ' · Cancelled' : ''}',
                          ),
                          trailing: Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(formatMoney(r.total), style: tabularFigures),
                              if (manage && !r.cancelled && r.id != null)
                                IconButton(
                                  tooltip: 'Cancel run',
                                  onPressed: () => _cancel(r),
                                  icon: const Icon(Icons.cancel_outlined),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

/// Pick the run date, preview the lines, then confirm to post. Pops the
/// posted [DepRun].
class DepreciationRunDialog extends ConsumerStatefulWidget {
  const DepreciationRunDialog({super.key});

  @override
  ConsumerState<DepreciationRunDialog> createState() =>
      _DepreciationRunDialogState();
}

class _DepreciationRunDialogState extends ConsumerState<DepreciationRunDialog> {
  DateTime _toDate = DateTime.now();
  DepRun? _preview;
  String? _error;

  Future<void> _previewRun() async {
    setState(() => _error = null);
    try {
      final p = await ref
          .read(fixedAssetRepositoryProvider)
          .runDepreciation(toDate: apiDate(_toDate), preview: true);
      if (mounted) setState(() => _preview = p);
    } catch (e) {
      if (mounted) setState(() => _error = depreciationErrorMessage(e));
    }
  }

  Future<void> _post() async {
    try {
      final run = await ref
          .read(fixedAssetRepositoryProvider)
          .runDepreciation(toDate: apiDate(_toDate));
      if (mounted) Navigator.pop(context, run);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = depreciationErrorMessage(e);
          _preview = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    return AlertDialog(
      title: const Text('Run depreciation'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DateButton(
                label: 'Depreciate up to',
                value: _toDate,
                onChanged: (d) => setState(() {
                  _toDate = d;
                  _preview = null;
                  _error = null;
                }),
              ),
              const SizedBox(height: 8),
              const Text(
                'Every active asset is depreciated from where it last stopped. '
                'Check the lines before posting.',
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (p != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Preview: ${p.lines.length} assets, '
                  'total ${formatMoney(p.total)}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                for (final l in p.lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            '${l.number} ${l.name}\n'
                            '${formatDate(l.from)} to ${formatDate(l.to)} · ${l.days} days',
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(formatAmount(l.amount), style: tabularFigures),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (p == null)
          BusyButton(
            onPressed: _previewRun,
            label: 'Preview',
            icon: Icons.visibility_outlined,
          )
        else
          BusyButton(
            onPressed: p.lines.isEmpty ? null : _post,
            label: 'Confirm and post',
          ),
      ],
    );
  }
}
