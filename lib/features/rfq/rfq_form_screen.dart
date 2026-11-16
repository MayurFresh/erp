import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_picker.dart';
import '../../widgets/states.dart';
import '../items/item_picker.dart';
import '../locations/location_filter.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'rfq_models.dart';
import 'rfq_repository.dart';

class _LineDraft {
  _LineDraft(this.itemId, this.name, this.unit, double qty)
    : qty = TextEditingController(text: qty == 0 ? '' : '$qty');
  final String itemId;
  final String name;
  final String unit;
  final TextEditingController qty;
}

/// New request for quotation, or edit of a draft (`rfqId`).
class RfqFormScreen extends ConsumerStatefulWidget {
  const RfqFormScreen({super.key, this.rfqId});

  final String? rfqId;

  @override
  ConsumerState<RfqFormScreen> createState() => _State();
}

class _State extends ConsumerState<RfqFormScreen> {
  String? _locationId;
  String? _indentId;
  String? _indentNumber;
  DateTime? _due;
  final _notes = TextEditingController();
  final List<({String id, String name})> _vendors = [];
  final List<_LineDraft> _lines = [];
  String? _error;
  bool _busy = false;
  bool _loaded = false;

  @override
  void dispose() {
    _notes.dispose();
    for (final l in _lines) {
      l.qty.dispose();
    }
    super.dispose();
  }

  void _load(Rfq r) {
    if (_loaded) return;
    _loaded = true;
    _locationId = r.locationId;
    _indentId = r.indentId;
    _due = r.dueDate == null ? null : DateTime.tryParse(r.dueDate!);
    _notes.text = r.notes ?? '';
    _vendors.addAll([for (final v in r.vendors) (id: v.partyId, name: v.partyName)]);
    _lines.addAll([
      for (final l in r.lines) _LineDraft(l.itemId, l.itemName, l.unit, l.qty),
    ]);
  }

  Future<void> _addVendor() async {
    final p = await pickParty(context, ref, type: PartyType.vendor);
    if (p == null || _vendors.any((v) => v.id == p.id)) return;
    setState(() => _vendors.add((id: p.id, name: p.name)));
  }

  Future<void> _addItem() async {
    final item = await pickItem(context, ref);
    if (item == null) return;
    setState(() => _lines.add(_LineDraft(item.id, item.name, item.unit, 1)));
  }

  Future<void> _fromIndent() async {
    final repo = ref.read(rfqRepositoryProvider);
    final picked = await showSearchPicker<Json>(
      context: context,
      title: 'Choose an approved indent',
      hintText: 'Search number',
      emptyMessage: 'No approved indents.',
      search: repo.approvedIndents,
      titleBuilder: (_, d) => Text(asString(d['number'])),
    );
    if (picked == null) return;
    setState(() {
      _indentId = asString(picked['id']);
      _indentNumber = asString(picked['number']);
      _locationId ??= asStringOrNull(picked['locationId']);
      _lines.clear();
    });
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _due ?? now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d != null) setState(() => _due = d);
  }

  Future<void> _save() async {
    if (_vendors.isEmpty) {
      setState(() => _error = 'Choose at least one vendor.');
      return;
    }
    if (_lines.isEmpty && _indentId == null) {
      setState(() => _error = 'Add an item or start from an indent.');
      return;
    }
    for (final l in _lines) {
      if ((double.tryParse(l.qty.text) ?? 0) <= 0) {
        setState(() => _error = 'Enter a quantity for ${l.name}.');
        return;
      }
    }
    if (_locationId == null && _indentId == null) {
      setState(() => _error = 'Choose a location.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final body = <String, Object?>{
      if (_locationId != null) 'locationId': _locationId,
      'vendorIds': [for (final v in _vendors) v.id],
      if (_due != null) 'dueDate': apiDate(_due!) else 'dueDate': null,
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
      if (_indentId != null) 'indentId': _indentId,
      if (_lines.isNotEmpty)
        'lines': [
          for (final l in _lines)
            {'itemId': l.itemId, 'qty': double.parse(l.qty.text)},
        ],
    };
    try {
      final repo = ref.read(rfqRepositoryProvider);
      final r = widget.rfqId == null
          ? await repo.create(body)
          : await repo.update(widget.rfqId!, body);
      ref.bump(const [DataKind.purchases]);
      if (mounted) context.go('/rfqs/${r.id}');
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _form() => FormPage(
    children: [
      PageHeader(
        title: widget.rfqId == null ? 'New request for quotation' : 'Edit request',
      ),
      SectionCard(
        title: 'Details',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LocationField(
              value: _locationId,
              label: 'Deliver to',
              onChanged: (v) => setState(() => _locationId = v),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _pickDue,
              icon: const Icon(Icons.event_outlined),
              label: Text(
                _due == null ? 'Reply by (optional)' : 'Reply by ${formatDate(_due)}',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      SectionCard(
        title: 'Vendors',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final v in _vendors)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(v.name),
                trailing: IconButton(
                  tooltip: 'Remove ${v.name}',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _vendors.remove(v)),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addVendor,
                icon: const Icon(Icons.add),
                label: const Text('Add vendor'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      SectionCard(
        title: 'Items',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_indentId != null && _lines.isEmpty)
              Text(
                'Lines come from indent ${_indentNumber ?? ''}. Add items '
                'below to use your own list instead.',
              ),
            for (final l in _lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(child: Text(l.name)),
                    SizedBox(
                      width: 96,
                      child: TextField(
                        controller: l.qty,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Qty (${l.unit})',
                          isDense: true,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove ${l.name}',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _lines.remove(l)),
                    ),
                  ],
                ),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _addItem,
                  icon: const Icon(Icons.add),
                  label: const Text('Add item'),
                ),
                if (widget.rfqId == null)
                  OutlinedButton.icon(
                    onPressed: _fromIndent,
                    icon: const Icon(Icons.playlist_add_check),
                    label: const Text('From approved indent'),
                  ),
              ],
            ),
          ],
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy ? null : _save,
          child: const Text('Save request'),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final id = widget.rfqId;
    if (id == null) return _form();
    return AsyncValueView<Rfq>(
      value: ref.watch(rfqProvider(id)),
      onRetry: () => ref.invalidate(rfqProvider(id)),
      data: (r) {
        _load(r);
        return _form();
      },
    );
  }
}
