import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/india_states.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../accounts/account_model.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import '../payments/payment_model.dart';
import '../payments/payments_repository.dart';
import 'parties_repository.dart';
import 'party_model.dart';

typedef StatementKey = ({String partyId, String? from, String? to});

final partyStatementProvider = FutureProvider.autoDispose
    .family<Ledger, StatementKey>((ref, key) {
      ref.watch(activeCompanyIdProvider);
      ref.watchRevisions(moneyKinds);
      return ref
          .watch(partiesRepositoryProvider)
          .statement(key.partyId, from: key.from, to: key.to);
    });

/// A customer or vendor: balance, open documents, statement and shortcuts.
class PartyDetailScreen extends ConsumerWidget {
  const PartyDetailScreen({super.key, required this.partyId});

  final String partyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return AsyncValueView(
      value: ref.watch(partyProvider(partyId)),
      onRetry: () => ref.invalidate(partyProvider(partyId)),
      data: (party) {
        final showOutstanding = perms.can(Perm.paymentsView);
        final showStatement =
            perms.can(Perm.partiesView) &&
            (perms.can(Perm.paymentsView) || perms.can(Perm.accountsView));
        String q(String path) => '$path?partyId=$partyId';
        final actions = [
          if (party.isCustomer && perms.can(Perm.invoicesCreate))
            DocAction(
              label: 'New invoice',
              icon: Icons.receipt_long_outlined,
              primary: true,
              onPressed: () => context.push(q('/invoices/new')),
            ),
          if (party.isCustomer && perms.can(Perm.paymentsCreate))
            DocAction(
              label: 'Record receipt',
              icon: Icons.call_received,
              onPressed: () => context.push(q('/receipts/new')),
            ),
          if (party.isVendor && perms.can(Perm.purchasesCreate))
            DocAction(
              label: 'New bill',
              icon: Icons.shopping_cart_outlined,
              primary: !party.isCustomer,
              onPressed: () => context.push(q('/purchases/new')),
            ),
          if (party.isVendor && perms.can(Perm.paymentsCreate))
            DocAction(
              label: 'Record payment',
              icon: Icons.call_made,
              onPressed: () => context.push(q('/payments/new')),
            ),
          if (perms.can(Perm.partiesEdit))
            DocAction(
              label: 'Edit',
              icon: Icons.edit_outlined,
              onPressed: () => context.push('/parties/$partyId/edit'),
            ),
        ];
        return FormPage(
          maxWidth: 1100,
          children: [
            DocHeader(
              title: party.name,
              pills: Pill(party.type.label),
              actions: actions,
              facts: [
                LabeledValue('GSTIN', party.gstin ?? ''),
                LabeledValue('State', stateLabel(party.stateCode)),
                LabeledValue('Phone', party.phone ?? ''),
                LabeledValue('Email', party.email ?? ''),
                LabeledValue('Credit limit', formatMoney(party.creditLimit)),
                LabeledValue('Credit days', '${party.creditDays}'),
                if ((party.pan ?? '').isNotEmpty)
                  LabeledValue('PAN', party.pan!),
                if ((party.udyamNo ?? '').isNotEmpty)
                  LabeledValue('Udyam number', party.udyamNo!),
                if (party.msmeCategory != null)
                  LabeledValue('MSME category', party.msmeCategory!),
                if (party.tdsSectionCode != null)
                  LabeledValue('TDS section', party.tdsSectionCode!),
              ],
            ),
            if (party.address != null && party.address!.isNotEmpty)
              SectionCard(title: 'Address', child: Text(party.address!)),
            _BalanceCard(party: party, showOutstanding: showOutstanding),
            if (showOutstanding) _OutstandingSection(party: party),
            if (showStatement) _StatementSection(partyId: partyId),
          ],
        );
      },
    );
  }
}

class _BalanceCard extends ConsumerWidget {
  const _BalanceCard({required this.party, required this.showOutstanding});

  final Party party;
  final bool showOutstanding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final outstanding = showOutstanding
        ? ref.watch(outstandingProvider(party.id)).value
        : null;
    final balance = outstanding?.balance ?? party.balance;
    if (balance == null) return const SizedBox.shrink();
    final (label, color) = balance > 0.004
        ? ('Receivable', theme.colorScheme.primary)
        : balance < -0.004
        ? ('Payable', theme.colorScheme.tertiary)
        : ('Settled', Colors.green);
    final caption = Row(
      children: [
        Icon(Icons.account_balance_wallet_outlined, color: color),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Balance', style: theme.textTheme.labelLarge),
              Text(
                balance > 0
                    ? 'They owe you'
                    : balance < 0
                    ? 'You owe them'
                    : 'Nothing outstanding',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
    final amount = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Text(
        '$label ${formatMoney(balance.abs())}',
        style: theme.textTheme.titleLarge?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    return SectionCard(
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth < 480
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [caption, const SizedBox(height: 8), amount],
              )
            : Row(
                children: [
                  Expanded(child: caption),
                  const SizedBox(width: 12),
                  Expanded(child: amount),
                ],
              ),
      ),
    );
  }
}

class _OutstandingSection extends ConsumerWidget {
  const _OutstandingSection({required this.party});

  final Party party;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final value = ref.watch(outstandingProvider(party.id));
    return SectionCard(
      title: 'Open documents',
      child: switch (value) {
        AsyncValue(:final error?, hasValue: false) => Row(
          children: [
            Expanded(child: Text(errorMessage(error))),
            TextButton(
              onPressed: () => ref.invalidate(outstandingProvider(party.id)),
              child: const Text('Retry'),
            ),
          ],
        ),
        AsyncValue(value: final o?) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (party.isCustomer || o.invoices.isNotEmpty)
              _DocList(
                title: 'Invoices',
                docs: o.invoices,
                route: perms.can(Perm.invoicesView)
                    ? (d) => '/invoices/${d.id}'
                    : null,
              ),
            if (party.isVendor || o.purchases.isNotEmpty)
              _DocList(
                title: 'Purchase bills',
                docs: o.purchases,
                route: perms.can(Perm.purchasesView)
                    ? (d) => '/purchases/${d.id}'
                    : null,
              ),
          ],
        ),
        _ => const LinearProgressIndicator(),
      },
    );
  }
}

class _DocList extends StatelessWidget {
  const _DocList({required this.title, required this.docs, this.route});

  final String title;
  final List<OpenDoc> docs;
  final String Function(OpenDoc)? route;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        if (docs.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Nothing open.'),
          ),
        for (final doc in docs)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(doc.number, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                formatDate(doc.date),
                if (doc.dueDate != null) 'due ${formatDate(doc.dueDate)}',
              ].join(' · '),
              style: doc.isOverdue(today)
                  ? TextStyle(color: theme.colorScheme.error)
                  : null,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatMoney(doc.amountDue),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  'of ${formatMoney(doc.total)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            onTap: route == null ? null : () => context.push(route!(doc)),
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _StatementSection extends ConsumerStatefulWidget {
  const _StatementSection({required this.partyId});

  final String partyId;

  @override
  ConsumerState<_StatementSection> createState() => _StatementSectionState();
}

class _StatementSectionState extends ConsumerState<_StatementSection> {
  DateTimeRange? _range;

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: _range,
    );
    if (picked != null) setState(() => _range = picked);
  }

  @override
  Widget build(BuildContext context) {
    final range = _range;
    final key = (
      partyId: widget.partyId,
      from: range == null ? null : apiDate(range.start),
      to: range == null ? null : apiDate(range.end),
    );
    final value = ref.watch(partyStatementProvider(key));
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Statement',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _pickRange,
                icon: const Icon(Icons.date_range_outlined),
                label: Text(
                  range == null
                      ? 'Financial year to date'
                      : '${formatDate(range.start)} – ${formatDate(range.end)}',
                ),
              ),
              if (range != null)
                TextButton(
                  onPressed: () => setState(() => _range = null),
                  child: const Text('Reset'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          switch (value) {
            AsyncValue(:final error?, hasValue: false) => Row(
              children: [
                Expanded(child: Text(errorMessage(error))),
                TextButton(
                  onPressed: () => ref.invalidate(partyStatementProvider(key)),
                  child: const Text('Retry'),
                ),
              ],
            ),
            AsyncValue(value: final ledger?) => _LedgerView(ledger: ledger),
            _ => const LinearProgressIndicator(),
          },
          if (value.isLoading && value.hasValue)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                minHeight: 2,
                color: theme.colorScheme.primary,
              ),
            ),
        ],
      ),
    );
  }
}

/// Opening balance, lines with the running balance, closing balance.
class _LedgerView extends StatelessWidget {
  const _LedgerView({required this.ledger});

  final Ledger ledger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bold = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    String bal(double b) => drCr(b, formatMoney);
    final header = Text(
      'Period ${formatDate(ledger.from)} – ${formatDate(ledger.to)}',
      style: theme.textTheme.bodySmall,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 860) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: DataTable(
                    showCheckboxColumn: false,
                    columnSpacing: 18,
                    horizontalMargin: 8,
                    columns: const [
                      DataColumn(label: Text('Date')),
                      DataColumn(label: Text('Voucher')),
                      DataColumn(label: Text('Number')),
                      DataColumn(label: Text('Narration')),
                      DataColumn(label: Text('Debit'), numeric: true),
                      DataColumn(label: Text('Credit'), numeric: true),
                      DataColumn(label: Text('Balance'), numeric: true),
                    ],
                    rows: [
                      DataRow(
                        cells: [
                          DataCell(Text(formatDate(ledger.from))),
                          DataCell(Text('Opening balance', style: bold)),
                          const DataCell(Text('')),
                          const DataCell(Text('')),
                          const DataCell(Text('')),
                          const DataCell(Text('')),
                          DataCell(
                            Text(bal(ledger.openingBalance), style: bold),
                          ),
                        ],
                      ),
                      for (final line in ledger.lines)
                        DataRow(
                          onSelectChanged: line.route == null
                              ? null
                              : (_) => context.push(line.route!),
                          cells: [
                            DataCell(Text(formatDate(line.date))),
                            DataCell(Text(line.voucherLabel)),
                            DataCell(Text(line.number ?? '—')),
                            DataCell(
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 220,
                                ),
                                child: Text(
                                  line.narration ?? '',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            DataCell(
                              Text(
                                line.debit == 0 ? '' : formatMoney(line.debit),
                              ),
                            ),
                            DataCell(
                              Text(
                                line.credit == 0
                                    ? ''
                                    : formatMoney(line.credit),
                              ),
                            ),
                            DataCell(Text(bal(line.balance))),
                          ],
                        ),
                      DataRow(
                        cells: [
                          DataCell(Text(formatDate(ledger.to))),
                          DataCell(Text('Closing balance', style: bold)),
                          const DataCell(Text('')),
                          const DataCell(Text('')),
                          DataCell(
                            Text(formatMoney(ledger.totalDebit), style: bold),
                          ),
                          DataCell(
                            Text(formatMoney(ledger.totalCredit), style: bold),
                          ),
                          DataCell(
                            Text(bal(ledger.closingBalance), style: bold),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            const SizedBox(height: 8),
            _SummaryRow('Opening balance', bal(ledger.openingBalance)),
            const Divider(),
            if (ledger.lines.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No transactions in this period.'),
              ),
            for (final line in ledger.lines)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${line.voucherLabel} ${line.number ?? ''}',
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    formatDate(line.date),
                    if (line.narration != null && line.narration!.isNotEmpty)
                      line.narration!,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      line.debit != 0
                          ? 'Dr ${formatMoney(line.debit)}'
                          : 'Cr ${formatMoney(line.credit)}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(bal(line.balance), style: theme.textTheme.bodySmall),
                  ],
                ),
                onTap: line.route == null
                    ? null
                    : () => context.push(line.route!),
              ),
            const Divider(),
            _SummaryRow('Closing balance', bal(ledger.closingBalance)),
          ],
        );
      },
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600);
    return Row(
      children: [
        Expanded(child: Text(label, style: style)),
        Text(value, style: style),
      ],
    );
  }
}
