import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import '../reports/report_widgets.dart' show tabularFigures;
import 'account_picker.dart';
import 'accounting_models.dart';
import 'accounting_repository.dart';

/// One editable row of the journal grid.
class _LineState {
  final key = UniqueKey();
  Account? account;
  Party? party;
  final debit = TextEditingController();
  final credit = TextEditingController();

  /// Message from the server for this row.
  String? serverError;

  JournalDraftLine get draft => JournalDraftLine(
    accountId: account?.id,
    accountSubtype: account?.subtype,
    partyId: accountTakesParty(account) ? party?.id : null,
    debit: parseNumber(debit.text) ?? 0,
    credit: parseNumber(credit.text) ?? 0,
  );

  void dispose() {
    debit.dispose();
    credit.dispose();
  }
}

/// `/journals/new`: a manual journal voucher. Save stays disabled until
/// debits equal credits.
class JournalCreateScreen extends ConsumerStatefulWidget {
  const JournalCreateScreen({super.key});

  @override
  ConsumerState<JournalCreateScreen> createState() =>
      _JournalCreateScreenState();
}

class _JournalCreateScreenState extends ConsumerState<JournalCreateScreen> {
  final _narration = TextEditingController();
  final List<_LineState> _lines = [_LineState(), _LineState()];
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  bool _saving = false;
  Map<String, String> _serverErrors = const {};

  /// Rows that will be sent, in order (server line index → row).
  List<_LineState> get _sentRows =>
      _lines.where((l) => !l.draft.isBlank).toList();

  JournalDraft get _draft => JournalDraft(
    date: _date,
    narration: _narration.text,
    lines: [for (final l in _lines) l.draft],
  );

  @override
  void dispose() {
    _narration.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  void _changed(_LineState line) => setState(() => line.serverError = null);

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: kMinDocDate,
      lastDate: DateUtils.dateOnly(now),
      helpText: 'Journal date',
    );
    if (picked != null) {
      setState(() {
        _date = picked;
        _serverErrors = Map.of(_serverErrors)..remove('date');
      });
    }
  }

  Future<void> _pickAccount(_LineState line) async {
    final account = await pickAccount(context, ref);
    if (account == null || !mounted) return;
    setState(() {
      if (line.account?.subtype != account.subtype) line.party = null;
      line.account = account;
      line.serverError = null;
    });
  }

  Future<void> _pickParty(_LineState line) async {
    final party = await pickParty(
      context,
      ref,
      type: line.account?.subtype == 'payables'
          ? PartyType.vendor
          : PartyType.customer,
    );
    if (party == null || !mounted) return;
    setState(() {
      line.party = party;
      line.serverError = null;
    });
  }

  void _addLine() => setState(() => _lines.add(_LineState()));

  void _removeLine(_LineState line) {
    if (_lines.length <= JournalDraft.minLines) {
      setState(() {
        line
          ..account = null
          ..party = null
          ..serverError = null;
        line.debit.clear();
        line.credit.clear();
      });
      return;
    }
    setState(() => _lines.remove(line));
    line.dispose();
  }

  /// Fills the difference into this row on the side that is short.
  void _balanceInto(_LineState line) {
    final diff = _draft.difference - (line.draft.debit - line.draft.credit);
    setState(() {
      if (diff > 0) {
        line.debit.clear();
        line.credit.text = formatPlain(diff);
      } else if (diff < 0) {
        line.credit.clear();
        line.debit.text = formatPlain(-diff);
      }
      line.serverError = null;
    });
  }

  Future<void> _save() async {
    final draft = _draft;
    if (!draft.canSave) return;
    final sent = _sentRows;
    setState(() {
      _saving = true;
      _serverErrors = const {};
      for (final l in _lines) {
        l.serverError = null;
      }
    });
    try {
      final entry = await ref
          .read(accountingRepositoryProvider)
          .createJournal(draft);
      ref.bump(const [DataKind.accounts]);
      if (!mounted) return;
      showInfoSnackBar(context, 'Posted ${entry.number ?? 'journal'}');
      context.go('/journals');
    } catch (e) {
      if (!mounted) return;
      final fields = apiError(e)?.fieldErrors ?? const <String, String>{};
      setState(() {
        _serverErrors = {
          for (final MapEntry(:key, :value) in fields.entries)
            if (journalLineIndex(key) == null) key: value,
        };
        for (final MapEntry(:key, :value) in fields.entries) {
          final index = journalLineIndex(key);
          if (index != null && index < sent.length) {
            sent[index].serverError = value;
          }
        }
      });
      showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final perms = ref.watch(permissionsProvider);
    final canParty = perms.can(Perm.partiesView);
    final draft = _draft;
    final problems = draft.problems;

    return FormPage(
      maxWidth: 1100,
      children: [
        Text('New journal', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Manual journal voucher (JV). Each line is either a debit or a '
          'credit; total debits must equal total credits.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          child: FormRow(
            children: [
              PickerField(
                label: 'Date',
                value: formatDate(_date),
                icon: Icons.event_outlined,
                errorText: _serverErrors['date'],
                onTap: _pickDate,
              ),
              TextField(
                controller: _narration,
                decoration: InputDecoration(
                  labelText: 'Narration',
                  hintText: 'e.g. Cash withdrawn from bank for site expenses',
                  errorText: _serverErrors['narration'],
                ),
                textCapitalization: TextCapitalization.sentences,
                maxLines: null,
                onChanged: (_) => setState(
                  () =>
                      _serverErrors = Map.of(_serverErrors)
                        ..remove('narration'),
                ),
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Lines',
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 760;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (wide) const _GridHeader(),
                  for (final (i, line) in _lines.indexed) ...[
                    if (i > 0) const Divider(height: 16),
                    _JournalLineRow(
                      key: line.key,
                      index: i,
                      line: line,
                      wide: wide,
                      canParty: canParty,
                      showBalance:
                          !draft.isBalanced &&
                          draft.difference != 0 &&
                          line.account != null,
                      onPickAccount: () => _pickAccount(line),
                      onPickParty: () => _pickParty(line),
                      onClearParty: () => setState(() => line.party = null),
                      onRemove: () => _removeLine(line),
                      onBalance: () => _balanceInto(line),
                      onChanged: () => _changed(line),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _lines.length >= JournalDraft.maxLines
                          ? null
                          : _addLine,
                      icon: const Icon(Icons.add),
                      label: const Text('Add line'),
                    ),
                  ),
                  if (_serverErrors['lines'] != null)
                    Text(
                      _serverErrors['lines']!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                ],
              );
            },
          ),
        ),
        _TotalsCard(draft: draft),
        if (problems.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              problems.first,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: _saving ? null : () => context.go('/journals'),
              child: const Text('Cancel'),
            ),
            BusyButton(
              busy: _saving,
              onPressed: draft.canSave ? _save : null,
              label: 'Post journal',
            ),
          ],
        ),
      ],
    );
  }
}

class _GridHeader extends StatelessWidget {
  const _GridHeader();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const SizedBox(width: 32),
          Expanded(flex: 4, child: Text('Account', style: style)),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Text('Party (receivable / payable)', style: style),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 140,
            child: Text('Debit', style: style, textAlign: TextAlign.right),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 140,
            child: Text('Credit', style: style, textAlign: TextAlign.right),
          ),
          const SizedBox(width: 96),
        ],
      ),
    );
  }
}

class _JournalLineRow extends StatelessWidget {
  const _JournalLineRow({
    super.key,
    required this.index,
    required this.line,
    required this.wide,
    required this.canParty,
    required this.showBalance,
    required this.onPickAccount,
    required this.onPickParty,
    required this.onClearParty,
    required this.onRemove,
    required this.onBalance,
    required this.onChanged,
  });

  final int index;
  final _LineState line;
  final bool wide;
  final bool canParty;
  final bool showBalance;
  final VoidCallback onPickAccount;
  final VoidCallback onPickParty;
  final VoidCallback onClearParty;
  final VoidCallback onRemove;
  final VoidCallback onBalance;
  final VoidCallback onChanged;

  Widget _amount(
    TextEditingController own,
    TextEditingController other,
    String label,
  ) => TextField(
    controller: own,
    decoration: InputDecoration(
      labelText: wide ? null : label,
      hintText: wide ? '0.00' : null,
      prefixText: '₹ ',
      isDense: true,
    ),
    textAlign: TextAlign.right,
    style: tabularFigures,
    keyboardType: decimalKeyboard,
    inputFormatters: [decimalInput()],
    onChanged: (text) {
      // A line is either a debit or a credit.
      if (text.trim().isNotEmpty && other.text.isNotEmpty) other.clear();
      onChanged();
    },
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final takesParty = accountTakesParty(line.account);
    final error = line.serverError ?? line.draft.error;
    final account = PickerField(
      label: 'Account',
      value: line.account?.displayName,
      onTap: onPickAccount,
    );
    final party = takesParty && canParty
        ? Row(
            children: [
              Expanded(
                child: PickerField(
                  label: line.account?.subtype == 'payables'
                      ? 'Vendor (optional)'
                      : 'Customer (optional)',
                  value: line.party?.name,
                  icon: Icons.person_search_outlined,
                  onTap: onPickParty,
                ),
              ),
              if (line.party != null)
                IconButton(
                  tooltip: 'Clear party',
                  onPressed: onClearParty,
                  icon: const Icon(Icons.close),
                ),
            ],
          )
        : null;
    final actions = [
      if (showBalance)
        IconButton(
          tooltip: 'Put the difference on this line',
          onPressed: onBalance,
          icon: const Icon(Icons.balance_outlined),
        ),
      IconButton(
        tooltip: 'Remove line',
        onPressed: onRemove,
        icon: const Icon(Icons.delete_outline),
      ),
    ];
    final errorText = error == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          );

    if (wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(width: 32, child: Text('${index + 1}')),
              Expanded(flex: 4, child: account),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child:
                    party ??
                    Text(
                      takesParty ? '' : '—',
                      style: TextStyle(color: theme.colorScheme.outline),
                    ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 140,
                child: _amount(line.debit, line.credit, 'Debit'),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 140,
                child: _amount(line.credit, line.debit, 'Credit'),
              ),
              SizedBox(
                width: 96,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: actions,
                ),
              ),
            ],
          ),
          ?errorText,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Line ${index + 1}',
                style: theme.textTheme.labelLarge,
              ),
            ),
            ...actions,
          ],
        ),
        account,
        if (party != null) ...[const SizedBox(height: 12), party],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _amount(line.debit, line.credit, 'Debit')),
            const SizedBox(width: 12),
            Expanded(child: _amount(line.credit, line.debit, 'Credit')),
          ],
        ),
        ?errorText,
      ],
    );
  }
}

/// Live totals and the difference indicator.
class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.draft});

  final JournalDraft draft;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final balanced = draft.isBalanced;
    final empty = draft.totalDebitPaise == 0 && draft.totalCreditPaise == 0;
    final color = balanced
        ? Colors.green.shade700
        : empty
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.error;
    Widget figure(String label, String value, {Color? valueColor}) => Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: theme.textTheme.labelMedium),
        Text(
          value,
          style: theme.textTheme.titleMedium
              ?.merge(tabularFigures)
              .copyWith(fontWeight: FontWeight.w700, color: valueColor),
        ),
      ],
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 24,
          runSpacing: 12,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  balanced ? Icons.check_circle : Icons.error_outline,
                  color: color,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    empty
                        ? 'Enter the amounts'
                        : journalDifferenceLabel(draft.difference),
                    style: theme.textTheme.titleSmall?.copyWith(color: color),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                figure('Total debit', formatMoney(draft.totalDebit)),
                figure('Total credit', formatMoney(draft.totalCredit)),
                figure(
                  'Difference',
                  formatMoney(draft.difference.abs()),
                  valueColor: balanced ? null : color,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
