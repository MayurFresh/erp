import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../documents/line_editor.dart';
import '../items/item_picker.dart';
import '../locations/location_filter.dart';
import '../locations/locations_repository.dart';
import '../parties/parties_repository.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
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
      lines: [for (final line in _lines) line.toDraft()],
    );
  }

  @override
  Future<Invoice> fetchPreview(InvoiceDraft draft) =>
      ref.read(invoicesRepositoryProvider).preview(draft);

  Future<void> _pickParty() async {
    final party = await pickParty(context, ref, type: PartyType.customer);
    if (party == null) return;
    setState(() {
      _party = party;
      _fieldErrors = Map.of(_fieldErrors)..remove('partyId');
    });
    schedulePreview();
  }

  Future<void> _addLine() async {
    final item = await pickItem(context, ref);
    if (item == null) return;
    setState(() => _lines.add(LineDraft(item, defaultRate: item.salePrice)));
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

  Future<void> _pickDate() async {
    final picked = await pickDocDate(context, _date);
    if (picked == null) return;
    setState(() => _date = picked);
    schedulePreview();
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
      final invoice = await ref.read(invoicesRepositoryProvider).create(draft);
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
                label: 'Billing location',
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
                label: 'Customer',
                value: _party?.name,
                onTap: _pickParty,
                errorText: _fieldErrors['partyId'],
                validator: () => _party == null ? 'Choose a customer' : null,
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
                label: 'Invoice date',
                value: formatDate(_date),
                icon: Icons.calendar_today_outlined,
                errorText: _fieldErrors['invoiceDate'],
                onTap: _pickDate,
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
        title: 'New invoice',
        main: [
          details,
          DocLinesSection(
            lines: _lines,
            previewLines: preview?.lines,
            lineErrors: _lineErrors,
            enabled: !_saving,
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
