import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../items/item_model.dart';
import '../items/item_picker.dart';
import '../locations/location_filter.dart';
import '../locations/locations_repository.dart';
import 'stock_models.dart';
import 'stock_repository.dart';

/// `POST /stock/adjustments`; pops with the created [StockMove].
class AdjustStockDialog extends ConsumerStatefulWidget {
  const AdjustStockDialog({super.key, this.initialLocationId});

  final String? initialLocationId;

  @override
  ConsumerState<AdjustStockDialog> createState() => _AdjustStockDialogState();
}

class _AdjustStockDialogState extends ConsumerState<AdjustStockDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _qty = TextEditingController();
  final _rate = TextEditingController();
  final _note = TextEditingController();
  String? _locationId;
  Item? _item;
  bool _add = true;
  bool _opening = false;
  bool _saving = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _locationId = widget.initialLocationId;
  }

  @override
  void dispose() {
    _qty.dispose();
    _rate.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickItem() async {
    final item = await pickItem(context, ref, stockOnly: true);
    if (item != null) {
      setState(() {
        _item = item;
        serverErrors = Map.of(serverErrors)..remove('itemId');
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      serverErrors = const {};
      _error = null;
    });
    if (!_formKey.currentState!.validate()) return;
    final qty = parseNumber(_qty.text)!;
    setState(() => _saving = true);
    try {
      final move = await ref
          .read(stockRepositoryProvider)
          .adjust(
            StockAdjustment(
              locationId: _locationId!,
              itemId: _item!.id,
              qty: _add ? qty : -qty,
              rate: parseNumber(_rate.text),
              note: trimmedOrNull(_note.text),
              isOpening: _opening && _add,
            ),
          );
      ref.bump(const [DataKind.stock]);
      if (mounted) Navigator.of(context).pop(move);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Default to the only location when there is just one.
    final locations = ref.watch(locationsLookupProvider).value;
    if (_locationId == null && locations != null) {
      final active = locations.where((l) => l.isActive).toList();
      if (active.length == 1) _locationId = active.single.id;
    }
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Adjust stock'),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LocationField(
                value: _locationId,
                errorText: serverError('locationId'),
                onChanged: (v) {
                  clearServerError('locationId');
                  setState(() => _locationId = v);
                },
              ),
              const SizedBox(height: 16),
              PickerField(
                label: 'Item',
                value: _item == null ? null : '${_item!.name} (${_item!.unit})',
                onTap: _pickItem,
                errorText: serverError('itemId'),
                validator: () => _item == null ? 'Choose an item' : null,
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Opening stock'),
                subtitle: const Text(
                  'Stock you had before using Progen; booked to opening '
                  'balances instead of other income',
                ),
                value: _opening,
                onChanged: (v) => setState(() {
                  _opening = v;
                  if (v) _add = true;
                }),
              ),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: [
                  const ButtonSegment(
                    value: true,
                    label: Text('Add'),
                    icon: Icon(Icons.add),
                  ),
                  ButtonSegment(
                    value: false,
                    label: const Text('Remove'),
                    icon: const Icon(Icons.remove),
                    enabled: !_opening,
                  ),
                ],
                selected: {_add},
                onSelectionChanged: (s) => setState(() => _add = s.first),
              ),
              const SizedBox(height: 16),
              FormRow(
                breakpoint: 380,
                children: [
                  TextFormField(
                    controller: _qty,
                    decoration: InputDecoration(
                      labelText: 'Quantity',
                      prefixText: _add ? '+ ' : '− ',
                      suffixText: _item?.unit,
                    ),
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput(decimals: 3)],
                    forceErrorText: serverError('qty'),
                    onChanged: (_) => clearServerError('qty'),
                    validator: (v) {
                      final error = requiredNumber(v, label: 'Quantity');
                      if (error != null) return error;
                      return parseNumber(v!)! > 0
                          ? null
                          : 'Must be more than 0';
                    },
                  ),
                  TextFormField(
                    controller: _rate,
                    decoration: InputDecoration(
                      labelText: 'Rate (optional)',
                      prefixText: '₹ ',
                      helperText: _add ? 'Default: average cost' : null,
                      helperMaxLines: 2,
                    ),
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput()],
                    forceErrorText: serverError('rate'),
                    onChanged: (_) => clearServerError('rate'),
                    validator: (v) => optionalNumber(v, min: 0),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _note,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
                forceErrorText: serverError('note'),
                onChanged: (_) => clearServerError('note'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  errorMessage(_error!),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        BusyButton(busy: _saving, onPressed: _save, label: 'Save'),
      ],
    );
  }
}
