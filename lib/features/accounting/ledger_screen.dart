import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import '../parties/party_reminder.dart';
import '../reports/report_export.dart';
import '../reports/report_period.dart';
import '../reports/report_widgets.dart';
import 'accounting_models.dart';
import 'accounting_repository.dart';
import 'journal_widgets.dart';

/// `/accounts/:id`: opening balance, every posting in the period with the
/// running balance, totals and the closing balance.
class AccountLedgerScreen extends ConsumerStatefulWidget {
  const AccountLedgerScreen({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<AccountLedgerScreen> createState() =>
      _AccountLedgerScreenState();
}

class _AccountLedgerScreenState extends ConsumerState<AccountLedgerScreen> {
  DateRange _range = DateRange.fyToDate();
  Party? _party;

  LedgerKey get _key => (
    accountId: widget.accountId,
    from: _range.apiFrom,
    to: _range.apiTo,
    partyId: _party?.id,
  );

  Future<void> _pickParty(Account account) async {
    final party = await pickParty(
      context,
      ref,
      type: account.subtype == 'payables'
          ? PartyType.vendor
          : PartyType.customer,
    );
    if (party != null) setState(() => _party = party);
  }

  void _open(LedgerLine line) {
    final route = openableDocumentRoute(
      ref.read(permissionsProvider),
      line.voucherType,
      line.route,
    );
    if (route != null) {
      context.push(route);
    } else {
      showJournalEntryDialog(context, line.entryId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final chart = ref.watch(chartOfAccountsProvider).value;
    Account? account;
    for (final a in chart ?? const <Account>[]) {
      if (a.id == widget.accountId) account = a;
    }
    final value = ref.watch(accountLedgerProvider(_key));
    final ledger = value.value;
    final title = account?.name ?? ledger?.accountName ?? 'Ledger';
    final subtitle = account == null
        ? 'Account ledger'
        : [
            account.code,
            accountTypeLabel(account.type),
            if (account.subtype != 'other')
              accountSubtypeLabel(account.subtype),
            if (!account.isActive) 'Inactive',
          ].join(' · ');
    final partyFilter =
        account != null &&
        accountTakesParty(account) &&
        perms.can(Perm.partiesView);

    return ReportPage(
      title: title,
      subtitle: subtitle,
      export: ledger == null
          ? null
          : ledgerExport(ledger, title: title, party: _party?.name),
      controls: [
        PeriodButton(
          value: _range,
          onChanged: (r) => setState(() => _range = r),
        ),
        if (partyFilter)
          _party == null
              ? OutlinedButton.icon(
                  onPressed: () => _pickParty(account!),
                  icon: const Icon(Icons.person_search_outlined),
                  label: const Text('All parties'),
                )
              : InputChip(
                  avatar: const Icon(Icons.person_outline, size: 18),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(_party!.name, overflow: TextOverflow.ellipsis),
                  ),
                  onPressed: () => _pickParty(account!),
                  onDeleted: () => setState(() => _party = null),
                ),
        if (partyFilter &&
            _party != null &&
            account.subtype == 'receivables' &&
            (ledger?.closingBalance ?? 0) > 0)
          OutlinedButton.icon(
            onPressed: () => sendPartyReminder(
              context,
              ref,
              partyId: _party!.id,
              partyName: _party!.name,
              amountDue: ledger!.closingBalance,
            ),
            icon: const Icon(Icons.chat_outlined),
            label: const Text('Send reminder'),
          ),
      ],
      body: ReportBody<Ledger>(
        value: value,
        onRetry: () => ref.invalidate(accountLedgerProvider(_key)),
        builder: (l) => [
          StatRow(
            children: [
              StatTile(
                label: 'Opening balance',
                value: drCr(l.openingBalance, formatMoney),
                caption: formatDate(l.from),
              ),
              StatTile(label: 'Debits', value: formatMoney(l.totalDebit)),
              StatTile(label: 'Credits', value: formatMoney(l.totalCredit)),
              StatTile(
                label: 'Closing balance',
                value: drCr(l.closingBalance, formatMoney),
                caption: formatDate(l.to),
              ),
            ],
          ),
          LedgerTable(ledger: l, onOpen: _open),
        ],
      ),
    );
  }
}

/// One row of [LedgerTable]: the opening line, a posting or the closing
/// line.
class _Row {
  const _Row.opening(this.balance, this.date)
    : line = null,
      label = 'Opening balance';
  const _Row.closing(this.balance, this.date)
    : line = null,
      label = 'Closing balance';
  _Row.line(LedgerLine this.line)
    : balance = line.balance,
      date = line.date,
      label = null;

  final LedgerLine? line;
  final double balance;
  final String? date;
  final String? label;
}

/// Ledger lines as a table (opening, postings, totals, closing), or as
/// cards on phones.
class LedgerTable extends StatelessWidget {
  const LedgerTable({super.key, required this.ledger, this.onOpen});

  final Ledger ledger;
  final ValueChanged<LedgerLine>? onOpen;

  @override
  Widget build(BuildContext context) {
    final l = ledger;
    final hasParty = l.lines.any((x) => x.partyName != null);
    final rows = [
      _Row.opening(l.openingBalance, l.from),
      for (final line in l.lines) _Row.line(line),
      _Row.closing(l.closingBalance, l.to),
    ];
    String bal(double b) => drCr(b, formatMoney);
    String money(double v) => v == 0 ? '' : formatMoney(v);
    final open = onOpen;
    return ReportTable<_Row>(
      rows: rows,
      columns: [
        ReportColumn('Date', (r) => formatDate(r.date)),
        ReportColumn('Voucher', (r) => r.line?.voucherLabel ?? r.label!),
        ReportColumn('Number', (r) => r.line?.number ?? ''),
        ReportColumn(
          'Narration',
          (r) => r.line?.narration ?? '',
          flex: true,
          maxWidth: 320,
        ),
        if (hasParty)
          ReportColumn('Party', (r) => r.line?.partyName ?? '', maxWidth: 200),
        ReportColumn('Debit', (r) => money(r.line?.debit ?? 0), numeric: true),
        ReportColumn(
          'Credit',
          (r) => money(r.line?.credit ?? 0),
          numeric: true,
        ),
        ReportColumn('Balance', (r) => bal(r.balance), numeric: true),
      ],
      totals: [
        '',
        'Total',
        '',
        '${l.lines.length} ${l.lines.length == 1 ? 'entry' : 'entries'}',
        if (hasParty) '',
        formatMoney(l.totalDebit),
        formatMoney(l.totalCredit),
        bal(l.closingBalance),
      ],
      onTap: open == null
          ? null
          : (r) {
              final line = r.line;
              if (line != null) open(line);
            },
      cardBuilder: (context, r) {
        final line = r.line;
        if (line == null) {
          return ReportRowCard(
            title: r.label!,
            subtitle: formatDate(r.date),
            trailing: bal(r.balance),
            highlight: true,
          );
        }
        return ReportRowCard(
          title: '${line.voucherLabel} ${line.number ?? ''}'.trim(),
          subtitle: [
            formatDate(line.date),
            if (line.narration != null && line.narration!.isNotEmpty)
              line.narration!,
            if (line.partyName != null) line.partyName!,
          ].join(' · '),
          trailing: line.debit != 0
              ? 'Dr ${formatMoney(line.debit)}'
              : 'Cr ${formatMoney(line.credit)}',
          pairs: [('Balance', bal(line.balance))],
          onTap: open == null ? null : () => open(line),
        );
      },
      totalsCard: ReportRowCard(
        title: 'Period totals',
        trailing: '',
        highlight: true,
        pairs: [
          ('Debits', formatMoney(l.totalDebit)),
          ('Credits', formatMoney(l.totalCredit)),
        ],
      ),
    );
  }
}

/// CSV / PDF table for a ledger: opening, postings, closing; totals row.
ReportExport ledgerExport(Ledger l, {required String title, String? party}) {
  final range = (l.from != null && l.to != null)
      ? '${formatDate(l.from)} – ${formatDate(l.to)}'
      : null;
  String side(double b) => b.abs() < 0.005 ? '' : (b > 0 ? 'Dr' : 'Cr');
  return ReportExport(
    title: 'Ledger — $title',
    subtitle: [?range, if (party != null) 'Party: $party'].join(' · '),
    fileStem: 'Ledger-$title-${l.to ?? ''}',
    columns: const [
      ExportColumn('Date'),
      ExportColumn('Voucher'),
      ExportColumn('Number'),
      ExportColumn('Narration'),
      ExportColumn('Party'),
      ExportColumn('Debit', CellKind.money),
      ExportColumn('Credit', CellKind.money),
      ExportColumn('Balance', CellKind.money),
      ExportColumn('Dr/Cr'),
    ],
    rows: [
      [
        formatDate(l.from),
        'Opening balance',
        null,
        null,
        null,
        null,
        null,
        l.openingBalance.abs(),
        side(l.openingBalance),
      ],
      for (final line in l.lines)
        [
          formatDate(line.date),
          line.voucherLabel,
          line.number,
          line.narration,
          line.partyName,
          line.debit == 0 ? null : line.debit,
          line.credit == 0 ? null : line.credit,
          line.balance.abs(),
          side(line.balance),
        ],
      [
        formatDate(l.to),
        'Closing balance',
        null,
        null,
        null,
        null,
        null,
        l.closingBalance.abs(),
        side(l.closingBalance),
      ],
    ],
    totals: [
      null,
      'Total',
      null,
      null,
      null,
      l.totalDebit,
      l.totalCredit,
      null,
      null,
    ],
  );
}

/// Shown when the ledger cannot be found (bad link).
class LedgerNotFound extends StatelessWidget {
  const LedgerNotFound({super.key});

  @override
  Widget build(BuildContext context) => const EmptyView(
    icon: Icons.search_off,
    message: 'This account could not be found.',
  );
}
