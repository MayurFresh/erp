import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart' show CGate, showSuccess;
import 'funds_models.dart';
import 'funds_repository.dart';
import 'funds_widgets.dart';

const _typeLabels = {
  'expense': 'Expenses',
  'purchase': 'Purchase bills',
  'payment': 'Payments',
};

/// `/funds/spending`: link existing bills, expenses and payments to a head and fund.
class SpendingScreen extends ConsumerStatefulWidget {
  const SpendingScreen({super.key});

  @override
  ConsumerState<SpendingScreen> createState() => _SpendingScreenState();
}

class _SpendingScreenState extends ConsumerState<SpendingScreen> {
  String _type = 'expense';
  String _q = '';

  Future<void> _link(Spendable s) async {
    final warnings = await showFormDialog<List<String>>(
      context: context,
      builder: (_) => LinkDialog(doc: s),
    );
    if (warnings != null && mounted) {
      ref.bumpFunds();
      showSuccess(context, '${s.number} linked');
      showWarnings(context, warnings);
    }
  }

  Future<void> _unlink(SpendLink l) async {
    try {
      await ref.read(fundsRepositoryProvider).unlink(l.id);
      ref.bumpFunds();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = ref.watch(permissionsProvider).canAny(const [
      Perm.fundsEntry,
      Perm.fundsManage,
    ]);
    return CGate(
      anyOf: const [Perm.fundsView, Perm.fundsEntry, Perm.fundsManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Link spending'),
          Expanded(
            child: Gutter(
              children: [
                if (entry)
                  SectionCard(
                    title: 'Not yet linked',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SegmentedButton<String>(
                          showSelectedIcon: false,
                          segments: [
                            for (final e in _typeLabels.entries)
                              ButtonSegment(value: e.key, label: Text(e.value)),
                          ],
                          selected: {_type},
                          onSelectionChanged: (v) =>
                              setState(() => _type = v.first),
                        ),
                        const SizedBox(height: 10),
                        SearchField(
                          hintText: 'Number, name or description',
                          onChanged: (v) => setState(() => _q = v),
                        ),
                        const SizedBox(height: 6),
                        AsyncValueView<List<Spendable>>(
                          value: ref.watch(
                            spendableProvider((type: _type, q: _q)),
                          ),
                          onRetry: () => ref.invalidate(spendableProvider),
                          data: (list) => list.isEmpty
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Text('Everything here is linked.'),
                                )
                              : Column(
                                  children: [
                                    for (final s in list)
                                      ListTile(
                                        key: ValueKey('spend-${s.id}'),
                                        contentPadding: EdgeInsets.zero,
                                        onTap: () => _link(s),
                                        title: Text(
                                          '${s.number}  ${s.who}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: Text(
                                          '${formatDate(s.date)}${s.what.isEmpty ? '' : '  |  ${s.what}'}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        trailing: Text(
                                          formatAmount(s.remaining),
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
                                        ),
                                      ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                SectionCard(
                  title: 'Linked spending',
                  child: ref
                      .watch(spendLinksProvider)
                      .when(
                        loading: () => const LoadingView(),
                        error: (e, _) => ErrorView(
                          error: e,
                          onRetry: () => ref.invalidate(spendLinksProvider),
                        ),
                        data: (list) => list.isEmpty
                            ? const Text('Nothing is linked yet.')
                            : Column(
                                children: [
                                  for (final l in list)
                                    ListTile(
                                      key: ValueKey('link-${l.id}'),
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(
                                        '${l.number}  |  ${formatAmount(l.amount)}',
                                      ),
                                      subtitle: Text(
                                        '${l.headLabel}\n${l.fundName}',
                                      ),
                                      isThreeLine: true,
                                      trailing: entry
                                          ? IconButton(
                                              tooltip: 'Remove link',
                                              onPressed: () => _unlink(l),
                                              icon: const Icon(Icons.link_off),
                                            )
                                          : null,
                                    ),
                                ],
                              ),
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class LinkDialog extends ConsumerStatefulWidget {
  const LinkDialog({super.key, required this.doc});

  final Spendable doc;

  @override
  ConsumerState<LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends ConsumerState<LinkDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  String? _head;
  String? _fund;
  String? _sanction;
  late final _amount = TextEditingController(
    text: formatPlain(widget.doc.remaining),
  );
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      final r = await ref.read(fundsRepositoryProvider).link({
        'sourceType': widget.doc.type,
        'sourceId': widget.doc.id,
        'headId': _head,
        'fundId': _fund,
        'sanctionId': _sanction,
        'amount': parseNumber(_amount.text),
      });
      if (mounted) Navigator.of(context).pop(warningsOf(r));
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final heads =
        ref.watch(headsProvider(null)).value?.leaves ?? const <HeadRow>[];
    final funds = (ref.watch(fundsListProvider).value ?? const <FundRow>[])
        .where((f) => f.status == 'active')
        .toList();
    final sanctions =
        (ref.watch(sanctionsProvider('approved')).value ?? const <Sanction>[])
            .where(
              (s) => s.headId == _head && s.fundId == _fund && s.committed > 0,
            )
            .toList();
    return AlertDialog(
      title: Text('Link ${widget.doc.number}'),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${widget.doc.who}. Not yet linked: ${formatAmount(widget.doc.remaining)}',
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const ValueKey('link-head'),
                  initialValue: _head,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Budget head',
                    errorText: serverError('headId'),
                  ),
                  items: [
                    for (final h in heads)
                      DropdownMenuItem(
                        value: h.id,
                        child: Text(
                          '${h.label}  (available ${formatAmount(h.available)})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  validator: (v) => v == null ? 'Choose a head' : null,
                  onChanged: (v) => setState(() {
                    _head = v;
                    _sanction = null;
                  }),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const ValueKey('link-fund'),
                  initialValue: _fund,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Fund or scheme',
                    errorText: serverError('fundId'),
                  ),
                  items: [
                    for (final f in funds)
                      DropdownMenuItem(
                        value: f.id,
                        child: Text(f.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  validator: (v) => v == null ? 'Choose a fund' : null,
                  onChanged: (v) => setState(() {
                    _fund = v;
                    _sanction = null;
                  }),
                ),
                if (sanctions.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    key: ValueKey('link-sanction-${sanctions.length}'),
                    initialValue: _sanction,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Against sanction (optional)',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('None'),
                      ),
                      for (final s in sanctions)
                        DropdownMenuItem<String?>(
                          value: s.id,
                          child: Text(
                            '${s.number}  (left ${formatAmount(s.committed)})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _sanction = v),
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _amount,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  decoration: InputDecoration(
                    labelText: 'Amount to link',
                    errorText: serverError('amount'),
                  ),
                  validator: (v) => (parseNumber(v ?? '') ?? 0) <= 0
                      ? 'Enter an amount'
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        BusyButton(
          busy: _saving,
          onPressed: _saving ? null : _save,
          label: 'Link',
        ),
      ],
    );
  }
}
