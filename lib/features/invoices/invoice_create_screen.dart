import 'dart:async';

import '../stock_tools/unit_picker.dart';
import '../controls/cost_centre_widgets.dart';
import '../controls/custom_fields_section.dart';
import 'package:flutter/material.dart';
import '../../core/permissions.dart';
import '../auth/session.dart';
import '../documents/credit_limit_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/business_profile.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../documents/document_models.dart' show DraftLine;
import '../documents/line_editor.dart';
import '../items/items_repository.dart';
import '../pricing/bill_discount.dart';
import '../pricing/price_prefill.dart';
import '../items/item_picker.dart';
import '../locations/location_filter.dart';
import '../locations/locations_repository.dart';
import '../parties/parties_repository.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import '../export_currency/export_fields_card.dart';
import '../export_currency/export_models.dart';
import 'invoice_model.dart';
import 'invoices_repository.dart';
import '../../widgets/busy.dart';

/// New sales invoice with live totals from `POST /invoices/preview`.
class InvoiceCreateScreen extends ConsumerStatefulWidget {
  const InvoiceCreateScreen({super.key, this.initialPartyId});

  /// Pre-selects the customer (e.g. from the party page).
  final String? initialPartyId;

  @override
  ConsumerState<InvoiceCreateScreen> createState() =>
      _InvoiceCreateScreenState();
}

class _InvoiceCreateScreenState extends ConsumerState<InvoiceCreateScreen>
    with
        LivePreview<InvoiceCreateScreen, InvoiceDraft, Invoice>,
        DirtyTracking<InvoiceCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _notes = TextEditingController();
  final _billDiscount = TextEditingController();
  bool _billPercent = false;
  Timer? _priceTimer;
  String? _costCentreId;
  Json _custom = const {};
  Json _exportExtra = const {};
  final List<LineDraft> _lines = [];
  String? _locationId;
  Party? _party;
  DateTime _date = DateUtils.dateOnly(DateTime.now());

  bool _saving = false;
  Object? _saveError;
  Map<String, String> _fieldErrors = const {};
  Map<int, Map<String, String>> _lineErrors = const {};

  @override
  void initState() {
    super.initState();
    final partyId = widget.initialPartyId;
    if (partyId != null) _loadParty(partyId);
  }

  Future<void> _loadParty(String id) async {
    try {
      final party = await ref.read(partiesRepositoryProvider).get(id);
      if (mounted && party.isCustomer) {
        setState(() => _party = party);
        schedulePreview();
      }
    } catch (_) {
      // The user can still pick the customer by hand.
    }
  }

  @override
  void dispose() {
    _priceTimer?.cancel();
    _billDiscount.dispose();
    _notes.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  @override
  InvoiceDraft? buildDraft() {
    final location = _locationId;
    final party = _party;
    if (location == null || party == null || _lines.isEmpty) return null;
    if (_lines.any((l) => !l.isValid)) return null;
    return InvoiceDraft(
      locationId: location,
      partyId: party.id,
      invoiceDate: apiDate(_date),
      notes: trimmedOrNull(_notes.text),
      costCentreId: _costCentreId,
      custom: _custom,
      extra: _exportExtra,
      lines: _draftLines(),
    );
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

  /// A bill discount becomes a fixed discount on every line, so GST is
  /// charged on the reduced value.
  List<DraftLine> _draftLines() {
    if (_bill.isZero) return [for (final line in _lines) line.toDraft()];
    final fixed = fixedDiscounts(_billLines, _bill);
    return [
      for (final (i, line) in _lines.indexed)
        DraftLine(
          itemId: line.item.id,
          qty: parseNumber(line.qty.text)!,
          rate: parseNumber(line.rate.text) ?? 0,
          discountAmount: fixed[i],
          unit: line.unit,
        ),
    ];
  }

  /// Fills rates and scheme discounts from price lists, customer prices and schemes.
  Future<void> _reprice() async {
    final ok = await repriceLines(ref, _party?.id, _lines);
    if (ok && mounted) {
      setState(() {});
      schedulePreview();
    }
  }

  void _linesChanged() {
    schedulePreview();
    _priceTimer?.cancel();
    _priceTimer = Timer(const Duration(milliseconds: 500), _reprice);
  }

  /// Adds the scheme's free goods as a separate zero-rate line.
  Future<void> _addFree(LineDraft l) async {
    final p = l.resolved;
    if (p == null || p.freeQty <= 0) return;
    var item = l.item;
    if (p.freeItemId != null && p.freeItemId != l.item.id) {
      try {
        item = await ref.read(itemsRepositoryProvider).get(p.freeItemId!);
      } catch (_) {
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      l.freeAdded = true;
      final free = LineDraft(item, defaultRate: 0);
      free.qty.text = formatPlain(p.freeQty);
      _lines.insert(_lines.indexOf(l) + 1, free);
    });
    markDirty();
    schedulePreview();
  }

  @override
  Future<Invoice> fetchPreview(InvoiceDraft draft) =>
      ref.read(invoicesRepositoryProvider).preview(draft);

  Future<void> _pickParty() async {
    final party = await pickParty(context, ref, type: PartyType.customer);
    if (party == null) return;
    if (mounted) {
      setState(() {
        _party = party;
        _fieldErrors = Map.of(_fieldErrors)..remove('partyId');
      });
    }
    schedulePreview();
    _reprice();
  }

  Future<void> _addLine() async {
    final item = await pickItem(context, ref);
    if (item == null) return;
    final (unit, factor) = await defaultUnitFor(ref, item.id, purchase: false);
    if (mounted) {
      final line = LineDraft(item, defaultRate: item.salePrice)
        ..autoRate = item.salePrice;
      if (unit != null) {
        line.unit = unit;
        line.rate.text = scaleRateText(line.rate.text, factor);
      }
      setState(() => _lines.add(line));
    }
    schedulePreview();
    _reprice();
  }

  void _removeLine(LineDraft line) {
    setState(() {
      _lines.remove(line);
      _lineErrors = const {};
    });
    line.dispose();
    schedulePreview();
  }

  Future<void> _pickDate() async {
    final picked = await pickDocDate(context, _date);
    if (picked == null) return;
    if (mounted) setState(() => _date = picked);
    schedulePreview();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saveError = null;
      _fieldErrors = const {};
      _lineErrors = const {};
    });
    final valid = validateAndReveal(_formKey);
    if (_lines.isEmpty) {
      markSaved();
      showInfoSnackBar(context, 'Add at least one item.');
      return;
    }
    final draft = buildDraft();
    if (!valid || draft == null) return;
    cancelPreview();
    setState(() => _saving = true);
    try {
      Invoice invoice;
      try {
        invoice = await ref.read(invoicesRepositoryProvider).create(draft);
      } catch (e) {
        final limit = creditLimitError(e);
        if (limit == null || !mounted) rethrow;
        final billAnyway = await confirmCreditLimit(
          context,
          limit,
          canOverride: ref
              .read(permissionsProvider)
              .can(Perm.partiesCreditOverride),
          document: 'invoice',
        );
        if (!billAnyway || !mounted) {
          setState(() => _saving = false);
          return;
        }
        invoice = await ref
            .read(invoicesRepositoryProvider)
            .create(draft.withOverLimit());
      }
      ref.bump(const [DataKind.invoices, DataKind.stock, DataKind.parties]);
      if (!mounted) return;
      showInfoSnackBar(context, 'Invoice ${invoice.number ?? ''} saved');
      context.go('/invoices/${invoice.id}');
    } catch (e) {
      if (!mounted) return;
      final (header, lines) = splitFieldErrors(e);
      setState(() {
        _saveError = e;
        _fieldErrors = header;
        _lineErrors = lines;
      });
      showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    // Default to the only location when there is just one.
    final locations = ref.watch(locationsLookupProvider).value;
    if (_locationId == null && locations != null) {
      final active = locations.where((l) => l.isActive).toList();
      if (active.length == 1) _locationId = active.single.id;
    }

    final details = SectionCard(
      title: 'Details',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormRow(
            children: [
              LocationField(
                value: _locationId,
                label: context.w('Billing location'),
                errorText: _fieldErrors['locationId'],
                onChanged: (v) {
                  setState(() {
                    _locationId = v;
                    _fieldErrors = Map.of(_fieldErrors)..remove('locationId');
                  });
                  schedulePreview();
                },
              ),
              PickerField(
                label: context.w('Customer'),
                value: _party?.name,
                onTap: _pickParty,
                errorText: _fieldErrors['partyId'],
                validator: () =>
                    _party == null ? context.w('Choose a customer') : null,
              ),
            ],
          ),
          if (_party != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                partySummary(_party!),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 16),
          FormRow(
            children: [
              PickerField(
                label: context.w('Invoice date'),
                value: formatDate(_date),
                icon: Icons.calendar_today_outlined,
                errorText: _fieldErrors['invoiceDate'],
                onTap: _pickDate,
              ),
              CostCentreField(
                value: _costCentreId,
                errorText: _fieldErrors['costCentreId'],
                onChanged: (v) => setState(() {
                  _costCentreId = v;
                  markDirty();
                }),
              ),
              TextFormField(
                controller: _notes,
                decoration: InputDecoration(
                  labelText: 'Notes (optional)',
                  errorText: _fieldErrors['notes'],
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return Form(
      key: _formKey,
      onChanged: markDirty,
      child: DocFormLayout(
        bottomBar: DocSaveBar(
          busy: _saving,
          onPressed: _save,
          label: context.w('Save invoice'),
        ),
        title: context.w('New invoice'),
        main: [
          details,
          ExportFieldsCard(
            invoiceDate: apiDate(_date),
            onChanged: (ExportChoice c) {
              _exportExtra = c.toJson();
              markDirty();
              schedulePreview();
            },
          ),
          CustomFieldsSection(
            entity: 'invoice',
            values: _custom,
            errors: _fieldErrors,
            onChanged: (v) => setState(() {
              _custom = v;
              markDirty();
            }),
          ),
          DocLinesSection(
            lines: _lines,
            previewLines: preview?.lines,
            lineErrors: _lineErrors,
            enabled: !_saving,
            onChanged: _linesChanged,
            onRemove: _removeLine,
            onAdd: _addLine,
            onAddFree: _addFree,
          ),
          if (_lines.isNotEmpty)
            SectionCard(
              title: 'Discount on bill',
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
                  schedulePreview();
                },
                onChanged: () {
                  markDirty();
                  schedulePreview();
                },
              ),
            ),
        ],
        summary: SectionCard(
          title: 'Summary',
          child: DocSummaryPanel(
            hideSave: true,
            ready: buildDraft() != null,
            preview: preview,
            previewError: previewError,
            previewing: previewing,
            saveError: _saveError,
            saving: _saving,
            onSave: _save,
            saveLabel: 'Save invoice',
            subject: 'the invoice',
            hint:
                'Choose a location, a customer and at least one item to see '
                'the totals.',
          ),
        ),
      ),
    );
  }
}
