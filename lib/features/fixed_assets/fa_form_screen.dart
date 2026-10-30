import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart' show withoutNulls;
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../compliance/compliance_repository.dart' show AccountOption;
import '../compliance/compliance_widgets.dart' show pickAccount;
import '../income_tax/it_widgets.dart';
import '../locations/locations_repository.dart';
import 'fa_models.dart';
import 'fa_repository.dart';

/// `/fixed-assets/new` and `/fixed-assets/:id/edit`.
class FixedAssetFormScreen extends ConsumerWidget {
  const FixedAssetFormScreen({super.key, this.id});

  final String? id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (id == null) return const AssetForm();
    return AsyncValueView<FixedAsset>(
      value: ref.watch(fixedAssetProvider(id!)),
      onRetry: () => ref.invalidate(fixedAssetProvider(id!)),
      data: (a) => AssetForm(asset: a),
    );
  }
}

class AssetForm extends ConsumerStatefulWidget {
  const AssetForm({super.key, this.asset});

  final FixedAsset? asset;

  @override
  ConsumerState<AssetForm> createState() => _AssetFormState();
}

class _AssetFormState extends ConsumerState<AssetForm>
    with ServerFieldErrors, DirtyTracking<AssetForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.asset?.name);
  late final _life = TextEditingController(
    text: '${widget.asset?.usefulLifeYears ?? ''}',
  );
  late final _residual = TextEditingController(
    text: widget.asset == null ? '5' : formatPlain(widget.asset!.residualPct),
  );
  final _cost = TextEditingController();
  final _gstItc = TextEditingController();
  final _openingDep = TextEditingController();
  late final _supplier = TextEditingController(
    text: widget.asset?.supplierName,
  );
  late final _billNo = TextEditingController(text: widget.asset?.billNo);
  late final _serial = TextEditingController(text: widget.asset?.serialNo);
  late final _tag = TextEditingController(text: widget.asset?.tagNo);
  late final _custodian = TextEditingController(text: widget.asset?.custodian);
  late final _notes = TextEditingController(text: widget.asset?.notes);
  String? _blockCode;
  String _method = 'slm';
  DateTime? _purchase;
  DateTime? _putToUse;
  AccountOption? _source;
  late String? _locationId = widget.asset?.locationId;
  String? _blockError;
  String? _sourceError;
  String? _purchaseError;
  String? _useError;

  bool get _editing => widget.asset != null;

  @override
  void dispose() {
    for (final c in [
      _name, _life, _residual, _cost, _gstItc, _openingDep, _supplier,
      _billNo, _serial, _tag, _custodian, _notes, //
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool _validateExtras() {
    if (_editing) return true;
    setState(() {
      _blockError = _blockCode == null ? 'Choose the block' : null;
      _sourceError = _source == null ? 'Choose the account' : null;
      _purchaseError = _purchase == null ? 'Choose the purchase date' : null;
      _useError = _putToUse == null
          ? 'Choose the date put to use'
          : (_purchase != null && _putToUse!.isBefore(_purchase!))
          ? 'Cannot be before the purchase date'
          : null;
    });
    return _blockError == null &&
        _sourceError == null &&
        _purchaseError == null &&
        _useError == null;
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    final ok = _form.currentState!.validate();
    if (!_validateExtras() || !ok) return;
    final repo = ref.read(fixedAssetRepositoryProvider);
    try {
      FixedAsset saved;
      if (_editing) {
        saved = await repo.update(widget.asset!.id, {
          'name': _name.text.trim(),
          'locationId': _locationId,
          'serialNo': _serial.text.trim(),
          'tagNo': _tag.text.trim(),
          'custodian': _custodian.text.trim(),
          'notes': _notes.text.trim(),
          'usefulLifeYears': int.parse(_life.text.trim()),
          'residualPct': parseIndianNumber(_residual.text) ?? 0,
        });
      } else {
        String? opt(TextEditingController c) => trimmedOrNull(c.text);
        saved = await repo.create(
          withoutNulls({
            'name': _name.text.trim(),
            'blockCode': _blockCode,
            'bookMethod': _method,
            'usefulLifeYears': int.parse(_life.text.trim()),
            'residualPct': parseIndianNumber(_residual.text) ?? 5,
            'cost': parseIndianNumber(_cost.text),
            'gstItc': parseIndianNumber(_gstItc.text),
            'purchaseDate': apiDate(_purchase!),
            'putToUseDate': apiDate(_putToUse!),
            'sourceAccountId': _source!.id,
            'openingAccDep': parseIndianNumber(_openingDep.text),
            'locationId': _locationId,
            'supplierName': opt(_supplier),
            'billNo': opt(_billNo),
            'serialNo': opt(_serial),
            'tagNo': opt(_tag),
            'custodian': opt(_custodian),
            'notes': opt(_notes),
          }),
        );
      }
      markSaved();
      ref.read(faRevisionProvider.notifier).bump();
      ref.bump(const [DataKind.accounts]);
      if (mounted) context.go('/fixed-assets/${saved.id}');
    } catch (e) {
      if (mounted) showSubmitError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocks = ref.watch(itBlocksProvider).value ?? const <ItBlock>[];
    final locations = ref.watch(locationsLookupProvider).value ?? const [];
    final disposed = widget.asset?.disposed ?? false;
    return track(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: _editing ? 'Edit ${widget.asset!.name}' : 'Add fixed asset',
            subtitle: _editing
                ? widget.asset!.number
                : 'Capitalised on the date it is put to use',
            actions: [
              OutlinedButton(
                onPressed: () => leave(
                  _editing
                      ? '/fixed-assets/${widget.asset!.id}'
                      : '/fixed-assets',
                ),
                child: const Text('Back'),
              ),
              if (!disposed)
                BusyButton(
                  onPressed: _save,
                  label: 'Save',
                  icon: Icons.save_outlined,
                ),
            ],
          ),
          Expanded(
            child: Form(
              key: _form,
              onChanged: markDirty,
              child: FormPage(
                children: [
                  if (disposed)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'This asset is disposed and cannot be edited.',
                      ),
                    ),
                  TextFormField(
                    controller: _name,
                    enabled: !disposed,
                    decoration: InputDecoration(
                      labelText: 'Name',
                      errorText: serverError('name'),
                    ),
                    validator: validateName,
                  ),
                  const SizedBox(height: 12),
                  if (!_editing) ...[
                    DropdownButtonFormField<String>(
                      initialValue: _blockCode,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Income-tax block',
                        errorText: _blockError ?? serverError('blockCode'),
                      ),
                      items: [
                        for (final b in blocks)
                          DropdownMenuItem(
                            value: b.code,
                            child: Text(
                              '${b.name} (${formatPercent(b.rate)})',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() {
                        _blockCode = v;
                        _blockError = null;
                        markDirty();
                      }),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Book depreciation method',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'slm',
                          label: Text('Straight line'),
                        ),
                        ButtonSegment(
                          value: 'wdv',
                          label: Text('Written down'),
                        ),
                      ],
                      selected: {_method},
                      onSelectionChanged: (s) => setState(() {
                        _method = s.first;
                        markDirty();
                      }),
                    ),
                    const SizedBox(height: 12),
                  ],
                  FormRow(
                    children: [
                      TextFormField(
                        controller: _life,
                        enabled: !disposed,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Useful life (years)',
                          errorText: serverError('usefulLifeYears'),
                        ),
                        validator: (v) {
                          final n = int.tryParse((v ?? '').trim());
                          if (n == null) return 'Enter whole years';
                          return n < 1 || n > 100 ? 'Between 1 and 100' : null;
                        },
                      ),
                      TextFormField(
                        controller: _residual,
                        enabled: !disposed,
                        keyboardType: decimalKeyboard,
                        inputFormatters: [percentInput()],
                        decoration: InputDecoration(
                          labelText: 'Residual value (%)',
                          helperText: 'Usually 5',
                          errorText: serverError('residualPct'),
                        ),
                        validator: (v) =>
                            validatePercent(v, label: 'Residual value'),
                      ),
                    ],
                  ),
                  if (!_editing) ...[
                    const SizedBox(height: 12),
                    FormRow(
                      children: [
                        TextFormField(
                          controller: _cost,
                          keyboardType: decimalKeyboard,
                          inputFormatters: [moneyInput()],
                          decoration: InputDecoration(
                            labelText: 'Cost (excluding GST claimed)',
                            prefixText: '₹ ',
                            errorText: serverError('cost'),
                          ),
                          validator: (v) =>
                              validateMoney(v, label: 'Cost', min: 0.01),
                        ),
                        TextFormField(
                          controller: _gstItc,
                          keyboardType: decimalKeyboard,
                          inputFormatters: [moneyInput()],
                          decoration: const InputDecoration(
                            labelText: 'GST input credit (optional)',
                            prefixText: '₹ ',
                          ),
                          validator: (v) => validateMoney(
                            v,
                            isRequired: false,
                            label: 'GST credit',
                            min: 0,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    FormRow(
                      children: [
                        DateButton(
                          label: 'Purchase date',
                          value: _purchase,
                          first: kMinDocDate,
                          last: maxDocDate(),
                          errorText: _purchaseError,
                          onChanged: (d) => setState(() {
                            _purchase = d;
                            _purchaseError = null;
                            _putToUse ??= d;
                            markDirty();
                          }),
                        ),
                        DateButton(
                          label: 'Put to use',
                          value: _putToUse,
                          first: _purchase ?? kMinDocDate,
                          last: maxDocDate(),
                          errorText: _useError,
                          onChanged: (d) => setState(() {
                            _putToUse = d;
                            _useError = null;
                            markDirty();
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    PickerField(
                      label: 'Paid from / source account',
                      value: _source?.label,
                      errorText: _sourceError ?? serverError('sourceAccountId'),
                      onTap: () async {
                        final a = await pickAccount(
                          context,
                          ref,
                          title: 'Source account',
                          where: (a) => a.subtype != 'fixed_asset',
                        );
                        if (a != null) {
                          setState(() {
                            _source = a;
                            _sourceError = null;
                            markDirty();
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Bank, cash, payables, an expense account, or Opening '
                      'Balances for an asset you already own.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _openingDep,
                      keyboardType: decimalKeyboard,
                      inputFormatters: [moneyInput()],
                      decoration: const InputDecoration(
                        labelText:
                            'Opening accumulated depreciation (optional)',
                        prefixText: '₹ ',
                        helperText: 'For an asset you already owned',
                        helperMaxLines: 2,
                      ),
                      validator: (v) => validateMoney(
                        v,
                        isRequired: false,
                        label: 'Opening depreciation',
                        min: 0,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: locations.any((l) => l.id == _locationId)
                        ? _locationId
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Location'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('None')),
                      for (final l in locations)
                        DropdownMenuItem(value: l.id, child: Text(l.name)),
                    ],
                    onChanged: disposed
                        ? null
                        : (v) => setState(() {
                            _locationId = v;
                            markDirty();
                          }),
                  ),
                  if (!_editing) ...[
                    const SizedBox(height: 12),
                    FormRow(
                      children: [
                        TextFormField(
                          controller: _supplier,
                          decoration: const InputDecoration(
                            labelText: 'Supplier',
                          ),
                          validator: (v) => maxLength(v, 200, 'Supplier'),
                        ),
                        TextFormField(
                          controller: _billNo,
                          decoration: const InputDecoration(
                            labelText: 'Bill number',
                          ),
                          validator: (v) => maxLength(v, 100, 'Bill number'),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  FormRow(
                    children: [
                      TextFormField(
                        controller: _serial,
                        enabled: !disposed,
                        decoration: const InputDecoration(
                          labelText: 'Serial number',
                        ),
                        validator: (v) => maxLength(v, 100, 'Serial number'),
                      ),
                      TextFormField(
                        controller: _tag,
                        enabled: !disposed,
                        decoration: const InputDecoration(
                          labelText: 'Tag number',
                        ),
                        validator: (v) => maxLength(v, 100, 'Tag number'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _custodian,
                    enabled: !disposed,
                    decoration: const InputDecoration(labelText: 'Custodian'),
                    validator: (v) => maxLength(v, 200, 'Custodian'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _notes,
                    enabled: !disposed,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Notes'),
                    validator: validateNotes,
                  ),
                  if (_editing)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Changes to life and residual value affect future '
                        'depreciation runs only.',
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
