import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../reports/report_widgets.dart' show tabularFigures;
import 'compliance_models.dart';
import 'compliance_repository.dart';
import 'compliance_widgets.dart';

/// `/bank-reconciliation`: imported statements and the import action.
class BankReconScreen extends ConsumerWidget {
  const BankReconScreen({super.key});

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final created = await showDialog<BankStatement>(
      context: context,
      builder: (_) => const _ImportDialog(),
    );
    if (created == null || !context.mounted) return;
    ref.read(complianceRevisionProvider.notifier).bump();
    context.go('/bank-reconciliation/${created.id}');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(bankStatementsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Bank reconciliation',
          subtitle: 'Match your bank statement with the books',
          actions: [
            FilledButton.icon(
              onPressed: () => _import(context, ref),
              icon: const Icon(Icons.upload_file),
              label: const Text('Import statement'),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView<List<BankStatement>>(
            value: value,
            onRetry: () => ref.invalidate(bankStatementsProvider),
            data: (list) => list.isEmpty
                ? const EmptyView(
                    message: 'No statements yet. Import a CSV from your bank.',
                    icon: Icons.account_balance_outlined,
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    children: [
                      for (final s in list)
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            onTap: () =>
                                context.go('/bank-reconciliation/${s.id}'),
                            title: Text(s.accountName),
                            subtitle: Text(
                              '${formatDate(s.fromDate)} – ${formatDate(s.toDate)}'
                              ' · ${s.fileName}\n'
                              '${s.lines} lines · ${s.matched} matched · '
                              '${s.unmatched} unmatched · ${s.ignored} ignored',
                            ),
                            isThreeLine: true,
                            trailing: s.unmatched == 0
                                ? const StatusPill('ok', label: 'Done')
                                : StatusPill(
                                    'warn',
                                    label: '${s.unmatched} open',
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

class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog();

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  AccountOption? _account;
  ({String name, String text})? _file;
  bool _busy = false;

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final s = await ref
          .read(complianceRepositoryProvider)
          .importStatement(
            accountId: _account!.id,
            csv: _file!.text,
            fileName: _file!.name,
          );
      if (mounted) Navigator.pop(context, s);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showErrorSnackBar(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Import bank statement'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PickerField(
            label: 'Bank account',
            value: _account?.label,
            onTap: () async {
              final a = await pickAccount(
                context,
                ref,
                title: 'Bank account',
                where: (a) => a.subtype == 'bank',
              );
              if (a != null) setState(() => _account = a);
            },
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              try {
                final f = await pickTextFile(const ['csv', 'txt']);
                if (f != null) setState(() => _file = f);
              } catch (e) {
                if (context.mounted) showErrorSnackBar(context, e);
              }
            },
            icon: const Icon(Icons.attach_file),
            label: Text(_file?.name ?? 'Choose CSV file'),
          ),
          const SizedBox(height: 8),
          Text(
            'Date, narration, debit/credit and balance columns are detected '
            'from common Indian bank exports. Lines already imported are skipped.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      BusyButton(
        busy: _busy,
        onPressed: _account == null || _file == null ? null : _submit,
        label: 'Import',
      ),
    ],
  );
}

// -------------------------------------------------------------------- Detail

/// `/bank-reconciliation/:id`: statement lines to match, ignore or book.
class BankStatementScreen extends ConsumerStatefulWidget {
  const BankStatementScreen({super.key, required this.id});

  final String id;

  @override
  ConsumerState<BankStatementScreen> createState() =>
      _BankStatementScreenState();
}

class _BankStatementScreenState extends ConsumerState<BankStatementScreen> {
  String? _filter;
  bool _busy = false;

  ComplianceRepository get _repo => ref.read(complianceRepositoryProvider);

  void _refresh() => ref.read(complianceRevisionProvider.notifier).bump();

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      _refresh();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _auto() => _run(() async {
    final n = await _repo.autoMatch(widget.id);
    if (mounted) {
      showInfoSnackBar(
        context,
        n == 0 ? 'Nothing new to match.' : 'Matched $n lines.',
      );
    }
  });

  Future<void> _candidates(BankLine line) async {
    final picked = await showModalBottomSheet<BankCandidate>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CandidatesSheet(line: line),
    );
    if (picked != null) {
      await _run(() => _repo.matchLine(line.id, picked.journalLineId));
    }
  }

  Future<void> _create(BankLine line) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _CreateEntryDialog(line: line),
    );
    if (ok == true) {
      _refresh();
      ref.invalidate(accountOptionsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(bankStatementProvider(widget.id));
    return AsyncValueView<BankStatement>(
      value: value,
      onRetry: () => ref.invalidate(bankStatementProvider(widget.id)),
      data: (s) {
        final lines = _filter == null
            ? s.lineRows
            : s.lineRows.where((l) => l.status == _filter).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: s.accountName,
              subtitle:
                  '${formatDate(s.fromDate)} – ${formatDate(s.toDate)} · ${s.fileName}',
              actions: [
                OutlinedButton.icon(
                  onPressed: () => context.go('/bank-reconciliation'),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Statements'),
                ),
                BusyButton(
                  busy: _busy,
                  onPressed: _auto,
                  label: 'Auto-match',
                  icon: Icons.auto_fix_high,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 24,
                runSpacing: 8,
                children: [
                  LabeledValue(
                    'Statement balance',
                    s.closingBalance == null
                        ? ''
                        : formatMoney(s.closingBalance),
                  ),
                  LabeledValue(
                    'Book balance',
                    s.bookBalance == null ? '' : formatMoney(s.bookBalance),
                  ),
                  LabeledValue(
                    'Difference',
                    s.difference == null ? '' : formatMoney(s.difference),
                  ),
                  LabeledValue(
                    'Book entries not matched',
                    '${s.unmatchedBook}',
                  ),
                ],
              ),
            ),
            FilterBar(
              children: [
                for (final (key, label, n) in [
                  (null, 'All', s.lineRows.length),
                  ('unmatched', 'Unmatched', s.unmatched),
                  ('matched', 'Matched', s.matched),
                  ('ignored', 'Ignored', s.ignored),
                ])
                  ChoiceChip(
                    label: Text('$label ($n)'),
                    selected: _filter == key,
                    onSelected: (_) => setState(() => _filter = key),
                  ),
              ],
            ),
            Expanded(
              child: lines.isEmpty
                  ? const EmptyView(
                      message: 'No lines here.',
                      icon: Icons.inbox_outlined,
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                      children: [
                        for (final l in lines)
                          _LineCard(
                            line: l,
                            onMatch: () => _candidates(l),
                            onUnmatch: () =>
                                _run(() => _repo.lineAction(l.id, 'unmatch')),
                            onIgnore: () =>
                                _run(() => _repo.lineAction(l.id, 'ignore')),
                            onCreate: () => _create(l),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({
    required this.line,
    required this.onMatch,
    required this.onUnmatch,
    required this.onIgnore,
    required this.onCreate,
  });

  final BankLine line;
  final VoidCallback onMatch;
  final VoidCallback onUnmatch;
  final VoidCallback onIgnore;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = line.match;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      StatusPill(
                        line.status == 'unmatched' ? 'warn' : line.status,
                        label: line.status,
                      ),
                      Text(
                        formatDate(line.date),
                        style: theme.textTheme.labelLarge,
                      ),
                      if (line.reference != null && line.reference!.isNotEmpty)
                        Text(line.reference!, style: theme.textTheme.bodySmall),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    line.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (m != null)
                    Text(
                      'Matched to ${m.number} (${m.voucherType}) ${formatDate(m.date)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.green.shade700,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 4),
              child: Text(
                '${line.isDeposit ? '+' : '−'}${formatAmount(line.amount)}',
                style: tabularFigures.copyWith(
                  fontWeight: FontWeight.w700,
                  color: line.isDeposit
                      ? Colors.green.shade700
                      : theme.colorScheme.error,
                ),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Line actions',
              onSelected: (v) => switch (v) {
                'match' => onMatch(),
                'unmatch' => onUnmatch(),
                'ignore' => onIgnore(),
                _ => onCreate(),
              },
              itemBuilder: (_) => [
                if (line.status == 'unmatched') ...[
                  const PopupMenuItem(
                    value: 'match',
                    child: Text('Find match'),
                  ),
                  const PopupMenuItem(
                    value: 'create',
                    child: Text('Create entry'),
                  ),
                  const PopupMenuItem(value: 'ignore', child: Text('Ignore')),
                ] else
                  PopupMenuItem(
                    value: 'unmatch',
                    child: Text(
                      line.status == 'ignored' ? 'Stop ignoring' : 'Unmatch',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidatesSheet extends ConsumerWidget {
  const _CandidatesSheet({required this.line});

  final BankLine line;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
    height: MediaQuery.sizeOf(context).height * 0.6,
    child: Column(
      children: [
        ListTile(
          title: Text('Candidates for ${formatAmount(line.amount)}'),
          subtitle: Text(
            line.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: FutureBuilder<List<BankCandidate>>(
            future: ref.read(complianceRepositoryProvider).candidates(line.id),
            builder: (context, snap) {
              if (snap.hasError) return ErrorView(error: snap.error!);
              if (!snap.hasData) return const LoadingView();
              final list = snap.data!;
              if (list.isEmpty) {
                return const EmptyView(
                  message: 'No book entry with the same amount within 10 days.',
                  icon: Icons.search_off,
                );
              }
              return ListView(
                children: [
                  for (final c in list)
                    ListTile(
                      onTap: () => Navigator.pop(context, c),
                      title: Text(
                        '${c.number} · ${c.partyName.isEmpty ? c.voucherType : c.partyName}',
                      ),
                      subtitle: Text(
                        '${formatDate(c.date)} · ${c.narration}',
                        maxLines: 2,
                      ),
                      trailing: Text(
                        formatAmount(c.amount),
                        style: tabularFigures,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}

class _CreateEntryDialog extends ConsumerStatefulWidget {
  const _CreateEntryDialog({required this.line});

  final BankLine line;

  @override
  ConsumerState<_CreateEntryDialog> createState() => _CreateEntryDialogState();
}

class _CreateEntryDialogState extends ConsumerState<_CreateEntryDialog> {
  late final _narration = TextEditingController(text: widget.line.description);
  AccountOption? _account;
  bool _busy = false;

  @override
  void dispose() {
    _narration.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await ref.read(complianceRepositoryProvider).createEntry(widget.line.id, {
        'accountId': _account!.id,
        if (_narration.text.trim().isNotEmpty)
          'narration': _narration.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showErrorSnackBar(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.line;
    return AlertDialog(
      title: const Text('Create bank entry'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${l.isDeposit ? 'Deposit' : 'Withdrawal'} of ${formatMoney(l.amount)} '
              'on ${formatDate(l.date)}. ${l.isDeposit ? 'Credits' : 'Debits'} '
              'the account you choose.',
            ),
            const SizedBox(height: 12),
            PickerField(
              label: 'Other account (e.g. bank charges, interest)',
              value: _account?.label,
              onTap: () async {
                final a = await pickAccount(
                  context,
                  ref,
                  title: 'Account',
                  where: (a) => a.subtype != 'bank' && a.subtype != 'cash',
                );
                if (a != null) setState(() => _account = a);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _narration,
              decoration: const InputDecoration(labelText: 'Narration'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        BusyButton(
          busy: _busy,
          onPressed: _account == null ? null : _submit,
          label: 'Create entry',
        ),
      ],
    );
  }
}
