import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../documents/line_editor.dart';
import '../items/item_picker.dart';
import '../locations/location_filter.dart';
import '../locations/locations_repository.dart';
import '../parties/parties_repository.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import '../tax/tax_pickers.dart';
import '../tax/tds_preview_card.dart';
import 'purchase_model.dart';
import 'purchases_repository.dart';
import '../../widgets/busy.dart';

/// New purchase bill with live totals from `POST /purchases/preview`.
class PurchaseCreateScreen extends ConsumerStatefulWidget {
  const PurchaseCreateScreen({super.key, this.initialPartyId});

  /// Pre-selects the vendor (e.g. from the party page).
  final String? initialPartyId;

  @override
  ConsumerState<PurchaseCreateScreen> createState() =>
      _PurchaseCreateScreenState();
}

class _PurchaseCreateScreenState extends ConsumerState<PurchaseCreateScreen>
    with
        LivePreview<PurchaseCreateScreen, PurchaseDraft, Purchase>,
        DirtyTracking<PurchaseCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _supplierInvoiceNo = TextEditingController();
  final _notes = TextEditingController();
  final List<LineDraft> _lines = [];
  String? _locationId;
  Party? _party;
  DateTime _billDate = DateUtils.dateOnly(DateTime.now());
  DateTime? _supplierInvoiceDate;
  String? _tdsSectionId;
  bool _tdsTouched = false;
  bool _reverseCharge = false;

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
      if (mounted && party.isVendor) {
        setState(() {
          _party = party;
          if (!_tdsTouched) _tdsSectionId = party.tdsSectionId;
        });
        schedulePreview();
      }
    } catch (_) {
      // The user can still pick the vendor by hand.
    }
  }

  @override
  void dispose() {
    _supplierInvoiceNo.dispose();
    _notes.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  @override
  PurchaseDraft? buildDraft() {
    final location = _locationId;
    final party = _party;
    if (location == null || party == null || _lines.isEmpty) return null;
    if (_lines.any((l) => !l.isValid)) return null;
    final supplierDate = _supplierInvoiceDate;
    return PurchaseDraft(
      locationId: location,
      partyId: party.id,
      billDate: apiDate(_billDate),
      supplierInvoiceNo: trimmedOrNull(_supplierInvoiceNo.text),
      supplierInvoiceDate: supplierDate == null ? null : apiDate(supplierDate),
      notes: trimmedOrNull(_notes.text),
      tdsSectionId: _tdsSectionId,
      reverseCharge: _reverseCharge,
      lines: [for (final line in _lines) line.toDraft()],
    );
  }

  @override
  Future<Purchase> fetchPreview(PurchaseDraft draft) =>
      ref.read(purchasesRepositoryProvider).preview(draft);

  void _clearError(String field) {
    if (_fieldErrors.containsKey(field)) {
      setState(() => _fieldErrors = Map.of(_fieldErrors)..remove(field));
    }
  }

  Future<void> _pickParty() async {
    final party = await pickParty(context, ref, type: PartyType.vendor);
    if (party == null) return;
    setState(() {
      _party = party;
      if (!_tdsTouched) _tdsSectionId = party.tdsSectionId;
    });
    _clearError('partyId');
    schedulePreview();
  }

  Future<void> _addLine() async {
    final item = await pickItem(context, ref);
    if (item == null) return;
    // Without items.view_cost the price is absent and the server applies it.
    setState(
      () => _lines.add(LineDraft(item, defaultRate: item.purchasePrice)),
    );
    schedulePreview();
  }

  void _removeLine(LineDraft line) {
    setState(() {
      _lines.remove(line);
      _lineErrors = const {};
    });
    line.dispose();
    schedulePreview();
  }

  Future<void> _pickBillDate() async {
    final picked = await pickDocDate(context, _billDate);
    if (picked == null) return;
    setState(() => _billDate = picked);
    schedulePreview();
  }

  Future<void> _pickSupplierDate() async {
    final picked = await pickDocDate(
      context,
      _supplierInvoiceDate ?? _billDate,
    );
    if (picked != null) setState(() => _supplierInvoiceDate = picked);
  }

  Future<void> _save() async {
    setState(() {
      _saveError = null;
      _fieldErrors = const {};
      _lineErrors = const {};
    });
    final valid = _formKey.currentState!.validate();
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
      final bill = await ref.read(purchasesRepositoryProvider).create(draft);
      ref.bump(const [DataKind.purchases, DataKind.stock, DataKind.parties]);
      if (!mounted) return;
      showInfoSnackBar(context, 'Bill ${bill.number ?? ''} saved');
      context.go('/purchases/${bill.id}');
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
    final locations = ref.watch(locationsLookupProvider).value;
    if (_locationId == null && locations != null) {
      final active = locations.where((l) => l.isActive).toList();
      if (active.length == 1) _locationId = active.single.id;
    }
    final showCost = ref.watch(permissionsProvider).can(Perm.itemsViewCost);

    final details = SectionCard(
      title: 'Details',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormRow(
            children: [
              LocationField(
                value: _locationId,
                label: 'Receiving location',
                errorText: _fieldErrors['locationId'],
                onChanged: (v) {
                  setState(() => _locationId = v);
                  _clearError('locationId');
                  schedulePreview();
                },
              ),
              PickerField(
                label: 'Vendor',
                value: _party?.name,
                onTap: _pickParty,
                errorText: _fieldErrors['partyId'],
                validator: () => _party == null ? 'Choose a vendor' : null,
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
                label: 'Bill date',
                value: formatDate(_billDate),
                icon: Icons.calendar_today_outlined,
                errorText: _fieldErrors['billDate'],
                onTap: _pickBillDate,
              ),
              TextFormField(
                controller: _supplierInvoiceNo,
                decoration: InputDecoration(
                  labelText: 'Supplier invoice no. (optional)',
                  errorText: _fieldErrors['supplierInvoiceNo'],
                ),
                onChanged: (_) => _clearError('supplierInvoiceNo'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FormRow(
            children: [
              PickerField(
                label: 'Supplier invoice date (optional)',
                value: _supplierInvoiceDate == null
                    ? null
                    : formatDate(_supplierInvoiceDate),
                icon: Icons.event_outlined,
                errorText: _fieldErrors['supplierInvoiceDate'],
                onTap: _pickSupplierDate,
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
        title: 'New purchase bill',
        main: [
          details,
          SectionCard(
            title: 'TDS and reverse charge',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TdsSectionPicker(
                  value: _tdsSectionId,
                  date: apiDate(_billDate),
                  enabled: !_saving,
                  errorText: _fieldErrors['tdsSectionId'],
                  onChanged: (s) {
                    setState(() {
                      _tdsSectionId = s?.id;
                      _tdsTouched = true;
                    });
                    schedulePreview();
                  },
                ),
                TdsPreviewCard(
                  partyId: _party?.id,
                  sectionId: _tdsSectionId,
                  date: apiDate(_billDate),
                  gross: preview?.subtotal,
                  documentTotal: preview?.total,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Reverse charge (RCM)'),
                  subtitle: const Text(
                    'The supplier charges no GST. You pay the tax directly '
                    'and a self-invoice number is issued.',
                  ),
                  value: _reverseCharge,
                  onChanged: _saving
                      ? null
                      : (v) {
                          setState(() => _reverseCharge = v);
                          schedulePreview();
                        },
                ),
              ],
            ),
          ),
          DocLinesSection(
            lines: _lines,
            previewLines: preview?.lines,
            lineErrors: _lineErrors,
            enabled: !_saving,
            rateHint: showCost ? null : 'Item cost',
            onChanged: schedulePreview,
            onRemove: _removeLine,
            onAdd: _addLine,
          ),
        ],
        summary: SectionCard(
          title: 'Summary',
          child: DocSummaryPanel(
            ready: buildDraft() != null,
            preview: preview,
            previewError: previewError,
            previewing: previewing,
            saveError: _saveError,
            saving: _saving,
            onSave: _save,
            saveLabel: 'Save bill',
            subject: 'the bill',
            hint:
                'Choose a location, a vendor and at least one item to see '
                'the totals.',
          ),
        ),
      ),
    );
  }
}
