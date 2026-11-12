import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../documents/line_editor.dart';
import '../items/item_model.dart';
import '../items/item_picker.dart';
import '../locations/location_filter.dart';
import '../locations/locations_repository.dart';
import '../parties/parties_repository.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'po_models.dart';
import 'po_repository.dart';

/// New purchase order, or edit of a draft (`poId`), with live totals from
/// `POST /purchase-orders/preview`.
class PoFormScreen extends ConsumerStatefulWidget {
  const PoFormScreen({super.key, this.poId, this.initialPartyId});

  final String? poId;
  final String? initialPartyId;

  @override
  ConsumerState<PoFormScreen> createState() => _PoFormScreenState();
}

class _PoFormScreenState extends ConsumerState<PoFormScreen>
    with
        LivePreview<PoFormScreen, PoDraft, PurchaseOrder>,
        DirtyTracking<PoFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _notes = TextEditingController();
  final List<LineDraft> _lines = [];
  String? _locationId;
  Party? _party;
  DateTime _orderDate = DateUtils.dateOnly(DateTime.now());
  DateTime? _expectedDate;

  bool _loading = false;
  Object? _loadError;
  bool _saving = false;
  Object? _saveError;
  Map<String, String> _fieldErrors = const {};
  Map<int, Map<String, String>> _lineErrors = const {};

  DateTime? _loadedAt;
  bool get _editing => widget.poId != null;

  @override
  void initState() {
    super.initState();
    if (_editing) {
      _loading = true;
      _load();
    } else if (widget.initialPartyId != null) {
      _loadParty(widget.initialPartyId!);
    }
  }

  Future<void> _loadParty(String id) async {
    try {
      final party = await ref.read(partiesRepositoryProvider).get(id);
      if (mounted && party.isVendor) {
        setState(() => _party = party);
        schedulePreview();
      }
    } catch (_) {
      // The user can still pick the vendor by hand.
    }
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(poRepositoryProvider);
      final po = await repo.get(widget.poId!);
      _loadedAt = po.updatedAt;
      if (!po.isDraft) {
        if (!mounted) return;
        showInfoSnackBar(context, 'Only a draft purchase order can be edited.');
        context.go('/purchase-orders/${widget.poId}');
        return;
      }
      final party = await ref.read(partiesRepositoryProvider).get(po.partyId);
      if (!mounted) return;
      setState(() {
        _locationId = po.locationId;
        _party = party;
        _orderDate = DateTime.tryParse(po.orderDate ?? '') ?? _orderDate;
        _expectedDate = DateTime.tryParse(po.expectedDate ?? '');
        _notes.text = po.notes ?? '';
        for (final l in po.lines ?? const <PoLine>[]) {
          final draft = LineDraft(
            Item(
              id: l.itemId,
              companyId: '',
              name: l.itemName,
              sku: l.sku,
              unit: l.unit,
              gstRate: l.gstRate,
              salePrice: 0,
              purchasePrice: l.rate,
            ),
            defaultRate: l.rate,
          );
          draft.qty.text = formatPlain(l.qty);
          if (l.discountPct > 0) {
            draft.discount.text = formatPlain(l.discountPct);
          }
          _lines.add(draft);
        }
        _loading = false;
      });
      schedulePreview();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = e;
          _loading = false;
        });
      }
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
  PoDraft? buildDraft() {
    final location = _locationId;
    final party = _party;
    if (location == null || party == null || _lines.isEmpty) return null;
    if (_lines.any((l) => !l.isValid)) return null;
    final expected = _expectedDate;
    return PoDraft(
      locationId: location,
      partyId: party.id,
      orderDate: apiDate(_orderDate),
      expectedDate: expected == null ? null : apiDate(expected),
      notes: trimmedOrNull(_notes.text),
      lines: [for (final line in _lines) line.toDraft()],
    );
  }

  @override
  Future<PurchaseOrder> fetchPreview(PoDraft draft) =>
      ref.read(poRepositoryProvider).preview(draft);

  void _clearError(String field) {
    if (_fieldErrors.containsKey(field)) {
      setState(() => _fieldErrors = Map.of(_fieldErrors)..remove(field));
    }
  }

  Future<void> _pickParty() async {
    final party = await pickParty(context, ref, type: PartyType.vendor);
    if (party == null) return;
    if (mounted) setState(() => _party = party);
    markDirty();
    _clearError('partyId');
    schedulePreview();
  }

  Future<void> _addLine() async {
    final item = await pickItem(context, ref);
    if (item == null) return;
    if (mounted) {
      setState(
        () => _lines.add(LineDraft(item, defaultRate: item.purchasePrice)),
      );
    }
    markDirty();
    schedulePreview();
  }

  void _removeLine(LineDraft line) {
    setState(() {
      _lines.remove(line);
      _lineErrors = const {};
    });
    line.dispose();
    markDirty();
    schedulePreview();
  }

  Future<void> _pickOrderDate() async {
    final picked = await pickDocDate(context, _orderDate);
    if (picked == null) return;
    if (mounted) setState(() => _orderDate = picked);
    markDirty();
    schedulePreview();
  }

  Future<void> _pickExpectedDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _expectedDate ?? today,
      firstDate: _orderDate,
      lastDate: today.add(const Duration(days: 730)),
    );
    if (picked == null) return;
    if (mounted) setState(() => _expectedDate = picked);
    markDirty();
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
      showInfoSnackBar(context, 'Add at least one item.');
      return;
    }
    final draft = buildDraft();
    if (!valid || draft == null) return;
    cancelPreview();
    setState(() => _saving = true);
    try {
      final repo = ref.read(poRepositoryProvider);
      final po = _editing
          ? await repo.update(widget.poId!, draft, expectedUpdatedAt: _loadedAt)
          : await repo.create(draft);
      ref.bump(poKinds);
      markSaved();
      if (!mounted) return;
      showInfoSnackBar(context, 'Order ${po.number ?? ''} saved');
      context.go('/purchase-orders/${po.id}');
    } catch (e) {
      if (!mounted) return;
      final (header, lines) = splitFieldErrors(e);
      setState(() {
        _saveError = e;
        _fieldErrors = header;
        _lineErrors = lines;
      });
      if (apiError(e)?.code == ApiException.staleEdit) {
        showErrorSnackBar(
          context,
          e,
          actionLabel: 'Reload',
          onAction: () {
            markSaved();
            context.go('/purchase-orders/${widget.poId}');
          },
        );
      } else {
        showErrorSnackBar(context, e);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_loadError != null) {
      return ErrorView(
        error: _loadError!,
        onRetry: () {
          setState(() {
            _loading = true;
            _loadError = null;
          });
          _load();
        },
      );
    }
    return track(_buildBody(context));
  }

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
                label: 'Deliver to',
                errorText: _fieldErrors['locationId'],
                onChanged: (v) {
                  setState(() => _locationId = v);
                  markDirty();
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
                label: 'Order date',
                value: formatDate(_orderDate),
                icon: Icons.calendar_today_outlined,
                errorText: _fieldErrors['orderDate'],
                onTap: _pickOrderDate,
              ),
              PickerField(
                label: 'Expected delivery (optional)',
                value: _expectedDate == null ? null : formatDate(_expectedDate),
                icon: Icons.event_outlined,
                errorText: _fieldErrors['expectedDate'],
                onTap: _pickExpectedDate,
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _notes,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: 'Notes (optional)',
              errorText: _fieldErrors['notes'],
            ),
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
          label: 'Save order',
        ),
        title: _editing ? 'Edit purchase order' : 'New purchase order',
        main: [
          details,
          DocLinesSection(
            lines: _lines,
            previewLines: preview?.taxLines,
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
            hideSave: true,
            ready: buildDraft() != null,
            preview: preview,
            previewError: previewError,
            previewing: previewing,
            saveError: _saveError,
            saving: _saving,
            onSave: _save,
            saveLabel: 'Save order',
            subject: 'the order',
            hint:
                'Choose a location, a vendor and at least one item to see '
                'the totals.',
          ),
        ),
      ),
    );
  }
}
