import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_profile.dart';
import '../../core/money.dart';
import '../../widgets/busy.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/money_text.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../items/item_picker.dart';
import '../locations/location_filter.dart';
import '../parties/contact_model.dart';
import '../parties/parties_repository.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import '../items/items_repository.dart';
import '../pricing/bill_discount.dart';
import '../pricing/price_prefill.dart';
import 'quotation_models.dart';
import 'quotation_repository.dart';

const int defaultValidityDays = 15;

class _Line with PricedLine {
  _Line({
    required this.itemId,
    required this.name,
    required this.unit,
    required this.gstRate,
    double qty = 1,
    double rate = 0,
    double discountPct = 0,
    double discountAmount = 0,
    String description = '',
  }) : qty = TextEditingController(text: formatPlain(qty)),
       rate = TextEditingController(text: formatPlain(rate)),
       fixedDiscount = discountAmount > 0,
       discount = TextEditingController(
         text: discountAmount > 0
             ? formatPlain(discountAmount)
             : discountPct > 0
             ? formatPlain(discountPct)
             : '',
       ),
       description = TextEditingController(text: description);

  final String itemId;
  final String name;
  final String unit;
  final double gstRate;
  final TextEditingController qty;
  final TextEditingController rate;
  final TextEditingController discount;
  final TextEditingController description;

  /// The discount is a rupee amount instead of a percentage.
  bool fixedDiscount;

  /// The free-goods line for this line's scheme was already added.
  bool freeAdded = false;

  @override
  TextEditingController get priceRateField => rate;
  @override
  TextEditingController get priceDiscountField => discount;
  @override
  String get priceItemId => itemId;
  @override
  double get priceQty => qtyValue;
  @override
  bool get priceDiscountIsPercent => !fixedDiscount;

  double get qtyValue => parseNumber(qty.text) ?? 0;
  double get rateValue => parseNumber(rate.text) ?? 0;
  double get discountValue => parseNumber(discount.text) ?? 0;

  /// Line amount before tax, as the server will compute it.
  double get taxable {
    final gross = qtyValue * rateValue;
    final off = fixedDiscount ? discountValue : gross * discountValue / 100;
    return (gross - off).clamp(0, double.infinity);
  }

  QuotationLineInput toInput() => QuotationLineInput(
    itemId: itemId,
    qty: qtyValue,
    rate: rateValue,
    discountPct: fixedDiscount ? 0 : discountValue,
    discountAmount: fixedDiscount ? discountValue : 0,
    description: trimmedOrNull(description.text),
  );

  void dispose() {
    qty.dispose();
    rate.dispose();
    discount.dispose();
    description.dispose();
  }
}

/// Creates a quotation or proforma invoice, or edits one (`quotationId`).
/// `partyId`, `dealId` and `contactId` prefill a new one (from the deal page
/// or the customer page).
class QuotationFormScreen extends ConsumerWidget {
  const QuotationFormScreen({
    super.key,
    this.quotationId,
    this.partyId,
    this.dealId,
    this.contactId,
  });

  final String? quotationId;
  final String? partyId;
  final String? dealId;
  final String? contactId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (quotationId == null) {
      return _QuotationForm(
        partyId: partyId,
        dealId: dealId,
        contactId: contactId,
      );
    }
    return AsyncValueView(
      value: ref.watch(quotationProvider(quotationId!)),
      onRetry: () => ref.invalidate(quotationProvider(quotationId!)),
      data: (q) {
        if (!q.isEditable) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            showInfoSnackBar(
              context,
              'Only a draft or sent quotation can be edited.',
            );
            context.go('/quotations/$quotationId');
          });
          return const LoadingView();
        }
        return _QuotationForm(existing: q);
      },
    );
  }
}

class _QuotationForm extends ConsumerStatefulWidget {
  const _QuotationForm({
    this.existing,
    this.partyId,
    this.dealId,
    this.contactId,
  });

  final Quotation? existing;
  final String? partyId;
  final String? dealId;
  final String? contactId;

  @override
  ConsumerState<_QuotationForm> createState() => _QuotationFormState();
}

class _QuotationFormState extends ConsumerState<_QuotationForm>
    with DirtyTracking, ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _notes = TextEditingController();
  final _terms = TextEditingController();
  final List<_Line> _lines = [];
  String _kind = 'quotation';
  String? _locationId;
  String? _partyId;
  String? _partyName;
  String? _contactId;
  String? _dealId;
  DateTime _date = DateTime.now();
  late DateTime _validUntil = _date.add(
    const Duration(days: defaultValidityDays),
  );
  bool _validTouched = false;
  bool _saving = false;
  String? _linesError;
  final _billDiscount = TextEditingController();
  bool _billPercent = false;
  Timer? _priceTimer;

  @override
  void initState() {
    super.initState();
    final q = widget.existing;
    if (q != null) {
      _kind = q.kind;
      _locationId = q.locationId;
      _partyId = q.partyId;
      _partyName = q.partyName;
      _contactId = q.contactId;
      _dealId = q.dealId;
      _notes.text = q.notes ?? '';
      _terms.text = q.terms ?? '';
      _date = DateTime.tryParse(q.quoteDate ?? '') ?? _date;
      _validUntil =
          DateTime.tryParse(q.validUntil ?? '') ??
          _date.add(const Duration(days: defaultValidityDays));
      _validTouched = true;
      for (final l in q.lines) {
        _lines.add(
          _Line(
            itemId: l.itemId,
            name: l.itemName,
            unit: l.unit,
            gstRate: l.gstRate,
            qty: l.qty,
            rate: l.rate,
            discountPct: l.discountPct,
            discountAmount: l.discountAmount,
            description: l.description == l.itemName ? '' : l.description,
          ),
        );
      }
    } else {
      _dealId = widget.dealId;
      _contactId = widget.contactId;
      final pid = widget.partyId;
      if (pid != null) {
        _partyId = pid;
        _loadParty(pid);
      }
    }
  }

  Future<void> _loadParty(String id) async {
    try {
      final p = await ref.read(partiesRepositoryProvider).get(id);
      if (mounted) setState(() => _partyName = p.name);
    } catch (_) {
      // The picker stays usable; the name just shows empty.
    }
  }

  @override
  void dispose() {
    _priceTimer?.cancel();
    _billDiscount.dispose();
    _notes.dispose();
    _terms.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _pickParty() async {
    final p = await pickParty(context, ref, type: PartyType.customer);
    if (p == null || !mounted) return;
    setState(() {
      if (p.id != _partyId) _contactId = null;
      _partyId = p.id;
      _partyName = p.name;
    });
    clearServerError('partyId');
    markDirty();
    _reprice();
  }

  Future<void> _pickDate({required bool validUntil}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: validUntil ? _validUntil : _date,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 3),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (validUntil) {
        _validUntil = picked;
        _validTouched = true;
      } else {
        _date = picked;
        if (!_validTouched) {
          _validUntil = picked.add(const Duration(days: defaultValidityDays));
        }
      }
    });
    markDirty();
  }

  Future<void> _addItem() async {
    final item = await pickItem(context, ref);
    if (item == null || !mounted) return;
    setState(() {
      _lines.add(
        _Line(
          itemId: item.id,
          name: item.name,
          unit: item.unit,
          gstRate: item.gstRate,
          rate: item.salePrice,
        )..autoRate = item.salePrice,
      );
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
    var name = l.name, unit = l.unit, gst = l.gstRate, id = l.itemId;
    if (p.freeItemId != null && p.freeItemId != l.itemId) {
      try {
        final item = await ref.read(itemsRepositoryProvider).get(p.freeItemId!);
        id = item.id;
        name = item.name;
        unit = item.unit;
        gst = item.gstRate;
      } catch (_) {
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      l.freeAdded = true;
      final at = _lines.indexOf(l) + 1;
      _lines.insert(
        at,
        _Line(
          itemId: id,
          name: '$name (free)',
          unit: unit,
          gstRate: gst,
          qty: p.freeQty,
          rate: 0,
          description: '$name, free under scheme',
        ),
      );
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
        qty: l.qtyValue,
        rate: l.rateValue,
        discountPct: l.fixedDiscount ? 0 : l.discountValue,
        discountAmount: l.fixedDiscount ? l.discountValue : 0,
      ),
  ];

  /// Lines to send. A bill discount becomes a fixed discount on every line.
  List<QuotationLineInput> _inputLines() {
    if (_bill.isZero) return [for (final l in _lines) l.toInput()];
    final fixed = fixedDiscounts(_billLines, _bill);
    return [
      for (final (i, l) in _lines.indexed)
        QuotationLineInput(
          itemId: l.itemId,
          qty: l.qtyValue,
          rate: l.rateValue,
          discountPct: 0,
          discountAmount: fixed[i],
          description: trimmedOrNull(l.description.text),
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
    final input = QuotationInput(
      kind: _kind,
      locationId: _locationId!,
      partyId: _partyId!,
      contactId: _contactId,
      dealId: _dealId,
      quoteDate: apiDate(_date),
      validUntil: apiDate(_validUntil),
      notes: trimmedOrNull(_notes.text),
      terms: trimmedOrNull(_terms.text),
      lines: _inputLines(),
    );
    try {
      final repo = ref.read(quotationRepositoryProvider);
      final saved = widget.existing == null
          ? await repo.create(input)
          : await repo.update(
              widget.existing!.id,
              input,
              expectedUpdatedAt: widget.existing!.updatedAt,
            );
      markSaved();
      ref.read(quotationRevisionProvider.notifier).bump();
      if (!mounted) return;
      showInfoSnackBar(
        context,
        '${kindLabel(saved.kind)} ${saved.number} saved',
      );
      context.go('/quotations/${saved.id}');
    } catch (e) {
      if (mounted) {
        showSubmitError(
          e,
          onReload: () {
            markSaved();
            context.go('/quotations/${widget.existing?.id}');
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
    final contacts = _partyId == null
        ? const <ContactPerson>[]
        : ref.watch(partyContactsProvider(_partyId!)).value ??
              const <ContactPerson>[];
    final linesTotal = _lines.fold<double>(0, (a, l) => a + l.taxable);
    final billOff = billDiscountTotal(linesTotal, _bill);
    final subtotal = linesTotal - billOff;
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
                            ? '/quotations/${widget.existing!.id}'
                            : '/quotations',
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
              editing
                  ? 'Edit ${widget.existing!.number}'
                  : 'New ${kindLabel(_kind).toLowerCase()}',
              style: theme.textTheme.headlineSmall,
            ),
            SectionCard(
              title: 'Details',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<String>(
                    key: const ValueKey('kind-toggle'),
                    segments: [
                      for (final e in quotationKinds.entries)
                        ButtonSegment(value: e.key, label: Text(e.value)),
                    ],
                    selected: {_kind},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) {
                      setState(() => _kind = s.first);
                      markDirty();
                    },
                  ),
                  const SizedBox(height: 12),
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
                        label: 'Location',
                        errorText: serverError('locationId'),
                        onChanged: (v) {
                          setState(() => _locationId = v);
                          markDirty();
                        },
                      ),
                    ],
                  ),
                  if (contacts.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    FormRow(
                      children: [
                        DropdownButtonFormField<String?>(
                          initialValue: contacts.any((c) => c.id == _contactId)
                              ? _contactId
                              : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Contact person (optional)',
                          ),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('No contact person'),
                            ),
                            for (final c in contacts)
                              DropdownMenuItem<String?>(
                                value: c.id,
                                child: Text(
                                  c.designation == null
                                      ? c.name
                                      : '${c.name}, ${c.designation}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) {
                            setState(() => _contactId = v);
                            markDirty();
                          },
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  FormRow(
                    children: [
                      PickerField(
                        label: 'Quote date',
                        value: formatDate(_date),
                        icon: Icons.calendar_today_outlined,
                        onTap: () => _pickDate(validUntil: false),
                      ),
                      PickerField(
                        label: 'Valid until',
                        value: formatDate(_validUntil),
                        icon: Icons.calendar_today_outlined,
                        onTap: () => _pickDate(validUntil: true),
                        validator: () =>
                            _validUntil.isBefore(
                              DateTime(_date.year, _date.month, _date.day),
                            )
                            ? 'Must not be before the quote date'
                            : null,
                      ),
                    ],
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
                        'No items yet. Add stock or service items.',
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
                  if (_linesError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _linesError!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  if (_lines.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: BillDiscountField(
                        controller: _billDiscount,
                        isPercent: _billPercent,
                        appliedAmount: billOff,
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
                  if (_lines.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            'Amount before tax (GST is added when saved)',
                            style: theme.textTheme.bodySmall,
                          ),
                          MoneyText(
                            subtotal,
                            style: theme.textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            SectionCard(
              title: 'Notes and terms',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _notes,
                    maxLines: 2,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                    ),
                  ),
                  TextFormField(
                    controller: _terms,
                    maxLines: 4,
                    maxLength: 2000,
                    decoration: const InputDecoration(
                      labelText: 'Terms (optional)',
                      helperText: 'Payment, delivery and warranty terms',
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
    Widget field(
      TextEditingController c,
      String label, {
      bool required = false,
      int decimals = 2,
      Widget? suffix,
    }) => TextFormField(
      controller: c,
      keyboardType: decimalKeyboard,
      inputFormatters: <TextInputFormatter>[decimalInput(decimals: decimals)],
      decoration: InputDecoration(labelText: label, suffixIcon: suffix),
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
                child: Text(
                  '${line.name} (GST ${formatPercent(line.gstRate)})',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              IconButton(
                tooltip: context.w('Remove item'),
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FormRow(
            breakpoint: 480,
            children: [
              field(
                line.qty,
                'Quantity (${line.unit})',
                required: true,
                decimals: 3,
              ),
              field(line.rate, 'Rate'),
              field(
                line.discount,
                line.fixedDiscount ? 'Discount amount' : 'Discount %',
                suffix: IconButton(
                  tooltip: line.fixedDiscount
                      ? 'Switch to percentage'
                      : 'Switch to fixed amount',
                  onPressed: () {
                    line.fixedDiscount = !line.fixedDiscount;
                    onChanged();
                  },
                  icon: Text(
                    line.fixedDiscount ? moneySymbol : '%',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
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
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: MoneyText(line.taxable, style: theme.textTheme.bodyMedium),
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}
