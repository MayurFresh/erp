import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/whatsapp.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../accounts/account_model.dart' show drCr;
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import '../parties/parties_repository.dart';
import '../parties/statement_pdf.dart';
import '../reports/pdf_actions.dart';
import 'receivables_models.dart';
import 'receivables_repository.dart';
import 'receivables_widgets.dart';

/// `/parties/:id/statement`: dated rows, open bills, ageing and optional
/// interest, with PDF and WhatsApp share.
class StatementScreen extends ConsumerStatefulWidget {
  const StatementScreen({super.key, required this.partyId});

  final String partyId;

  @override
  ConsumerState<StatementScreen> createState() => _StatementScreenState();
}

class _StatementScreenState extends ConsumerState<StatementScreen> {
  late DateTime _from = fyStartOf(DateTime.now());
  late DateTime _to = DateTime.now();

  PartyStatementKey get _key => (
    partyId: widget.partyId,
    from: apiDate(_from),
    to: apiDate(_to),
  );

  String _whatsAppText(PartyStatement s, String company) {
    final b = StringBuffer()
      ..writeln('Statement of account from $company')
      ..writeln('${formatDate(apiDate(_from))} to ${formatDate(apiDate(_to))}')
      ..writeln('Closing balance: ${drCr(s.ledger.closingBalance, formatMoney)}');
    if (s.ageing.overdue > 0) {
      b.writeln('Overdue: ${formatMoney(s.ageing.overdue)}');
    }
    if (s.showInterest && s.interestTotal > 0) {
      b.writeln('Interest at ${s.interestPct}% a year on overdue bills: ${formatMoney(s.interestTotal)}');
    }
    b.write('Please pay the overdue amount. Thank you.');
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(partyStatementFullProvider(_key));
    final party = ref.watch(partyProvider(widget.partyId)).value;
    final companyName =
        ref.watch(sessionProvider).value?.company?.name ?? 'OneMatrix';
    return RGate(
      anyOf: const [Perm.partiesView],
      child: AsyncValueView<PartyStatement>(
        value: value,
        onRetry: () => ref.invalidate(partyStatementFullProvider(_key)),
        data: (s) {
          final actions = [
            if (party != null)
              ...pdfDocActions(
                context,
                ref,
                fileName: statementFileName(party),
                build: (p) async => buildStatementPdf(
                  party,
                  s.ledger,
                  p.company,
                  brand: p.brand,
                  theme: p.theme,
                  extraDetails: _pdfDetails(s),
                ),
              ),
            DocAction(
              label: 'Send on WhatsApp',
              icon: Icons.chat_outlined,
              primary: true,
              onPressed: () async {
                final ok = await openWhatsApp(
                  whatsAppUri(
                    phone: s.partyPhone,
                    text: _whatsAppText(s, companyName),
                  ),
                );
                if (!ok && context.mounted) {
                  showInfoSnackBar(context, 'WhatsApp could not be opened');
                }
              },
            ),
          ];
          return FormPage(
            maxWidth: 1100,
            children: [
              DocHeader(
                title: 'Statement: ${s.partyName}',
                pills: Pill(drCr(s.ledger.closingBalance, formatMoney)),
                actions: actions,
                facts: [
                  LabeledValue('Opening', drCr(s.ledger.openingBalance, formatMoney)),
                  LabeledValue('Closing', drCr(s.ledger.closingBalance, formatMoney)),
                  LabeledValue('Overdue', formatMoney(s.ageing.overdue)),
                  if (s.showInterest)
                    LabeledValue('Interest (not posted)', formatMoney(s.interestTotal)),
                ],
              ),
              SectionCard(
                title: 'Period',
                child: FormRow(
                  children: [
                    RDateField(
                      label: 'From',
                      value: _from,
                      onChanged: (d) => setState(() => _from = d ?? _from),
                    ),
                    RDateField(
                      label: 'To',
                      value: _to,
                      lastDate: DateTime.now(),
                      onChanged: (d) => setState(() => _to = d ?? _to),
                    ),
                  ],
                ),
              ),
              _AgeingCard(s: s),
              if (s.openBills.isNotEmpty) _OpenBills(s: s),
              _Rows(s: s),
            ],
          );
        },
      ),
    );
  }

  List<(String, String)> _pdfDetails(PartyStatement s) => [
    for (final (label, amount) in s.ageing.buckets)
      ('Ageing: $label', formatMoney(amount)),
    if (s.showInterest)
      ('Interest at ${s.interestPct}% a year', formatMoney(s.interestTotal)),
  ];
}

class _AgeingCard extends StatelessWidget {
  const _AgeingCard({required this.s});

  final PartyStatement s;

  @override
  Widget build(BuildContext context) => SectionCard(
    title: s.ageing.basis == 'payable' ? 'Ageing of what you owe' : 'Ageing of what they owe',
    child: Wrap(
      spacing: Space.lg,
      runSpacing: Space.sm,
      children: [
        for (final (label, amount) in s.ageing.buckets)
          SizedBox(
            width: 140,
            child: LabeledValue(label, formatMoney(amount)),
          ),
        SizedBox(
          width: 140,
          child: LabeledValue('Total open', formatMoney(s.ageing.total)),
        ),
      ],
    ),
  );
}

class _OpenBills extends StatelessWidget {
  const _OpenBills({required this.s});

  final PartyStatement s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Open bills',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final b in s.openBills)
            Padding(
              key: ValueKey('bill-${b.id}'),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(b.number, style: theme.textTheme.titleSmall),
                        Text(
                          b.daysOverdue > 0
                              ? 'Due ${formatDate(b.dueDate)}, ${b.daysOverdue} days overdue'
                              : 'Due ${formatDate(b.dueDate)}',
                          style: theme.textTheme.bodySmall,
                        ),
                        if (b.interestDue != null && b.interestDue! > 0)
                          Text(
                            'Interest ${formatMoney(b.interestDue)}',
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  Text(formatMoney(b.amountDue)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Rows extends StatelessWidget {
  const _Rows({required this.s});

  final PartyStatement s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bold = theme.textTheme.titleSmall;
    Widget amounts(StatementRow r) => Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (r.debit != 0) Text('Debit ${formatMoney(r.debit)}'),
        if (r.credit != 0) Text('Credit ${formatMoney(r.credit)}'),
        Text(drCr(r.balance, formatMoney), style: bold),
      ],
    );
    return SectionCard(
      title: 'Transactions',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _line(context, 'Opening balance', null, Text(drCr(s.ledger.openingBalance, formatMoney), style: bold)),
          if (s.rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No transactions in this period.'),
            ),
          for (final r in s.rows)
            _line(
              context,
              '${statementTypeLabel(r.type)}${r.number == null ? '' : ' ${r.number}'}',
              [formatDate(r.date), if (r.dueDate != null) 'due ${formatDate(r.dueDate)}'].join(', '),
              amounts(r),
            ),
          _line(context, 'Closing balance', null, Text(drCr(s.ledger.closingBalance, formatMoney), style: bold)),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, String title, String? sub, Widget trailing) => Container(
    padding: const EdgeInsets.symmetric(vertical: 8),
    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              if (sub != null) Text(sub, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        trailing,
      ],
    ),
  );
}
