import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../compliance/compliance_repository.dart' show AccountOption;
import '../compliance/compliance_widgets.dart' show pickAccount;
import '../compliance/tax_perms.dart';
import '../income_tax/it_widgets.dart';
import '../reports/report_widgets.dart' show tabularFigures;
import 'fa_models.dart';
import 'fa_repository.dart';

/// `/fixed-assets/:id`: one asset with its history; edit and dispose here.
class FixedAssetDetailScreen extends ConsumerWidget {
  const FixedAssetDetailScreen({super.key, required this.id});

  final String id;

  Future<void> _dispose(
    BuildContext context,
    WidgetRef ref,
    FixedAsset a,
  ) async {
    final done = await showDialog<FixedAsset>(
      context: context,
      builder: (_) => DisposeAssetDialog(asset: a),
    );
    if (done == null || !context.mounted) return;
    ref.read(faRevisionProvider.notifier).bump();
    ref.bump(const [DataKind.accounts]);
    showInfoSnackBar(context, '${a.name} disposed');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = ref.watch(permissionsProvider).can(TaxPerm.assetsManage);
    return AsyncValueView<FixedAsset>(
      value: ref.watch(fixedAssetProvider(id)),
      onRetry: () => ref.invalidate(fixedAssetProvider(id)),
      data: (a) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: a.name,
            subtitle: '${a.number} · ${a.blockName}',
            actions: [
              OutlinedButton(
                onPressed: () => context.go('/fixed-assets'),
                child: const Text('Back'),
              ),
              if (manage && !a.disposed) ...[
                OutlinedButton.icon(
                  onPressed: () => context.go('/fixed-assets/${a.id}/edit'),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit'),
                ),
                FilledButton.icon(
                  onPressed: () => _dispose(context, ref, a),
                  icon: const Icon(Icons.sell_outlined),
                  label: const Text('Dispose'),
                ),
              ],
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                if (a.disposed && a.disposal != null)
                  SectionCard(
                    title: 'Disposed on ${formatDate(a.disposal!.date)}',
                    child: Wrap(
                      spacing: 32,
                      runSpacing: 12,
                      children: [
                        LabeledValue(
                          'Sale value',
                          formatMoney(a.disposal!.saleValue),
                        ),
                        LabeledValue(
                          a.disposal!.gainLoss >= 0 ? 'Gain' : 'Loss',
                          formatMoney(a.disposal!.gainLoss.abs()),
                        ),
                      ],
                    ),
                  ),
                SectionCard(
                  title: 'Values',
                  child: Wrap(
                    spacing: 32,
                    runSpacing: 12,
                    children: [
                      LabeledValue('Cost', formatMoney(a.cost)),
                      LabeledValue('GST credit', formatMoney(a.gstItc)),
                      LabeledValue(
                        'Opening acc. dep.',
                        formatMoney(a.openingAccDep),
                      ),
                      LabeledValue(
                        'Accumulated dep.',
                        formatMoney(a.accumulatedDep),
                      ),
                      LabeledValue('Book value', formatMoney(a.bookValue)),
                      LabeledValue(
                        'Depreciated until',
                        a.depreciatedUntil == null
                            ? 'Not yet'
                            : formatDate(a.depreciatedUntil),
                      ),
                    ],
                  ),
                ),
                SectionCard(
                  title: 'Details',
                  child: Wrap(
                    spacing: 32,
                    runSpacing: 12,
                    children: [
                      LabeledValue('Method', a.methodLabel),
                      LabeledValue('Useful life', '${a.usefulLifeYears} years'),
                      LabeledValue('Residual', formatPercent(a.residualPct)),
                      LabeledValue('Purchased', formatDate(a.purchaseDate)),
                      LabeledValue('Put to use', formatDate(a.putToUseDate)),
                      if (a.locationName.isNotEmpty)
                        LabeledValue('Location', a.locationName),
                      if (a.supplierName.isNotEmpty)
                        LabeledValue('Supplier', a.supplierName),
                      if (a.billNo.isNotEmpty) LabeledValue('Bill', a.billNo),
                      if (a.serialNo.isNotEmpty)
                        LabeledValue('Serial', a.serialNo),
                      if (a.tagNo.isNotEmpty) LabeledValue('Tag', a.tagNo),
                      if (a.custodian.isNotEmpty)
                        LabeledValue('Custodian', a.custodian),
                      if (a.notes.isNotEmpty) LabeledValue('Notes', a.notes),
                    ],
                  ),
                ),
                SectionCard(
                  title: 'History',
                  child: a.history.isEmpty
                      ? const Text('No entries yet.')
                      : Column(
                          children: [
                            for (final h in a.history)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(_kind(h.kind)),
                                subtitle: Text(formatDate(h.date)),
                                trailing: Text(
                                  formatMoney(h.amount),
                                  style: tabularFigures,
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _kind(String k) => switch (k) {
    'capitalise' || 'asset_capitalise' => 'Capitalised',
    'depreciation' => 'Depreciation',
    'disposal' || 'asset_disposal' => 'Disposed',
    _ =>
      k.isEmpty ? '' : k[0].toUpperCase() + k.substring(1).replaceAll('_', ' '),
  };
}

/// Dispose of an asset: date, sale value and, when sold, where the money
/// went. Pops the updated [FixedAsset].
class DisposeAssetDialog extends ConsumerStatefulWidget {
  const DisposeAssetDialog({super.key, required this.asset});

  final FixedAsset asset;

  @override
  ConsumerState<DisposeAssetDialog> createState() => _DisposeAssetDialogState();
}

class _DisposeAssetDialogState extends ConsumerState<DisposeAssetDialog> {
  final _form = GlobalKey<FormState>();
  final _sale = TextEditingController(text: '0');
  final _notes = TextEditingController();
  DateTime _date = DateTime.now();
  AccountOption? _account;
  String? _accountError;

  @override
  void dispose() {
    _sale.dispose();
    _notes.dispose();
    super.dispose();
  }

  double get _saleValue => parseIndianNumber(_sale.text) ?? 0;

  DateTime get _first =>
      DateTime.tryParse(widget.asset.putToUseDate) ?? DateTime(2017);

  Future<void> _submit() async {
    final ok = _form.currentState!.validate();
    final needAccount = _saleValue > 0 && _account == null;
    setState(() => _accountError = needAccount ? 'Choose the account' : null);
    if (!ok || needAccount) return;
    try {
      final a = await ref
          .read(fixedAssetRepositoryProvider)
          .dispose(widget.asset.id, {
            'date': apiDate(_date),
            'saleValue': _saleValue,
            if (_saleValue > 0) 'receivedInAccountId': _account!.id,
            if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
          });
      if (mounted) Navigator.pop(context, a);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Dispose ${widget.asset.name}'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Book value ${formatMoney(widget.asset.bookValue)}. '
                'Depreciation is charged up to the disposal date first.',
              ),
              const SizedBox(height: 12),
              DateButton(
                label: 'Disposal date',
                value: _date,
                first: _first,
                last: DateTime.now().add(const Duration(days: 365)),
                onChanged: (d) => setState(() => _date = d),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _sale,
                keyboardType: decimalKeyboard,
                inputFormatters: [moneyInput()],
                decoration: const InputDecoration(
                  labelText: 'Sale value',
                  prefixText: '₹ ',
                  helperText: '0 for scrap',
                ),
                validator: (v) => validateMoney(v, label: 'Sale value', min: 0),
                onChanged: (_) => setState(() {}),
              ),
              if (_saleValue > 0) ...[
                const SizedBox(height: 12),
                PickerField(
                  label: 'Received in',
                  value: _account?.label,
                  errorText: _accountError,
                  onTap: () async {
                    final a = await pickAccount(
                      context,
                      ref,
                      title: 'Received in',
                      where: (a) =>
                          a.subtype != 'fixed_asset' &&
                          a.subtype != 'accumulated_depreciation',
                    );
                    if (a != null) {
                      setState(() {
                        _account = a;
                        _accountError = null;
                      });
                    }
                  },
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _notes,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                ),
                validator: validateNotes,
              ),
              const SizedBox(height: 12),
              Text(
                'GST on the sale is not posted here. Raise a sales invoice '
                'for the buyer to account for it.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      BusyButton(onPressed: _submit, label: 'Dispose'),
    ],
  );
}
