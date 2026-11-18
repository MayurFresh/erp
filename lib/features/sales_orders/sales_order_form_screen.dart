import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/permissions.dart';
import '../auth/session.dart';
import '../documents/credit_limit_dialog.dart';
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
import '../pricing/bill_discount.dart';
import '../pricing/price_prefill.dart';
import 'o2c_repository.dart';
import '../stock_tools/unit_picker.dart';
import 'sales_order_models.dart';

class _Line with PricedLine {
  _Line(this.item,{double qty = 1, double? rate, double discount = 0})
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
  bool freeAdded = false;

  /// Alternate unit the quantity and rate are entered in; null is the item's own unit.
  String? unit;

  @override
  TextEditingController get priceRateField => rate;
  @override
  TextEditingController get priceDiscountField => discount;
  @override
  String get priceItemId => item.itemId;
  @override
  double get priceQty => parseNumber(qty.text) ?? 0;

  double get gross =>
      round2((parseNumber(qty.text) ?? 0) * (parseNumber(rate.text) ?? 0));

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
  final _billDiscount = TextEditingController();
  bool _billPercent = false;
  Timer? _priceTimer;
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
            qty: l.entered?.qty ?? l.qtyOrdered,
            rate: l.entered?.rate ?? l.rate,
            discount: l.discountPct,
          )
            ..allowBackorder = l.allowBackorder
            ..unit = l.entered?.unit,
        );
      }
    }
  }

  @override
  void dispose() {
    _ref.dispose();
    _priceTimer?.cancel();
    _billDiscount.dispose();
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
    _reprice();
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
    final (unit, factor) = await defaultUnitFor(ref, item.itemId, purchase: false);
    if (!mounted) return;
    final line = _Line(item)..autoRate = item.salePrice;
    if (unit != null) {
      line.unit = unit;
      line.rate.text = scaleRateText(line.rate.text, factor);
    }
    setState(() {
      _lines.add(line);
      _linesError = null;
    });
    markDirty();
    _reprice();
  }

  /// Fills rates and scheme discounts from price lists, customer prices and schemes.
  Future<void> _reprice() async {
    final ok = await repriceLines(ref, _partyId, _lines);
    if (ok && mounted) setState(() {});
  }

  void _scheduleReprice() {
    _priceTimer?.cancel();
    _priceTimer = Timer(const Duration(milliseconds: 500), _reprice);
  }

  /// Adds the scheme's free goods as a separate zero-rate line.
  Future<void> _addFree(_Line l) async {
    final p = l.resolved;
    if (p == null || p.freeQty <= 0) return;
    var free = l.item;
    if (p.freeItemId != null && p.freeItemId != l.item.itemId) {
      try {
        final repo = ref.read(o2cRepositoryProvider);
        final found = await repo.availability(
          locationId: _locationId!,
          q: p.freeItemId!,
        );
        final match = found.data.where((a) => a.itemId == p.freeItemId);
        if (match.isEmpty) {
          if (mounted) showInfoSnackBar(context, 'The free item was not found');
          return;
        }
        free = match.first;
      } catch (_) {
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      l.freeAdded = true;
      _lines.insert(_lines.indexOf(l) + 1, _Line(free, qty: p.freeQty, rate: 0));
    });
    markDirty();
  }

  BillDiscount get _bill => BillDiscount(
    value: parseNumber(_billDiscount.text) ?? 0,
    isPercent: _billPercent,
  );

  List<BillLine> get _billLines => [
    for (final l in _lines)
      BillLine(
        qty: l.priceQty,
        rate: parseNumber(l.rate.text) ?? 0,
        discountPct: parseNumber(l.discount.text) ?? 0,
      ),
  ];

  /// Order lines to send. A bill discount is spread over the lines in
  /// proportion to their value; an order line takes a percent, so the spread
  /// amount is converted to one.
  List<OrderLineInput> _inputLines() {
    final fixed = _bill.isZero ? null : fixedDiscounts(_billLines, _bill);
    return [
      for (final (i, l) in _lines.indexed)
        OrderLineInput(
          itemId: l.item.itemId,
          qty: parseNumber(l.qty.text) ?? 0,
          rate: parseNumber(l.rate.text),
          discountPct: fixed == null
              ? parseNumber(l.discount.text) ?? 0
              : discountPctFor(fixed[i], l.gross),
          allowBackorder: l.allowBackorder,
          unit: l.unit,
        ),
    ];
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
      lines: _inputLines(),
    );
    try {
      final repo = ref.read(o2cRepositoryProvider);
      Future<SalesOrder> create() async {
        try {
          return await repo.createOrder(input);
        } catch (e) {
          final limit = creditLimitError(e);
          if (limit == null || !mounted) rethrow;
          final billAnyway = await confirmCreditLimit(
            context,
            limit,
            canOverride: ref
                .read(permissionsProvider)
                .can(Perm.partiesCreditOverride),
            document: 'order',
          );
          if (!billAnyway) throw const _CreditLimitDeclined();
          return repo.createOrder(input.withOverLimit());
        }
      }

      final SalesOrder saved;
      try {
        saved = widget.existing == null
            ? await create()
            : await repo.updateOrder(
                widget.existing!.id,
                input,
                expectedUpdatedAt: widget.existing!.updatedAt,
              );
      } on _CreditLimitDeclined {
        return;
      }
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
                      onAddFree: () => _addFree(l),
                      onChanged: () {
                        setState(() {});
                        markDirty();
                        _scheduleReprice();
                      },
                    ),
                  if (_lines.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: BillDiscountField(
                        controller: _billDiscount,
                        isPercent: _billPercent,
                        appliedAmount: billDiscountTotal(
                          _billLines.fold<double>(0, (a, l) => a + l.taxable),
                          _bill,
                        ),
                        onModeChanged: (v) {
                          setState(() => _billPercent = v);
                          markDirty();
                        },
                        onChanged: () {
                          setState(() {});
                          markDirty();
                        },
                      ),
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
    this.onAddFree,
  });

  final _Line line;
  final VoidCallback onRemove;
  final VoidCallback onChanged;
  final VoidCallback? onAddFree;

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
          Align(
            alignment: Alignment.centerLeft,
            child: LineUnitPicker(
              itemId: item.itemId,
              value: line.unit,
              onChanged: (u) => line.unit = u,
              onRateScale: (r) {
                line.rate.text = scaleRateText(line.rate.text, r);
                onChanged();
              },
            ),
          ),
          const SizedBox(height: 8),
          FormRow(
            breakpoint: 480,
            children: [
              field(
                line.qty,
                'Quantity (${line.unit ?? item.unit})',
                required: true,
                decimals: 3,
              ),
              field(line.rate, 'Rate'),
              field(line.discount, 'Discount %'),
            ],
          ),
          if (line.resolved != null)
            Align(
              alignment: Alignment.centerLeft,
              child: SchemeHint(
                price: line.resolved!,
                onAddFree: onAddFree,
                freeAdded: line.freeAdded,
              ),
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

/// The user went back from the credit limit dialog.
class _CreditLimitDeclined implements Exception {
  const _CreditLimitDeclined();
}
