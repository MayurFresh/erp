import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../widgets/form_support.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../../items/item_model.dart';
import '../../items/item_picker.dart';
import '../common/boq_picker.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../models/material_models.dart';
import '../../../widgets/busy.dart';

/// Creates an indent, or replaces all editable content of a draft/rejected one.
class IndentFormScreen extends ConsumerStatefulWidget {
  const IndentFormScreen({super.key, this.indentId, this.initialLocationId});

  final String? indentId;
  final String? initialLocationId;

  @override
  ConsumerState<IndentFormScreen> createState() => _IndentFormScreenState();
}

class _IndentFormScreenState extends ConsumerState<IndentFormScreen>
    with DirtyTracking<IndentFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _notes = TextEditingController();
  final List<_IndentLineRow> _lines = [];
  String? _locationId;
  DateTime? _requiredBy;
  bool _loading = false;
  bool _busy = false;
  Indent? _original;

  bool get _editing => widget.indentId != null;

  @override
  void initState() {
    super.initState();
    _locationId = widget.initialLocationId;
    final id = widget.indentId;
    if (id != null) _load(id);
  }

  @override
  void dispose() {
    _notes.dispose();
    for (final line in _lines) {
      line.qty.dispose();
    }
    super.dispose();
  }

  Future<void> _load(String id) async {
    setState(() => _loading = true);
    try {
      final indent = await ref.read(constructionRepositoryProvider).indent(id);
      if (!mounted) return;
      setState(() {
        _original = indent;
        _locationId = indent.locationId;
        _requiredBy = parseApiDate(indent.requiredBy);
        _notes.text = indent.notes ?? '';
        _lines
          ..clear()
          ..addAll(indent.lines.map(_IndentLineRow.fromModel));
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErrorSnackBar(context, error);
    }
  }

  Future<void> _addItem() async {
    final item = await pickItem(context, ref);
    if (item == null || !mounted) return;
    if (_lines.any((line) => line.itemId == item.id)) {
      showInfoSnackBar(context, '${item.name} is already on this indent.');
      return;
    }
    setState(() => _lines.add(_IndentLineRow.forItem(item)));
  }

  Future<void> _save({required bool submit}) async {
    if (!_formKey.currentState!.validate()) return;
    final location = _locationId;
    if (location == null) return;
    if (_lines.isEmpty) {
      showInfoSnackBar(context, 'Add at least one material item.');
      return;
    }
    final lines = <IndentLineDraft>[];
    for (final line in _lines) {
      final qty = double.tryParse(line.qty.text.trim());
      if (qty == null || qty <= 0) {
        showInfoSnackBar(context, 'Enter a quantity for ${line.itemName}.');
        return;
      }
      lines.add(
        IndentLineDraft(
          itemId: line.itemId,
          qty: qty,
          boqLineId: line.boqLineId,
        ),
      );
    }

    setState(() => _busy = true);
    try {
      final repo = ref.read(constructionRepositoryProvider);
      final draft = IndentDraft(
        locationId: location,
        requiredBy: _requiredBy == null ? null : apiDate(_requiredBy!),
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        // A new indent is created and submitted in one request, so a failed
        // submit cannot leave a duplicate draft behind. PUT has no `submit`.
        submit: submit && !_editing,
        lines: lines,
      );
      var saved = _editing
          ? await repo.updateIndent(widget.indentId!, draft)
          : await repo.createIndent(draft);
      if (submit && _editing) saved = await repo.submitIndent(saved.id);
      ref.bumpC(const [CKind.indents]);
      if (!mounted) return;
      showSuccess(
        context,
        submit ? '${saved.number} submitted' : '${saved.number} saved',
      );
      context.go('/indents/${saved.id}');
    } catch (error) {
      if (!mounted) return;
      showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final session = ref.watch(sessionProvider).value;
    if (_loading) return const LoadingView();
    final original = _original;
    final creator =
        original == null || session?.user?.id == original.createdBy?.id;
    final canEdit = !_editing || creator || perms.can(CPerm.indentsApprove);
    // PUT /indents/:id only accepts draft or rejected indents.
    final lockedStatus =
        original != null &&
            original.status != IndentStatus.draft &&
            original.status != IndentStatus.rejected
        ? original.status
        : null;
    return CGate(
      anyOf: const [CPerm.indentsCreate, CPerm.indentsApprove],
      child: lockedStatus != null
          ? EmptyView(
              icon: Icons.lock_outline,
              message:
                  'This indent is ${lockedStatus.label.toLowerCase()}; only '
                  'draft or rejected indents can be edited.',
            )
          : !canEdit
          ? const EmptyView(
              icon: Icons.lock_outline,
              message:
                  'Only the person who raised this indent or an approver can '
                  'edit it.',
            )
          : Form(
              key: _formKey,
              onChanged: markDirty,
              child: BottomBarLayout(
                bar: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      style: bigOutlinedButton,
                      onPressed: _busy ? null : () => leave('/indents'),
                      child: const Text('Cancel'),
                    ),
                    OutlinedButton(
                      style: bigOutlinedButton,
                      onPressed: _busy ? null : () => _save(submit: false),
                      child: Text(_editing ? 'Save changes' : 'Save draft'),
                    ),
                    FilledButton(
                      style: bigButton,
                      // Submitting needs indents.create (approvers may edit).
                      onPressed: _busy || !perms.can(CPerm.indentsCreate)
                          ? null
                          : () => _save(submit: true),
                      child: Text(
                        original?.status == IndentStatus.rejected
                            ? 'Save & resubmit'
                            : 'Save & submit',
                      ),
                    ),
                  ],
                ),
                child: CPage(
                  maxWidth: 900,
                  children: [
                    SectionCard(
                      title: 'Indent details',
                      child: FormRow(
                        children: [
                          SiteField(
                            value: _locationId,
                            includeStores: true,
                            onChanged: (value) {
                              setState(() {
                                _locationId = value;
                                for (final line in _lines) {
                                  line.boqLineId = null;
                                }
                              });
                            },
                          ),
                          DateField(
                            label: 'Required by',
                            value: _requiredBy,
                            onChanged: (value) =>
                                setState(() => _requiredBy = value),
                            onCleared: () => setState(() => _requiredBy = null),
                          ),
                        ],
                      ),
                    ),
                    SectionCard(
                      title: 'Material requested',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_lines.isEmpty)
                            const Text('No material items added yet.'),
                          for (final line in _lines) ...[
                            _IndentLineEditor(
                              row: line,
                              locationId: _locationId,
                              enabled: !_busy,
                              onChanged: () => setState(() {}),
                              onRemove: () => setState(() {
                                _lines.remove(line);
                                line.qty.dispose();
                              }),
                            ),
                            const SizedBox(height: 12),
                          ],
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              style: bigOutlinedButton,
                              onPressed: _busy ? null : _addItem,
                              icon: const Icon(Icons.add),
                              label: const Text('Add material'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SectionCard(
                      title: 'Notes',
                      child: TextFormField(
                        controller: _notes,
                        maxLength: 1000,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: 'Notes (optional)',
                          hintText:
                              'Purpose, priority or delivery instructions',
                        ),
                      ),
                    ),
                    const SectionCard(
                      title: 'Submission',
                      child: Text(
                        'A submitted indent is locked while it is reviewed. If '
                        'it is rejected, revise the material and quantities, '
                        'then resubmit it.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _IndentLineRow {
  _IndentLineRow({
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.qty,
    this.boqLineId,
  });

  factory _IndentLineRow.forItem(Item item) => _IndentLineRow(
    itemId: item.id,
    itemName: item.name,
    unit: item.unit,
    qty: TextEditingController(),
  );

  factory _IndentLineRow.fromModel(IndentLine line) => _IndentLineRow(
    itemId: line.itemId,
    itemName: line.itemName,
    unit: line.unit,
    qty: TextEditingController(text: formatPlain(line.qty)),
    boqLineId: line.boqLineId,
  );

  final String itemId;
  final String itemName;
  final String unit;
  final TextEditingController qty;
  String? boqLineId;
}

class _IndentLineEditor extends StatelessWidget {
  const _IndentLineEditor({
    required this.row,
    required this.locationId,
    required this.enabled,
    required this.onChanged,
    required this.onRemove,
  });

  final _IndentLineRow row;
  final String? locationId;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.itemName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      row.unit,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 150,
                child: TextFormField(
                  controller: row.qty,
                  enabled: enabled,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput(decimals: 3)],
                  decoration: InputDecoration(
                    labelText: 'Quantity',
                    suffixText: row.unit,
                  ),
                  validator: (value) {
                    final qty = double.tryParse(value?.trim() ?? '');
                    return qty == null || qty <= 0 ? 'More than zero' : null;
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Remove ${row.itemName}',
                onPressed: enabled ? onRemove : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
            ],
          ),
          if (locationId != null) ...[
            const SizedBox(height: 12),
            BoqLineField(
              siteId: locationId,
              value: row.boqLineId,
              enabled: enabled,
              onChanged: (line) {
                row.boqLineId = line?.id;
                onChanged();
              },
            ),
          ],
        ],
      ),
    ),
  );
}
