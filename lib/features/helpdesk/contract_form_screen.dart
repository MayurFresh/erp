import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../construction/common/c_widgets.dart'
    show CGate, DateField, showSuccess;
import '../items/item_model.dart';
import '../items/item_picker.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'helpdesk_models.dart';
import 'helpdesk_repository.dart';

/// `/service-contracts/new`.
class ContractFormScreen extends ConsumerStatefulWidget {
  const ContractFormScreen({super.key});

  @override
  ConsumerState<ContractFormScreen> createState() => _ContractFormScreenState();
}

class _ContractFormScreenState extends ConsumerState<ContractFormScreen>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _value = TextEditingController();
  final _assets = TextEditingController();
  Party? _party;
  Item? _item;
  DateTime _start = DateUtils.dateOnly(DateTime.now());
  DateTime _end = DateUtils.dateOnly(
    DateTime.now().add(const Duration(days: 364)),
  );
  String _billing = 'upfront';
  String _billFreq = 'quarterly';
  String _visitFreq = 'quarterly';
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_title, _value, _assets]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    final missing = {
      if (_party == null) 'partyId': 'Choose the customer',
      if (_item == null) 'serviceItemId': 'Choose the service item',
    };
    if (missing.isNotEmpty) {
      setState(() => serverErrors = missing);
      return;
    }
    setState(() => _saving = true);
    try {
      final c = await ref.read(helpdeskRepositoryProvider).createContract({
        'partyId': _party!.id,
        'title': _title.text.trim(),
        'startDate': apiDate(_start),
        'endDate': apiDate(_end),
        'value': parseIndianNumber(_value.text) ?? 0,
        'billing': _billing,
        if (_billing == 'periodic') 'billFrequency': _billFreq,
        'visitFrequency': _visitFreq,
        'serviceItemId': _item!.id,
        'assets': [
          for (final line in _assets.text.split('\n'))
            if (line.trim().isNotEmpty) {'serialNo': line.trim()},
        ],
      });
      ref.read(helpdeskRevisionProvider.notifier).bump();
      if (!mounted) return;
      showSuccess(context, 'Contract ${c.number} created');
      context.go('/service-contracts/${c.id}');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => CGate(
    anyOf: const [Perm.serviceContractsManage],
    child: Form(
      key: _formKey,
      child: FormPage(
        maxWidth: 760,
        bottomBar: FormActionBar(
          children: [
            TextButton(
              onPressed: _saving
                  ? null
                  : () => context.go('/service-contracts'),
              child: const Text('Cancel'),
            ),
            BusyButton(
              busy: _saving,
              onPressed: _saving ? null : _save,
              label: 'Create contract',
            ),
          ],
        ),
        children: [
          Text('New contract', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Customer and term',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PickerField(
                  label: 'Customer',
                  value: _party?.name,
                  errorText: serverError('partyId'),
                  onTap: () async {
                    final p = await pickParty(
                      context,
                      ref,
                      type: PartyType.customer,
                    );
                    if (p != null) setState(() => _party = p);
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _title,
                  decoration: InputDecoration(
                    labelText: 'Title, such as Server AMC',
                    errorText: serverError('title'),
                  ),
                  validator: (v) => requiredField(v, 'Title'),
                ),
                const SizedBox(height: 12),
                FormRow(
                  children: [
                    DateField(
                      label: 'Start date',
                      value: _start,
                      lastDate: DateTime.now().add(const Duration(days: 730)),
                      onChanged: (d) => setState(() => _start = d),
                    ),
                    DateField(
                      label: 'End date',
                      value: _end,
                      errorText: serverError('endDate'),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                      onChanged: (d) => setState(() => _end = d),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _assets,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText:
                        'Covered serial numbers or equipment, one per line',
                  ),
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Billing and visits',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PickerField(
                  label: 'Service item used on the bill',
                  value: _item?.name,
                  errorText: serverError('serviceItemId'),
                  onTap: () async {
                    final i = await pickItem(context, ref);
                    if (i != null) setState(() => _item = i);
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _value,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Contract value before GST',
                    errorText: serverError('value'),
                  ),
                  validator: (v) => requiredNumber(v, label: 'Value', min: 0),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'upfront',
                      label: Text('Bill upfront'),
                    ),
                    ButtonSegment(
                      value: 'periodic',
                      label: Text('Bill in periods'),
                    ),
                  ],
                  selected: {_billing},
                  onSelectionChanged: (s) => setState(() => _billing = s.first),
                ),
                if (_billing == 'periodic') ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _billFreq,
                    decoration: const InputDecoration(labelText: 'Bill every'),
                    items: [
                      for (final e in billFrequencies.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => setState(() => _billFreq = v!),
                  ),
                ],
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _visitFreq,
                  decoration: const InputDecoration(
                    labelText: 'Preventive visits',
                  ),
                  items: [
                    for (final e in visitFrequencies.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() => _visitFreq = v!),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
