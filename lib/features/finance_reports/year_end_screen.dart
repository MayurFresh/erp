import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../reports/report_widgets.dart';
import 'finance_models.dart';
import 'finance_repository.dart';

/// `/year-end`: explains the close, runs it, and reopens it.
class YearEndScreen extends ConsumerStatefulWidget {
  const YearEndScreen({super.key});

  @override
  ConsumerState<YearEndScreen> createState() => _YearEndState();
}

class _YearEndState extends ConsumerState<YearEndScreen> {
  late String _fy = _previousFy();
  bool _busy = false;

  static String _previousFy() {
    final now = DateTime.now();
    final start = (now.month >= 4 ? now.year : now.year - 1) - 1;
    return '$start-${((start + 1) % 100).toString().padLeft(2, '0')}';
  }

  List<String> get _years {
    final now = DateTime.now();
    final cur = now.month >= 4 ? now.year : now.year - 1;
    return [
      for (var y = cur; y >= cur - 5; y--)
        '$y-${((y + 1) % 100).toString().padLeft(2, '0')}',
    ];
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.read(financeRevisionProvider.notifier).bump();
      if (mounted) showInfoSnackBar(context, done);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close(YearEndPreview p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Close ${p.fy}?'),
        content: Text(
          'This posts one journal dated ${formatDate(p.to)} and locks the '
          'books up to that date. Nothing can be posted in the year after '
          'this, until an owner reopens it.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Close the year')),
        ],
      ),
    );
    if (ok == true) {
      await _run(() => ref.read(financeRepositoryProvider).closeYear(p.fy), 'Year ${p.fy} closed.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(yearEndPreviewProvider(_fy));
    final closes = ref.watch(yearEndClosesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Year-end close',
          subtitle: 'Move the year profit or loss to equity and lock the year',
        ),
        FilterBar(
          children: [
            SizedBox(
              width: 200,
              child: DropdownButtonFormField<String>(
                initialValue: _fy,
                decoration: const InputDecoration(labelText: 'Financial year'),
                items: [for (final y in _years) DropdownMenuItem(value: y, child: Text(y))],
                onChanged: (v) => setState(() => _fy = v ?? _fy),
              ),
            ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              ReportBodyInline<YearEndPreview>(
                value: preview,
                onRetry: () => ref.invalidate(yearEndPreviewProvider(_fy)),
                builder: (p) => _PreviewCard(preview: p, busy: _busy, onClose: () => _close(p)),
              ),
              const ReportSectionTitle('Closed years'),
              ReportBodyInline<List<YearEndClose>>(
                value: closes,
                onRetry: () => ref.invalidate(yearEndClosesProvider),
                builder: (list) => list.isEmpty
                    ? const Text('No year has been closed yet.')
                    : Column(
                        children: [
                          for (final c in list)
                            _CloseTile(
                              close: c,
                              busy: _busy,
                              onReopen: () => _run(
                                () => ref.read(financeRepositoryProvider).reopenYear(c.id),
                                'Year ${c.fy} reopened.',
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Loading, error or content inside a scrolling page.
class ReportBodyInline<T> extends StatelessWidget {
  const ReportBodyInline({super.key, required this.value, required this.builder, required this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => switch (value) {
    AsyncValue(:final T value, hasValue: true) => builder(value),
    AsyncValue(:final Object error, hasError: true) => SizedBox(height: 200, child: ErrorView(error: error, onRetry: onRetry)),
    _ => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
  };
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.preview, required this.busy, required this.onClose});
  final YearEndPreview preview;
  final bool busy;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final p = preview;
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Year ${p.fy}: ${formatDate(p.from)} to ${formatDate(p.to)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatementLine('Income', p.income),
          StatementLine('Expenses', p.expenses),
          const Divider(height: 12),
          StatementLine(p.profit >= 0 ? 'Profit' : 'Loss', p.profit.abs(), bold: true),
          const SizedBox(height: 12),
          Text('What closing does', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          for (final step in p.steps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('• $step'),
            ),
          if (p.willCreateEquityAccount)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('A Retained Earnings account will be created.'),
            ),
          for (final b in p.blockers)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(b)),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: p.canClose && !busy ? onClose : null,
              child: Text('Close ${p.fy}'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CloseTile extends StatelessWidget {
  const _CloseTile({required this.close, required this.busy, required this.onReopen});
  final YearEndClose close;
  final bool busy;
  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    minTileHeight: 56,
    title: Text('${close.fy}  ${close.isClosed ? 'Closed' : 'Reopened'}'),
    subtitle: Text(
      '${close.profit >= 0 ? 'Profit' : 'Loss'} ${formatMoney(close.profit.abs())} '
      'moved to ${close.equityAccountName} on ${formatDate(close.closeDate)}',
    ),
    trailing: close.isClosed
        ? OutlinedButton(onPressed: busy ? null : onReopen, child: const Text('Reopen'))
        : null,
  );
}
