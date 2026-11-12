import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/business_profile.dart';

import '../../core/money.dart';
import '../../widgets/busy.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/search_picker.dart';
import '../../widgets/states.dart';
import '../locations/location_filter.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'o2c_repository.dart';
import 'sales_order_models.dart';

class _Line {
  _Line(this.item, {double qty = 1, double? rate, double discount = 0})
    : qty = TextEditingController(text: formatPlain(qty)),
      rate = TextEditingController(text: formatPlain(rate ?? item.salePrice)),
      discount = TextEditingController(
        text: discount == 0 ? '' : formatPlain(discount),
      );

  Availability item;
  final TextEditingController qty;
  final TextEditingController rate;
  final TextEditingController discount;
  bool allowBackorder = false;

  void dispose() {
    qty.dispose();
    rate.dispose();
    discount.dispose();
  }
}

/// Creates a draft order or edits one (`orderId` set).
class SalesOrderFormScreen extends ConsumerWidget {
  const SalesOrderFormScreen({super.key, this.orderId});

  final String? orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (orderId == null) return const _OrderForm();
    return AsyncValueView(
      value: ref.watch(salesOrderProvider(orderId!)),
      onRetry: () => ref.invalidate(salesOrderProvider(orderId!)),
      data: (o) {
        if (!o.isDraft) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            showInfoSnackBar(context, 'Only a draft order can be edited.');
            context.go('/sales-orders/$orderId');
          });
          return const LoadingView();
        }
        return _OrderForm(existing: o);
      },
    );
  }
}

class _OrderForm extends ConsumerStatefulWidget {
  const _OrderForm({this.existing});

  final SalesOrder? existing;

  @override
  ConsumerState<_OrderForm> createState() => _OrderFormState();
}

class _OrderFormState extends ConsumerState<_OrderForm>
    with DirtyTracking, ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _ref = TextEditingController();
  final _notes = TextEditingController();
  final List<_Line> _lines = [];
  String? _locationId;
  String? _partyId;
  String? _partyName;
  DateTime _date = DateTime.now();
  DateTime? _expected;
  bool _saving = false;
  String? _linesError;

  @override
  void initState() {
    super.initState();
    final o = widget.existing;
    if (o != null) {
      _locationId = o.locationId;
      _partyId = o.partyId;
      _partyName = o.partyName;
      _ref.text = o.externalRef ?? '';
      _notes.text = o.notes ?? '';
      _date = DateTime.tryParse(o.orderDate ?? '') ?? _date;
      _expected = DateTime.tryParse(o.expectedDate ?? '');
      for (final l in o.lines) {
        _lines.add(
          _Line(
            Availability(
              itemId: l.itemId,
              name: l.itemName,
              sku: l.sku,
              unit: l.unit,
              salePrice: l.rate,
              onHand: 0,
              reserved: 0,
              available: 0,
            ),
            qty: l.qtyOrdered,
            rate: l.rate,
            discount: l.discountPct,
          )..allowBackorder = l.allowBackorder,
        );
      }
    }
  }

  @override
  void dispose() {
    _ref.dispose();
    _notes.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _pickParty() async {
    final p = await pickParty(context, ref, type: PartyType.customer);
    if (p == null || !mounted) return;
    setState(() {
      _partyId = p.id;
      _partyName = p.name;
    });
    clearServerError('partyId');
    markDirty();
  }

  Future<void> _pickDate({required bool expected}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (expected ? _expected : _date) ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 2),
    );
    if (picked == null || !mounted) return;
    setState(() => expected ? _expected = picked : _date = picked);
    markDirty();
  }

  Future<void> _addItem() async {
    final loc = _locationId;
    if (loc == null) {
      showInfoSnackBar(context, 'Choose the dispatch location first');
      return;
    }
    final repo = ref.read(o2cRepositoryProvider);
    final item = await showSearchPicker<Availability>(
      context: context,
      title: context.w('Add an item'),
      hintText: 'Search name, SKU or barcode',
      search: (q) async =>
          (await repo.availability(locationId: loc, q: q)).data,
      titleBuilder: (_, a) => Text(a.name),
      subtitleBuilder: (_, a) => Text(
        [
          if (a.sku != null) a.sku!,
          'On hand ${formatQty(a.onHand)} · reserved ${formatQty(a.reserved)}',
        ].join(' · '),
      ),
      trailingBuilder: (_, a) => Text(
        '${formatQty(a.available)} ${a.unit}',
        key: ValueKey('available-${a.itemId}'),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
    if (item == null || !mounted) return;
    setState(() {
      _lines.add(_Line(item));
      _linesError = null;
    });
    markDirty();
  }

  void _removeLine(int i) {
    setState(() => _lines.removeAt(i).dispose());
    markDirty();
  }

  Future<void> _save() async {
    if (_saving) return;
    final valid = validateAndReveal(_formKey);
    if (_lines.isEmpty) {
      setState(() => _linesError = 'Add at least one item');
      return;
    }
    if (!valid || _partyId == null || _locationId == null) return;
    setState(() => _saving = true);
    final input = SalesOrderInput(
      locationId: _locationId!,
      partyId: _partyId!,
      orderDate: apiDate(_date),
      expectedDate: _expected == null ? null : apiDate(_expected!),
      externalRef: trimmedOrNull(_ref.text),
      notes: trimmedOrNull(_notes.text),
      lines: [
        for (final l in _lines)
          OrderLineInput(
            itemId: l.item.itemId,
            qty: parseNumber(l.qty.text) ?? 0,
            rate: parseNumber(l.rate.text),
            discountPct: parseNumber(l.discount.text) ?? 0,
            allowBackorder: l.allowBackorder,
          ),
      ],
    );
    try {
      final repo = ref.read(o2cRepositoryProvider);
      final saved = widget.existing == null
          ? await repo.createOrder(input)
          : await repo.updateOrder(
              widget.existing!.id,
              input,
              expectedUpdatedAt: widget.existing!.updatedAt,
            );
      markSaved();
      ref.read(o2cRevisionProvider.notifier).bump();
      if (!mounted) return;
      showInfoSnackBar(context, 'Order ${saved.number} saved');
      context.go('/sales-orders/${saved.id}');
    } catch (e) {
      if (mounted) {
        showSubmitError(
          e,
          onReload: () {
            markSaved();
            context.go('/sales-orders/${widget.existing?.id}');
          },
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    final theme = Theme.of(context);
    return track(
      Form(
        key: _formKey,
        onChanged: markDirty,
        child: FormPage(
          bottomBar: FormActionBar(
            children: [
              TextButton(
                onPressed: _saving
                    ? null
                    : () => leave(
                        editing
                            ? '/sales-orders/${widget.existing!.id}'
                            : '/sales-orders',
                      ),
                child: const Text('Cancel'),
              ),
              BusyButton(
                busy: _saving,
                onPressed: _save,
                label: editing ? 'Save changes' : 'Save draft',
                icon: Icons.check,
              ),
            ],
          ),
          maxWidth: 1000,
          children: [
            Text(
              editing ? 'Edit ${widget.existing!.number}' : 'New sales order',
              style: theme.textTheme.headlineSmall,
            ),
            SectionCard(
              title: context.w('Order'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormRow(
                    children: [
                      PickerField(
                        label: context.w('Customer'),
                        value: _partyName,
                        errorText: serverError('partyId'),
                        onTap: _pickParty,
                        validator: () => _partyId == null
                            ? context.w('Choose a customer')
                            : null,
                      ),
                      LocationField(
                        value: _locationId,
                        label: context.w('Dispatch location'),
                        errorText: serverError('locationId'),
                        onChanged: (v) {
                          setState(() => _locationId = v);
                          markDirty();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FormRow(
                    children: [
                      PickerField(
                        label: context.w('Order date'),
                        value: formatDate(_date),
                        icon: Icons.calendar_today_outlined,
                        onTap: () => _pickDate(expected: false),
                      ),
                      PickerField(
                        label: 'Expected dispatch (optional)',
                        value: _expected == null ? null : formatDate(_expected),
                        icon: Icons.calendar_today_outlined,
                        onTap: () => _pickDate(expected: true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _ref,
                    maxLength: 80,
                    decoration: InputDecoration(
                      labelText: context.w('Customer reference (optional)'),
                      errorText: serverError('externalRef'),
                    ),
                  ),
                  TextFormField(
                    controller: _notes,
                    maxLines: 2,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                    ),
                  ),
                ],
              ),
            ),
            SectionCard(
              title: context.w('Items'),
              trailing: TextButton.icon(
                onPressed: _addItem,
                icon: const Icon(Icons.add),
                label: Text(context.w('Add item')),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_lines.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'No items yet. Choose a location, then add items to '
                        'see what is available.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  for (final (i, l) in _lines.indexed)
                    _LineEditor(
                      key: ObjectKey(l),
                      line: l,
                      onRemove: () => _removeLine(i),
                      onChanged: () {
                        setState(() {});
                        markDirty();
                      },
                    ),
                  if (_linesError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _linesError!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LineEditor extends StatelessWidget {
  const _LineEditor({
    super.key,
    required this.line,
    required this.onRemove,
    required this.onChanged,
  });

  final _Line line;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = line.item;
    final qty = parseNumber(line.qty.text) ?? 0;
    final short = item.available > 0 || item.onHand > 0
        ? qty > item.available
        : false;
    Widget field(
      TextEditingController c,
      String label, {
      bool required = false,
      int decimals = 2,
    }) => TextFormField(
      controller: c,
      keyboardType: decimalKeyboard,
      inputFormatters: <TextInputFormatter>[decimalInput(decimals: decimals)],
      decoration: InputDecoration(labelText: label),
      onChanged: (_) => onChanged(),
      validator: required
          ? (v) {
              final n = parseNumber(v ?? '');
              return n == null || n <= 0 ? 'Enter more than zero' : null;
            }
          : null,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(item.name, style: theme.textTheme.titleSmall),
              ),
              IconButton(
                tooltip: context.w('Remove item'),
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          if (item.onHand > 0 || item.available > 0 || item.reserved > 0)
            Text(
              'Available ${formatQty(item.available)} ${item.unit}'
              ' (on hand ${formatQty(item.onHand)}, '
              'reserved ${formatQty(item.reserved)})',
              style: theme.textTheme.bodySmall?.copyWith(
                color: short
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 8),
          FormRow(
            breakpoint: 480,
            children: [
              field(
                line.qty,
                'Quantity (${item.unit})',
                required: true,
                decimals: 3,
              ),
              field(line.rate, 'Rate'),
              field(line.discount, 'Discount %'),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(context.w('Allow backorder for this line')),
            value: line.allowBackorder,
            onChanged: (v) {
              line.allowBackorder = v;
              onChanged();
            },
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}
