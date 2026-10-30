import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../core/providers.dart';
import '../../../widgets/form_support.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../documents/document_widgets.dart';
import '../../items/item_model.dart';
import '../../items/item_picker.dart';
import '../common/boq_picker.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../models/material_models.dart';
import '../../../widgets/busy.dart';

/// Creates a material issue against a site store.
class IssueFormScreen extends ConsumerStatefulWidget {
  const IssueFormScreen({super.key, this.initialLocationId});

  final String? initialLocationId;

  @override
  ConsumerState<IssueFormScreen> createState() => _IssueFormScreenState();
}

class _IssueFormScreenState extends ConsumerState<IssueFormScreen>
    with DirtyTracking<IssueFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _notes = TextEditingController();
  final List<_IssueLine> _lines = [];
  String? _locationId;
  String? _boqLineId;
  DateTime _date = today();
  bool _busy = false;

  /// Last save error, shown above the buttons (e.g. not enough stock).
  Object? _error;

  @override
  void initState() {
    super.initState();
    _locationId = widget.initialLocationId;
  }

  @override
  void dispose() {
    _notes.dispose();
    for (final line in _lines) {
      line.qty.dispose();
    }
    super.dispose();
  }

  Future<void> _addItem() async {
    final item = await pickItem(context, ref, stockOnly: true);
    if (item == null || !mounted) return;
    if (_lines.any((line) => line.item.id == item.id)) {
      showInfoSnackBar(context, '${item.name} is already on this issue.');
      return;
    }
    setState(() => _lines.add(_IssueLine(item)));
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_lines.isEmpty) {
      markSaved();
      showInfoSnackBar(context, 'Add at least one material item.');
      return;
    }
    final lines = <({String itemId, double qty})>[];
    for (final line in _lines) {
      final qty = double.tryParse(line.qty.text.trim());
      if (qty == null || qty <= 0) {
        showInfoSnackBar(context, 'Enter a quantity for ${line.item.name}.');
        return;
      }
      lines.add((itemId: line.item.id, qty: qty));
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final issue = await ref
          .read(constructionRepositoryProvider)
          .createIssue(
            IssueDraft(
              locationId: _locationId!,
              boqLineId: _boqLineId,
              date: apiDate(_date),
              notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
              lines: lines,
            ),
          );
      ref.bumpC(const [CKind.issues], const [DataKind.stock]);
      if (!mounted) return;
      showSuccess(context, '${issue.number} posted');
      context.go('/issues/${issue.id}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
      showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) => CGate(
    anyOf: const [CPerm.consumptionCreate],
    child: Form(
      key: _formKey,
      onChanged: markDirty,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(title: 'Issue material'),
          Expanded(
            child: BottomBarLayout(
              bar: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    ApiErrorBox(error: _error!, subject: 'the issue'),
                    const SizedBox(height: 8),
                  ],
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        style: bigOutlinedButton,
                        onPressed: _busy ? null : () => leave('/issues'),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        style: bigButton,
                        onPressed: _busy || _locationId == null ? null : _save,
                        child: const Text('Post issue'),
                      ),
                    ],
                  ),
                ],
              ),
              child: CPage(
                maxWidth: 900,
                children: [
                  SectionCard(
                    title: 'Issue details',
                    child: FormRow(
                      children: [
                        SiteField(
                          value: _locationId,
                          required: true,
                          onChanged: (value) => setState(() {
                            _locationId = value;
                            _boqLineId = null;
                          }),
                        ),
                        DateField(
                          label: 'Issue date',
                          value: _date,
                          lastDate: today(),
                          onChanged: (value) => setState(() => _date = value),
                        ),
                        BoqLineField(
                          siteId: _locationId,
                          value: _boqLineId,
                          onChanged: (line) =>
                              setState(() => _boqLineId = line?.id),
                        ),
                      ],
                    ),
                  ),
                  SectionCard(
                    title: 'Material',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_lines.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: Text('Add stock-tracked material below.'),
                          ),
                        for (final line in _lines)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _IssueLineEditor(
                              key: ObjectKey(line),
                              line: line,
                              enabled: !_busy,
                              onRemove: () => setState(() {
                                _lines.remove(line);
                                line.qty.dispose();
                              }),
                            ),
                          ),
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
                      maxLength: 500,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Notes (optional)',
                        hintText: 'Purpose or work instructions',
                      ),
                    ),
                  ),
                  const SectionCard(
                    title: 'Stock and accounting',
                    child: Text(
                      'The server checks stock at the selected site before posting. '
                      'A successful issue reduces inventory and records material '
                      'consumed at work.',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _IssueLine {
  _IssueLine(this.item) : qty = TextEditingController();

  final Item item;
  final TextEditingController qty;
}

/// Item + quantity + remove; the quantity moves under the item on phones.
class _IssueLineEditor extends StatelessWidget {
  const _IssueLineEditor({
    super.key,
    required this.line,
    required this.enabled,
    required this.onRemove,
  });

  final _IssueLine line;
  final bool enabled;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final name = Text(
      line.item.name,
      style: Theme.of(context).textTheme.titleMedium,
    );
    final qty = TextFormField(
      controller: line.qty,
      enabled: enabled,
      keyboardType: decimalKeyboard,
      inputFormatters: [decimalInput(decimals: 3)],
      decoration: InputDecoration(
        labelText: 'Quantity',
        suffixText: line.item.unit,
      ),
      validator: (value) {
        final qty = double.tryParse(value?.trim() ?? '');
        return qty == null || qty <= 0 ? 'More than zero' : null;
      },
    );
    final remove = IconButton(
      tooltip: 'Remove ${line.item.name}',
      constraints: BoxConstraints.tight(kTapTarget),
      onPressed: enabled ? onRemove : null,
      icon: const Icon(Icons.remove_circle_outline),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 480) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: name),
                  remove,
                ],
              ),
              const SizedBox(height: 6),
              qty,
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: name),
            const SizedBox(width: 12),
            SizedBox(width: 170, child: qty),
            remove,
          ],
        );
      },
    );
  }
}
