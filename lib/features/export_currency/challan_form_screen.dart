import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../items/item_picker.dart';
import '../locations/location_filter.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'export_models.dart';
import 'export_repository.dart';

class _Row {
  _Row(this.itemId, this.name, this.unit, double rate)
    : qty = TextEditingController(text: '1'),
      rate = TextEditingController(text: formatPlain(rate));
  final String itemId;
  final String name;
  final String unit;
  final TextEditingController qty;
  final TextEditingController rate;
  bool provisional = false;
}

/// Issue a delivery challan.
class ChallanFormScreen extends ConsumerStatefulWidget {
  const ChallanFormScreen({super.key});

  @override
  ConsumerState<ChallanFormScreen> createState() => _ChallanFormScreenState();
}

class _ChallanFormScreenState extends ConsumerState<ChallanFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _consignee = TextEditingController();
  final _address = TextEditingController();
  final _gstin = TextEditingController();
  final _vehicle = TextEditingController();
  final _transporter = TextEditingController();
  final _ewb = TextEditingController();
  final _notes = TextEditingController();
  final List<_Row> _rows = [];
  String _reason = 'supply_on_approval';
  String? _locationId;
  String? _toLocationId;
  Party? _party;
  bool _saving = false;
  Map<String, String> _errors = const {};

  @override
  void dispose() {
    for (final c in [
      _consignee,
      _address,
      _gstin,
      _vehicle,
      _transporter,
      _ewb,
      _notes,
    ]) {
      c.dispose();
    }
    for (final r in _rows) {
      r.qty.dispose();
      r.rate.dispose();
    }
    super.dispose();
  }

  Future<void> _pickParty() async {
    final p = await pickParty(context, ref, type: PartyType.customer);
    if (p == null) return;
    setState(() {
      _party = p;
      _consignee.text = p.name;
      _address.text = p.address ?? '';
      _gstin.text = p.gstin ?? '';
    });
  }

  Future<void> _addItem() async {
    final item = await pickItem(context, ref);
    if (item == null) return;
    setState(() => _rows.add(_Row(item.id, item.name, item.unit, item.salePrice)));
  }

  bool get transferNeedsTarget =>
      _reason == 'branch_transfer' && _toLocationId == null;

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_locationId == null) {
      setState(() => _errors = {'locationId': 'Choose a location'});
      return;
    }
    if (transferNeedsTarget) {
      setState(() => _errors = {'toLocationId': 'Choose the destination'});
      return;
    }
    if (_rows.isEmpty) {
      showErrorSnackBar(context, 'Add at least one item.');
      return;
    }
    setState(() {
      _saving = true;
      _errors = const {};
    });
    try {
      final c = await ref.read(exportRepositoryProvider).createChallan(
        ChallanInput(
          locationId: _locationId!,
          reason: _reason,
          toLocationId: _reason == 'branch_transfer' ? _toLocationId : null,
          partyId: _party?.id,
          consigneeName: trimmedOrNull(_consignee.text),
          consigneeAddress: trimmedOrNull(_address.text),
          consigneeGstin: trimmedOrNull(_gstin.text),
          vehicleNo: trimmedOrNull(_vehicle.text),
          transporter: trimmedOrNull(_transporter.text),
          ewbNo: trimmedOrNull(_ewb.text),
          notes: trimmedOrNull(_notes.text),
          lines: [
            for (final r in _rows)
              ChallanLineInput(
                itemId: r.itemId,
                qty: parseNumber(r.qty.text) ?? 0,
                rate: parseNumber(r.rate.text),
                provisional: r.provisional,
              ),
          ],
        ),
      );
      ref.read(exportRevisionProvider.notifier).bump();
      if (mounted) context.go('/delivery-challans/${c.id}');
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showErrorSnackBar(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final transfer = _reason == 'branch_transfer';
    return Form(
      key: _formKey,
      child: FormPage(
        bottomBar: FormActionBar(
          children: [
            TextButton(
              onPressed: _saving ? null : () => context.go('/delivery-challans'),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving' : 'Issue challan'),
            ),
          ],
        ),
        children: [
          const PageHeader(
            title: 'New delivery challan',
            subtitle: 'Stock leaves the location when you issue it',
          ),
          SectionCard(
            title: 'Movement',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _reason,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Reason'),
                      items: [
                        for (final e in challanReasons.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) => setState(() => _reason = v ?? _reason),
                    ),
                    LocationField(
                      value: _locationId,
                      label: 'From location',
                      errorText: _errors['locationId'],
                      onChanged: (v) => setState(() => _locationId = v),
                    ),
                    if (transfer)
                      LocationField(
                        value: _toLocationId,
                        label: 'To location',
                        errorText: _errors['toLocationId'],
                        onChanged: (v) => setState(() => _toLocationId = v),
                      ),
                  ],
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Consignee',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  children: [
                    PickerField(
                      label: 'Customer (needed to bill the challan later)',
                      value: _party?.name,
                      onTap: _pickParty,
                    ),
                    TextFormField(
                      controller: _consignee,
                      decoration: const InputDecoration(labelText: 'Consignee name'),
                      validator: (v) => transfer || (v ?? '').trim().isNotEmpty
                          ? null
                          : 'Enter the consignee',
                    ),
                    TextFormField(
                      controller: _gstin,
                      decoration: const InputDecoration(labelText: 'GSTIN (optional)'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _address,
                  decoration: const InputDecoration(labelText: 'Address (optional)'),
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Items',
            trailing: TextButton.icon(
              onPressed: _addItem,
              icon: const Icon(Icons.add),
              label: const Text('Add item'),
            ),
            child: _rows.isEmpty
                ? const Text('No items yet.')
                : Column(
                    children: [
                      for (final (i, r) in _rows.indexed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.name, style: Theme.of(context).textTheme.titleSmall),
                              const SizedBox(height: 8),
                              FormRow(
                                children: [
                                  TextFormField(
                                    controller: r.qty,
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(labelText: 'Quantity (${r.unit})'),
                                    validator: (v) => (parseNumber(v ?? '') ?? 0) > 0 ? null : 'Enter a quantity',
                                  ),
                                  TextFormField(
                                    controller: r.rate,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(labelText: 'Value per unit'),
                                  ),
                                ],
                              ),
                              Row(
                                children: [
                                  Expanded(
                                    child: CheckboxListTile(
                                      value: r.provisional,
                                      contentPadding: EdgeInsets.zero,
                                      controlAffinity: ListTileControlAffinity.leading,
                                      title: const Text('Quantity is provisional'),
                                      onChanged: (v) => setState(() => r.provisional = v ?? false),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Remove item',
                                    onPressed: () => setState(() => _rows.removeAt(i)),
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          SectionCard(
            title: 'Transport',
            child: FormRow(
              children: [
                TextFormField(
                  controller: _vehicle,
                  decoration: const InputDecoration(labelText: 'Vehicle number'),
                ),
                TextFormField(
                  controller: _transporter,
                  decoration: const InputDecoration(labelText: 'Transporter'),
                ),
                TextFormField(
                  controller: _ewb,
                  decoration: const InputDecoration(labelText: 'E-way bill number'),
                ),
                TextFormField(
                  controller: _notes,
                  decoration: const InputDecoration(labelText: 'Notes'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
