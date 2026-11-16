import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/status_chip.dart';
import '../../widgets/states.dart';
import '../accounting/accounting_repository.dart';
import '../auth/session.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import '../reports/report_period.dart';
import '../reports/report_widgets.dart';
import 'cheque_pdf.dart';
import 'finance_models.dart';
import 'finance_repository.dart';

/// `/cheques`: due today, every cheque, and cheque books.
class ChequesScreen extends ConsumerWidget {
  const ChequesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = ref.watch(permissionsProvider).can(Perm.chequesManage);
    return DefaultTabController(
      length: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Cheques',
            subtitle: 'Post-dated cheques, deposits, bounces and cheque books',
            actions: [
              if (manage)
                FilledButton.icon(
                  onPressed: () => _record(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('Record cheque'),
                ),
            ],
          ),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [Tab(text: 'Due today'), Tab(text: 'All cheques'), Tab(text: 'Cheque books')],
          ),
          const Expanded(
            child: TabBarView(
              children: [
                _ChequeList(scope: 'due'),
                _ChequeList(scope: 'all'),
                _BooksTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _record(BuildContext context, WidgetRef ref) async {
  final body = await showFormDialog<Json>(context: context, builder: (c) => const _RecordDialog());
  if (body == null || !context.mounted) return;
  try {
    await ref.read(financeRepositoryProvider).recordCheque(body);
    ref.read(financeRevisionProvider.notifier).bump();
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
  }
}

class _ChequeList extends ConsumerWidget {
  const _ChequeList({required this.scope});
  final String scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(chequesProvider(scope));
    return ReportBody<List<Cheque>>(
      value: value,
      onRetry: () => ref.invalidate(chequesProvider(scope)),
      isEmpty: (l) => l.isEmpty,
      emptyMessage: scope == 'due' ? 'No cheques are due today.' : 'No cheques recorded yet.',
      emptyIcon: Icons.receipt_long_outlined,
      builder: (list) => [for (final c in list) ChequeTile(cheque: c)],
    );
  }
}

/// One cheque with the actions its status allows.
class ChequeTile extends ConsumerWidget {
  const ChequeTile({super.key, required this.cheque});
  final Cheque cheque;

  Future<void> _act(BuildContext context, WidgetRef ref, String action) async {
    final repo = ref.read(financeRepositoryProvider);
    try {
      switch (action) {
        case 'print':
          final data = await repo.chequePrint(cheque.id);
          final bytes = await buildChequePdf(data);
          await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'cheque-${cheque.chequeNo}.pdf');
          return;
        case 'bounce':
          final body = await showFormDialog<Json>(
            context: context,
            builder: (c) => _BounceDialog(cheque: cheque),
          );
          if (body == null) return;
          await repo.chequeAction(cheque.id, 'bounce', body);
        case 'cancel':
          final ok = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text('Cancel cheque ${cheque.chequeNo}?'),
              content: const Text('Use this for a cheque that was never presented.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cancel cheque')),
              ],
            ),
          );
          if (ok != true) return;
          await repo.chequeAction(cheque.id, 'cancel', {'reason': 'Cancelled by user'});
        default:
          await repo.chequeAction(cheque.id, action);
      }
      ref.read(financeRevisionProvider.notifier).bump();
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  static const _labels = {
    'deposit': 'Mark deposited',
    'clear': 'Mark cleared',
    'bounce': 'Mark bounced',
    'cancel': 'Cancel cheque',
    'print': 'Print cheque',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = ref.watch(permissionsProvider).can(Perm.chequesManage);
    final c = cheque;
    final actions = [
      if (manage) ...c.actions,
      if (!c.received && c.status != 'cancelled') 'print',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minTileHeight: 64,
      title: Text('${c.received ? 'From' : 'To'} ${c.partyName}'),
      subtitle: Text(
        'Cheque ${c.chequeNo} · ${formatDate(c.chequeDate)} · ${c.bankAccountName}'
        '${c.bounceReason == null ? '' : '\n${c.bounceReason}'}',
      ),
      isThreeLine: c.bounceReason != null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(formatMoney(c.amount), style: tabularFigures),
              StatusChip(c.status),
            ],
          ),
          if (actions.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: 'Actions',
              onSelected: (a) => _act(context, ref, a),
              itemBuilder: (_) => [
                for (final a in actions) PopupMenuItem(value: a, child: Text(_labels[a]!)),
              ],
            ),
        ],
      ),
    );
  }
}

class _RecordDialog extends ConsumerStatefulWidget {
  const _RecordDialog();

  @override
  ConsumerState<_RecordDialog> createState() => _RecordState();
}

class _RecordState extends ConsumerState<_RecordDialog> {
  String _direction = 'received';
  String? _bankId;
  Party? _party;
  DateTime _date = dateOnly(DateTime.now());
  final _no = TextEditingController();
  final _amount = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _no.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final banks = ref.watch(chartOfAccountsProvider).value
            ?.where((a) => a.subtype == 'bank' && a.isActive).toList() ??
        const [];
    return AlertDialog(
      title: const Text('Record cheque'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'received', label: Text('Received')),
                  ButtonSegment(value: 'issued', label: Text('Issued')),
                ],
                selected: {_direction},
                onSelectionChanged: (s) => setState(() {
                  _direction = s.first;
                  _party = null;
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _bankId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Bank account'),
                items: [for (final a in banks) DropdownMenuItem(value: a.id, child: Text(a.name))],
                onChanged: (v) => setState(() => _bankId = v),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () async {
                  final p = await pickParty(context, ref, type: _direction == 'received' ? PartyType.customer : PartyType.vendor);
                  if (p != null) setState(() => _party = p);
                },
                child: Text(_party?.name ?? (_direction == 'received' ? 'Choose the customer' : 'Choose the vendor')),
              ),
              const SizedBox(height: 12),
              TextField(controller: _no, decoration: const InputDecoration(labelText: 'Cheque number')),
              const SizedBox(height: 12),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.event_outlined),
                label: Text('Cheque date ${formatDate(_date)}'),
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                  );
                  if (d != null) setState(() => _date = dateOnly(d));
                },
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final amount = double.tryParse(_amount.text.trim());
            if (_bankId == null || _party == null || _no.text.trim().isEmpty || amount == null || amount <= 0) {
              setState(() => _error = 'Choose the bank account and party, and enter the number and amount.');
              return;
            }
            Navigator.pop(context, <String, dynamic>{
              'direction': _direction,
              'bankAccountId': _bankId,
              'partyId': _party!.id,
              'chequeNo': _no.text.trim(),
              'chequeDate': apiDate(_date),
              'amount': amount,
            });
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _BounceDialog extends StatefulWidget {
  const _BounceDialog({required this.cheque});
  final Cheque cheque;

  @override
  State<_BounceDialog> createState() => _BounceState();
}

class _BounceState extends State<_BounceDialog> {
  final _reason = TextEditingController();
  final _charges = TextEditingController();
  bool _recover = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    _charges.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cleared = widget.cheque.paymentId != null;
    return AlertDialog(
      title: Text('Bounce cheque ${widget.cheque.chequeNo}'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(cleared
                  ? 'The ${widget.cheque.received ? 'receipt' : 'payment'} for this cheque is cancelled and the party balance is restored.'
                  : 'This cheque was not cleared, so nothing is reversed.'),
              const SizedBox(height: 12),
              TextField(controller: _reason, decoration: const InputDecoration(labelText: 'Reason')),
              const SizedBox(height: 12),
              TextField(
                controller: _charges,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Bank charges (optional)'),
              ),
              if (widget.cheque.received)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _recover,
                  onChanged: (v) => setState(() => _recover = v ?? false),
                  title: const Text('Charge these to the customer with a debit note'),
                ),
              if (_error != null)
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_reason.text.trim().length < 3) {
              setState(() => _error = 'Give a reason.');
              return;
            }
            final charges = double.tryParse(_charges.text.trim()) ?? 0;
            Navigator.pop(context, <String, dynamic>{
              'reason': _reason.text.trim(),
              if (charges > 0) 'bankCharges': charges,
              if (charges > 0 && _recover) 'recoverFromParty': true,
            });
          },
          child: const Text('Mark bounced'),
        ),
      ],
    );
  }
}

class _BooksTab extends ConsumerWidget {
  const _BooksTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(chequeBooksProvider);
    final manage = ref.watch(permissionsProvider).can(Perm.chequesManage);
    return ReportBody<List<ChequeBook>>(
      value: value,
      onRetry: () => ref.invalidate(chequeBooksProvider),
      builder: (books) => [
        if (manage)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () async {
                final body = await showFormDialog<Json>(context: context, builder: (c) => const _BookDialog());
                if (body == null || !context.mounted) return;
                try {
                  await ref.read(financeRepositoryProvider).addBook(body);
                  ref.read(financeRevisionProvider.notifier).bump();
                } catch (e) {
                  if (context.mounted) showErrorSnackBar(context, e);
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('Add cheque book'),
            ),
          ),
        if (books.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('No cheque books yet.')),
        for (final b in books)
          ListTile(
            contentPadding: EdgeInsets.zero,
            minTileHeight: 64,
            title: Text('${b.accountName}: ${b.prefix}${b.fromNo} to ${b.prefix}${b.toNo}'),
            subtitle: Text('${b.used} of ${b.leaves} leaves used${b.isActive ? '' : ' · closed'}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showDialog<void>(context: context, builder: (c) => _RegisterDialog(book: b)),
          ),
      ],
    );
  }
}

class _RegisterDialog extends ConsumerWidget {
  const _RegisterDialog({required this.book});
  final ChequeBook book;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AlertDialog(
    title: Text('${book.accountName} register'),
    content: SizedBox(
      width: 380,
      height: 420,
      child: FutureBuilder<List<ChequeLeaf>>(
        future: ref.read(financeRepositoryProvider).register(book.id),
        builder: (context, snap) {
          if (snap.hasError) return ErrorView(error: snap.error!);
          final leaves = snap.data;
          if (leaves == null) return const Center(child: CircularProgressIndicator());
          return ListView(
            children: [
              for (final l in leaves)
                ListTile(
                  dense: true,
                  title: Text(l.no),
                  subtitle: l.payee == null ? null : Text(l.payee!),
                  trailing: Text(l.status == 'unused' ? 'Unused' : '${chequeStatusLabel(l.status == 'issued' ? 'held' : l.status)}${l.amount == null ? '' : ' ${formatMoney(l.amount)}'}'),
                ),
            ],
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () async {
          Navigator.pop(context);
          await showFormDialog<void>(context: context, builder: (c) => _LayoutDialog(accountId: book.accountId, accountName: book.accountName));
        },
        child: const Text('Print layout'),
      ),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
    ],
  );
}

class _BookDialog extends ConsumerStatefulWidget {
  const _BookDialog();

  @override
  ConsumerState<_BookDialog> createState() => _BookState();
}

class _BookState extends ConsumerState<_BookDialog> {
  String? _bank;
  final _from = TextEditingController();
  final _to = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final banks = ref.watch(chartOfAccountsProvider).value?.where((a) => a.subtype == 'bank').toList() ?? const [];
    return AlertDialog(
      title: const Text('Add cheque book'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _bank,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Bank account'),
            items: [for (final a in banks) DropdownMenuItem(value: a.id, child: Text(a.name))],
            onChanged: (v) => setState(() => _bank = v),
          ),
          const SizedBox(height: 8),
          TextField(controller: _from, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'First cheque number')),
          const SizedBox(height: 8),
          TextField(controller: _to, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Last cheque number', helperText: 'At most 500 leaves')),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final f = int.tryParse(_from.text.trim());
            final t = int.tryParse(_to.text.trim());
            if (_bank == null || f == null || t == null || t < f) {
              setState(() => _error = 'Choose a bank account and a valid number range.');
              return;
            }
            Navigator.pop(context, <String, dynamic>{'accountId': _bank, 'fromNo': f, 'toNo': t});
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Edits where each field prints, in millimetres, and previews a sample leaf.
class _LayoutDialog extends ConsumerStatefulWidget {
  const _LayoutDialog({required this.accountId, required this.accountName});
  final String accountId;
  final String accountName;

  @override
  ConsumerState<_LayoutDialog> createState() => _LayoutState();
}

class _LayoutState extends ConsumerState<_LayoutDialog> {
  ChequeLayout? _layout;
  final Map<String, TextEditingController> _c = {};

  @override
  void initState() {
    super.initState();
    ref.read(financeRepositoryProvider).layout(widget.accountId).then((l) {
      if (!mounted) return;
      setState(() {
        _layout = l;
        _c['widthMm'] = TextEditingController(text: formatPlain(l.widthMm));
        _c['heightMm'] = TextEditingController(text: formatPlain(l.heightMm));
        _c['dateGap'] = TextEditingController(text: formatPlain(l.dateGap));
        _c['maxWidth'] = TextEditingController(text: formatPlain(l.wordsMaxWidth));
        for (final f in chequeLayoutFields) {
          _c['${f}_x'] = TextEditingController(text: formatPlain(l.fields[f]!.$1));
          _c['${f}_y'] = TextEditingController(text: formatPlain(l.fields[f]!.$2));
        }
      });
    }).catchError((Object e) {
      if (mounted) showErrorSnackBar(context, e);
    });
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  double _n(String k) => double.tryParse(_c[k]!.text.trim()) ?? 0;

  ChequeLayout _build() => ChequeLayout(
    widthMm: _n('widthMm'),
    heightMm: _n('heightMm'),
    wordsMaxWidth: _n('maxWidth'),
    dateGap: _n('dateGap'),
    fields: {for (final f in chequeLayoutFields) f: (_n('${f}_x'), _n('${f}_y'))},
  );

  Widget _num(String k, String label) => Expanded(
    child: Padding(
      padding: const EdgeInsets.only(right: 8, top: 8),
      child: TextField(
        controller: _c[k],
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label),
      ),
    ),
  );

  Future<void> _save() async {
    try {
      await ref.read(financeRepositoryProvider).saveLayout(widget.accountId, _build());
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _sample() async {
    final bytes = await buildChequePdf(ChequePrint(
      layout: _build(),
      chequeNo: '000000',
      dateText: '15042026',
      payee: 'Sample payee',
      amount: 12345.5,
    ));
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'cheque-sample.pdf');
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Print layout: ${widget.accountName}'),
    content: SizedBox(
      width: 400,
      child: _layout == null
          ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('All positions are millimetres from the top left of the cheque leaf.'),
                  Row(children: [_num('widthMm', 'Width'), _num('heightMm', 'Height')]),
                  Row(children: [_num('dateGap', 'Gap between date digits'), _num('maxWidth', 'Words line width')]),
                  for (final f in chequeLayoutFields) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(chequeFieldLabels[f]!, style: Theme.of(context).textTheme.titleSmall),
                    ),
                    Row(children: [_num('${f}_x', 'From left'), _num('${f}_y', 'From top')]),
                  ],
                ],
              ),
            ),
    ),
    actions: [
      TextButton(onPressed: _layout == null ? null : _sample, child: const Text('Print sample')),
      TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
      FilledButton(onPressed: _layout == null ? null : _save, child: const Text('Save layout')),
    ],
  );
}
