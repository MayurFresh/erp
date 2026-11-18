import '../controls/custom_fields_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/business_profile.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../tax/tax_pickers.dart';
import 'item_model.dart';
import 'items_repository.dart';
import '../../widgets/busy.dart';
import '../gst_compliance/rate_history_card.dart';

/// Create (`/items/new`) or edit (`/items/:id`) an item.
class ItemFormScreen extends ConsumerWidget {
  const ItemFormScreen({super.key, this.itemId});

  final String? itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = itemId;
    if (id == null) return const ItemForm();
    return AsyncValueView(
      value: ref.watch(itemProvider(id)),
      onRetry: () => ref.invalidate(itemProvider(id)),
      data: (item) => ItemForm(key: ValueKey(item.id), item: item),
    );
  }
}

class ItemForm extends ConsumerStatefulWidget {
  const ItemForm({super.key, this.item});

  final Item? item;

  @override
  ConsumerState<ItemForm> createState() => _ItemFormState();
}

class _ItemFormState extends ConsumerState<ItemForm>
    with ServerFieldErrors, DirtyTracking<ItemForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _sku;
  late final TextEditingController _barcode;
  late final TextEditingController _hsn;
  late final TextEditingController _unit;
  late final TextEditingController _salePrice;
  late final TextEditingController _mrp;
  late final TextEditingController _purchasePrice;
  late final TextEditingController _reorder;
  late double _gstRate;
  late bool _trackStock;
  late bool _active;
  late Json _custom;
  bool _saving = false;

  bool get _editing => widget.item != null;

  /// SAC codes start with 99 (services); other codes are goods.
  String? get _rateKind {
    final hsn = _hsn.text.trim();
    if (hsn.isEmpty) return null;
    return hsn.startsWith('99') ? 'services' : 'goods';
  }

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _name = TextEditingController(text: item?.name);
    _sku = TextEditingController(text: item?.sku);
    _barcode = TextEditingController(text: item?.barcode);
    _hsn = TextEditingController(text: item?.hsnCode);
    _unit = TextEditingController(text: item?.unit ?? 'pcs');
    _salePrice = TextEditingController(text: formatPlain(item?.salePrice));
    _mrp = TextEditingController(text: formatPlain(item?.mrp));
    _purchasePrice = TextEditingController(
      text: formatPlain(item?.purchasePrice),
    );
    _reorder = TextEditingController(text: formatPlain(item?.reorderLevel));
    _gstRate = item?.gstRate ?? 18;
    _trackStock = item?.trackStock ?? true;
    _active = item?.isActive ?? true;
    _custom = item?.custom ?? const {};
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _sku,
      _barcode,
      _hsn,
      _unit,
      _salePrice,
      _mrp,
      _purchasePrice,
      _reorder,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save({required bool showCost}) async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    final original = widget.item;
    final input = ItemInput(
      name: _name.text.trim(),
      sku: trimmedOrNull(_sku.text),
      barcode: trimmedOrNull(_barcode.text),
      hsnCode: trimmedOrNull(_hsn.text),
      unit: _unit.text.trim(),
      gstRate: _gstRate,
      salePrice: parseNumber(_salePrice.text) ?? 0,
      mrp: parseNumber(_mrp.text),
      // An emptied cost keeps the stored value rather than sending null.
      purchasePrice:
          parseNumber(_purchasePrice.text) ?? original?.purchasePrice,
      trackStock: _trackStock,
      reorderLevel: parseNumber(_reorder.text) ?? 0,
      isActive: _active,
      custom: _custom,
    );
    setState(() => _saving = true);
    try {
      final repo = ref.read(itemsRepositoryProvider);
      final saved = original == null
          ? await repo.create(input, includeCost: showCost)
          : await repo.update(original, input, includeCost: showCost);
      ref.bump(const [DataKind.items, DataKind.stock]);
      if (!mounted) return;
      markSaved();
      showInfoSnackBar(context, 'Saved "${saved.name}"');
      context.go('/items');
    } catch (e) {
      if (mounted) {
        showSubmitError(
          e,
          onReload: () {
            markSaved();
            context.go('/items');
          },
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final isIndia = ref.watch(businessProfileProvider).isIndia;
    final showCost = perms.can(Perm.itemsViewCost);
    final canSave = _editing
        ? perms.can(Perm.itemsEdit)
        : perms.can(Perm.itemsCreate);

    return Form(
      key: _formKey,
      onChanged: markDirty,
      child: FormPage(
        bottomBar: FormActionBar(
          children: [
            OutlinedButton(
              onPressed: _saving ? null : () => leave('/items'),
              child: Text(canSave ? 'Cancel' : 'Back'),
            ),
            if (canSave)
              BusyButton(
                busy: _saving,
                onPressed: () => _save(showCost: showCost),
                label: _editing ? 'Save changes' : 'Create item',
              ),
          ],
        ),
        children: [
          Text(
            _editing ? 'Edit item' : 'New item',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  enabled: canSave,
                  decoration: const InputDecoration(labelText: 'Name'),
                  textCapitalization: TextCapitalization.sentences,
                  forceErrorText: serverError('name'),
                  onChanged: (_) => clearServerError('name'),
                  validator: (v) => requiredField(v, 'Name'),
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _sku,
                      enabled: canSave,
                      decoration: const InputDecoration(
                        labelText: 'SKU (optional)',
                      ),
                      forceErrorText: serverError('sku'),
                      onChanged: (_) => clearServerError('sku'),
                    ),
                    TextFormField(
                      controller: _barcode,
                      enabled: canSave,
                      decoration: const InputDecoration(
                        labelText: 'Barcode (optional)',
                        helperText: 'Used when picking and packing orders',
                      ),
                      forceErrorText: serverError('barcode'),
                      onChanged: (_) => clearServerError('barcode'),
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return null;
                        if (t.length < 4 || t.length > 64) {
                          return 'Use 4 to 64 characters';
                        }
                        if (t.contains(RegExp(r'\s'))) {
                          return 'No spaces allowed';
                        }
                        return null;
                      },
                    ),
                    if (isIndia)
                      TextFormField(
                        controller: _hsn,
                        enabled: canSave,
                        decoration: const InputDecoration(
                          labelText: 'HSN / SAC (optional)',
                        ),
                        keyboardType: TextInputType.number,
                        forceErrorText: serverError('hsnCode'),
                        onChanged: (_) {
                          clearServerError('hsnCode');
                          setState(() {});
                        },
                        validator: (v) {
                          final text = v?.trim() ?? '';
                          if (text.isEmpty) return null;
                          return RegExp(r'^\d{4,8}$').hasMatch(text)
                              ? null
                              : 'Use 4 to 8 digits';
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _unit,
                      enabled: canSave,
                      decoration: InputDecoration(
                        labelText: 'Unit',
                        suffixIcon: PopupMenuButton<String>(
                          enabled: canSave,
                          tooltip: 'Choose a unit',
                          icon: const Icon(Icons.arrow_drop_down),
                          onSelected: (unit) {
                            _unit.text = unit;
                            clearServerError('unit');
                          },
                          itemBuilder: (context) => [
                            for (final unit in itemUnits)
                              PopupMenuItem(value: unit, child: Text(unit)),
                          ],
                        ),
                      ),
                      forceErrorText: serverError('unit'),
                      onChanged: (_) => clearServerError('unit'),
                      validator: (v) => requiredField(v, 'Unit'),
                    ),
                    GstRatePicker(
                      value: _gstRate,
                      kind: _rateKind,
                      enabled: canSave,
                      errorText: serverError('gstRate'),
                      onChanged: (v) => setState(() {
                        _gstRate = v ?? _gstRate;
                        serverErrors = Map.of(serverErrors)..remove('gstRate');
                      }),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Pricing',
            child: FormRow(
              children: [
                TextFormField(
                  controller: _salePrice,
                  enabled: canSave,
                  decoration: InputDecoration(
                    labelText: 'Sale price',
                    prefixText: '$moneySymbol ',
                  ),
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  forceErrorText: serverError('salePrice'),
                  onChanged: (_) => clearServerError('salePrice'),
                  validator: (v) =>
                      requiredNumber(v, label: 'Sale price', min: 0),
                ),
                TextFormField(
                  controller: _mrp,
                  enabled: canSave,
                  decoration: InputDecoration(
                    labelText: 'MRP (optional)',
                    prefixText: '$moneySymbol ',
                  ),
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  forceErrorText: serverError('mrp'),
                  onChanged: (_) => clearServerError('mrp'),
                  validator: (v) => optionalNumber(v, min: 0),
                ),
                if (showCost)
                  TextFormField(
                    controller: _purchasePrice,
                    enabled: canSave,
                    decoration: InputDecoration(
                      labelText: 'Purchase price (optional)',
                      prefixText: '$moneySymbol ',
                    ),
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput()],
                    forceErrorText: serverError('purchasePrice'),
                    onChanged: (_) => clearServerError('purchasePrice'),
                    validator: (v) => optionalNumber(v, min: 0),
                  ),
              ],
            ),
          ),
          SectionCard(
            title: 'Stock',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.w('Track stock')),
                  subtitle: const Text(
                    'Invoices reduce stock and fail when it would go negative',
                  ),
                  value: _trackStock,
                  onChanged: canSave
                      ? (v) => setState(() => _trackStock = v)
                      : null,
                ),
                if (_trackStock) ...[
                  const SizedBox(height: 8),
                  FormRow(
                    children: [
                      TextFormField(
                        controller: _reorder,
                        enabled: canSave,
                        decoration: const InputDecoration(
                          labelText: 'Reorder level',
                          helperText: 'Flagged as low stock at or below this',
                        ),
                        keyboardType: decimalKeyboard,
                        inputFormatters: [decimalInput(decimals: 3)],
                        forceErrorText: serverError('reorderLevel'),
                        onChanged: (_) => clearServerError('reorderLevel'),
                        validator: (v) => optionalNumber(v, min: 0),
                      ),
                    ],
                  ),
                ],
                if (_editing)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    subtitle: Text(
                      context.w('Inactive items cannot be invoiced'),
                    ),
                    value: _active,
                    onChanged: canSave
                        ? (v) => setState(() => _active = v)
                        : null,
                  ),
              ],
            ),
          ),
          if (_editing) RateHistoryCard(itemId: widget.item!.id),
          if (_editing)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    context.push('/items/${widget.item!.id}/units'),
                icon: const Icon(Icons.straighten_outlined),
                label: const Text('Other units (box, dozen)'),
              ),
            ),
          CustomFieldsSection(
            entity: 'item',
            values: _custom,
            errors: serverErrors,
            onChanged: (v) => setState(() => _custom = v),
          ),
        ],
      ),
    );
  }
}
