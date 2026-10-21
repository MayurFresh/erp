import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'item_model.dart';
import 'items_repository.dart';

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

class _ItemFormState extends ConsumerState<ItemForm> with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _sku;
  late final TextEditingController _hsn;
  late final TextEditingController _unit;
  late final TextEditingController _salePrice;
  late final TextEditingController _purchasePrice;
  late final TextEditingController _reorder;
  late double _gstRate;
  late bool _trackStock;
  late bool _active;
  bool _saving = false;

  bool get _editing => widget.item != null;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _name = TextEditingController(text: item?.name);
    _sku = TextEditingController(text: item?.sku);
    _hsn = TextEditingController(text: item?.hsnCode);
    _unit = TextEditingController(text: item?.unit ?? 'pcs');
    _salePrice = TextEditingController(text: formatPlain(item?.salePrice));
    _purchasePrice = TextEditingController(
      text: formatPlain(item?.purchasePrice),
    );
    _reorder = TextEditingController(text: formatPlain(item?.reorderLevel));
    _gstRate = item?.gstRate ?? 18;
    _trackStock = item?.trackStock ?? true;
    _active = item?.isActive ?? true;
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _sku,
      _hsn,
      _unit,
      _salePrice,
      _purchasePrice,
      _reorder,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save({required bool showCost}) async {
    setState(() => serverErrors = const {});
    if (!_formKey.currentState!.validate()) return;
    final original = widget.item;
    final input = ItemInput(
      name: _name.text.trim(),
      sku: trimmedOrNull(_sku.text),
      hsnCode: trimmedOrNull(_hsn.text),
      unit: _unit.text.trim(),
      gstRate: _gstRate,
      salePrice: parseNumber(_salePrice.text) ?? 0,
      // An emptied cost keeps the stored value rather than sending null.
      purchasePrice:
          parseNumber(_purchasePrice.text) ?? original?.purchasePrice,
      trackStock: _trackStock,
      reorderLevel: parseNumber(_reorder.text) ?? 0,
      isActive: _active,
    );
    setState(() => _saving = true);
    try {
      final repo = ref.read(itemsRepositoryProvider);
      final saved = original == null
          ? await repo.create(input, includeCost: showCost)
          : await repo.update(original, input, includeCost: showCost);
      ref.bump(const [DataKind.items, DataKind.stock]);
      if (!mounted) return;
      showInfoSnackBar(context, 'Saved "${saved.name}"');
      context.go('/items');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final showCost = perms.can(Perm.itemsViewCost);
    final canSave = _editing
        ? perms.can(Perm.itemsEdit)
        : perms.can(Perm.itemsCreate);
    final rates = {...gstRates, _gstRate}.toList()..sort();

    return Form(
      key: _formKey,
      child: FormPage(
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
                      controller: _hsn,
                      enabled: canSave,
                      decoration: const InputDecoration(
                        labelText: 'HSN / SAC (optional)',
                      ),
                      keyboardType: TextInputType.number,
                      forceErrorText: serverError('hsnCode'),
                      onChanged: (_) => clearServerError('hsnCode'),
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
                    DropdownButtonFormField<double>(
                      initialValue: _gstRate,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'GST rate'),
                      forceErrorText: serverError('gstRate'),
                      items: [
                        for (final rate in rates)
                          DropdownMenuItem(
                            value: rate,
                            child: Text(formatPercent(rate)),
                          ),
                      ],
                      onChanged: canSave
                          ? (v) => setState(() {
                              _gstRate = v ?? _gstRate;
                              serverErrors = Map.of(serverErrors)
                                ..remove('gstRate');
                            })
                          : null,
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
                  decoration: const InputDecoration(
                    labelText: 'Sale price',
                    prefixText: '₹ ',
                  ),
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  forceErrorText: serverError('salePrice'),
                  onChanged: (_) => clearServerError('salePrice'),
                  validator: (v) =>
                      requiredNumber(v, label: 'Sale price', min: 0),
                ),
                if (showCost)
                  TextFormField(
                    controller: _purchasePrice,
                    enabled: canSave,
                    decoration: const InputDecoration(
                      labelText: 'Purchase price (optional)',
                      prefixText: '₹ ',
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
                  title: const Text('Track stock'),
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
                if (_editing)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    subtitle: const Text('Inactive items cannot be invoiced'),
                    value: _active,
                    onChanged: canSave
                        ? (v) => setState(() => _active = v)
                        : null,
                  ),
              ],
            ),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _saving ? null : () => context.go('/items'),
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
        ],
      ),
    );
  }
}
