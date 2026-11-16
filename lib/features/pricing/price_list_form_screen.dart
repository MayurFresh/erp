import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/busy.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'price_rows_editor.dart';
import 'pricing_models.dart';
import 'pricing_repository.dart';

/// Creates a price list, or opens one (`listId`) to edit.
class PriceListFormScreen extends ConsumerWidget {
  const PriceListFormScreen({super.key, this.listId});

  final String? listId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (listId == null) return const _Form();
    return AsyncValueView(
      value: ref.watch(priceListProvider(listId!)),
      onRetry: () => ref.invalidate(priceListProvider(listId!)),
      data: (l) => _Form(existing: l),
    );
  }
}

class _Form extends ConsumerStatefulWidget {
  const _Form({this.existing});

  final PriceList? existing;

  @override
  ConsumerState<_Form> createState() => _FormState();
}

class _FormState extends ConsumerState<_Form>
    with DirtyTracking, ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _pct = TextEditingController();
  final _notes = TextEditingController();
  final List<RowDraft> _rows = [];
  String _mode = 'fixed';
  bool _below = true;
  bool _active = true;
  DateTime? _from;
  DateTime? _to;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final l = widget.existing;
    if (l == null) return;
    _name.text = l.name;
    _mode = l.mode;
    _below = l.adjustPct <= 0;
    _pct.text = l.adjustPct == 0 ? '' : formatPlain(l.adjustPct.abs());
    _notes.text = l.notes ?? '';
    _active = l.isActive;
    _from = DateTime.tryParse(l.validFrom ?? '');
    _to = DateTime.tryParse(l.validTo ?? '');
    _rows.addAll(l.items.map(RowDraft.from));
  }

  @override
  void dispose() {
    _name.dispose();
    _pct.dispose();
    _notes.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _pick(bool from) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: (from ? _from : _to) ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 5),
    );
    if (d == null || !mounted) return;
    setState(() => from ? _from = d : _to = d);
    markDirty();
  }

  Future<void> _save() async {
    if (_saving || !validateAndReveal(_formKey)) return;
    if (_from != null && _to != null && _to!.isBefore(_from!)) {
      showInfoSnackBar(context, 'The end date is before the start date.');
      return;
    }
    setState(() => _saving = true);
    final pct = (parseNumber(_pct.text) ?? 0) * (_below ? -1 : 1);
    final body = {
      'name': _name.text.trim(),
      'mode': _mode,
      'adjustPct': _mode == 'percent' ? pct : 0,
      'validFrom': _from == null ? null : apiDate(_from!),
      'validTo': _to == null ? null : apiDate(_to!),
      'isActive': _active,
      'notes': trimmedOrNull(_notes.text),
    };
    try {
      final repo = ref.read(pricingRepositoryProvider);
      final id = widget.existing?.id;
      final String savedId;
      if (id == null) {
        savedId = (await repo.createList(body)).id;
      } else {
        await repo.updateList(id, body);
        savedId = id;
      }
      await repo.saveListItems(savedId, [for (final r in _rows) ?r.toRow()]);
      markSaved();
      ref.read(pricingRevisionProvider.notifier).bump();
      if (!mounted) return;
      showInfoSnackBar(context, 'Price list saved');
      context.go('/price-lists');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final id = widget.existing!.id;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this price list?'),
        content: const Text('Customers on it must be moved to another list first.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(pricingRepositoryProvider).deleteList(id);
      markSaved();
      ref.read(pricingRevisionProvider.notifier).bump();
      if (mounted) context.go('/price-lists');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canEdit = ref.watch(permissionsProvider).can(Perm.pricingManage);
    final editing = widget.existing != null;
    return track(
      Form(
        key: _formKey,
        onChanged: markDirty,
        child: FormPage(
          maxWidth: 900,
          bottomBar: FormActionBar(
            children: [
              if (editing && canEdit)
                TextButton(onPressed: _saving ? null : _delete, child: const Text('Delete')),
              TextButton(
                onPressed: _saving ? null : () => leave('/price-lists'),
                child: const Text('Cancel'),
              ),
              if (canEdit)
                BusyButton(busy: _saving, onPressed: _save, label: 'Save price list', icon: Icons.check),
            ],
          ),
          children: [
            Text(editing ? widget.existing!.name : 'New price list', style: theme.textTheme.headlineSmall),
            SectionCard(
              title: 'Details',
              child: IgnorePointer(
                ignoring: !canEdit,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FormRow(
                      children: [
                        TextFormField(
                          controller: _name,
                          maxLength: 80,
                          decoration: InputDecoration(
                            labelText: 'Name',
                            errorText: serverError('name'),
                          ),
                          validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name' : null,
                        ),
                      ],
                    ),
                    SegmentedButton<String>(
                      key: const ValueKey('mode'),
                      segments: const [
                        ButtonSegment(value: 'fixed', label: Text('Listed prices')),
                        ButtonSegment(value: 'percent', label: Text('Percent of item price')),
                      ],
                      selected: {_mode},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) {
                        setState(() => _mode = s.first);
                        markDirty();
                      },
                    ),
                    if (_mode == 'percent') ...[
                      const SizedBox(height: 12),
                      FormRow(
                        children: [
                          TextFormField(
                            controller: _pct,
                            keyboardType: decimalKeyboard,
                            inputFormatters: <TextInputFormatter>[decimalInput(decimals: 2)],
                            decoration: const InputDecoration(labelText: 'Percent', suffixText: '%'),
                            validator: (v) => parseNumber(v ?? '') == null ? 'Enter a percent' : null,
                          ),
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: true, label: Text('Below')),
                              ButtonSegment(value: false, label: Text('Above')),
                            ],
                            selected: {_below},
                            showSelectedIcon: false,
                            onSelectionChanged: (s) {
                              setState(() => _below = s.first);
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
                          label: 'Valid from (optional)',
                          value: _from == null ? null : formatDate(_from),
                          icon: Icons.calendar_today_outlined,
                          onTap: () => _pick(true),
                        ),
                        PickerField(
                          label: 'Valid until (optional)',
                          value: _to == null ? null : formatDate(_to),
                          icon: Icons.calendar_today_outlined,
                          onTap: () => _pick(false),
                        ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Active'),
                      value: _active,
                      onChanged: (v) {
                        setState(() => _active = v);
                        markDirty();
                      },
                    ),
                    TextFormField(
                      controller: _notes,
                      maxLines: 2,
                      maxLength: 500,
                      decoration: const InputDecoration(labelText: 'Notes (optional)'),
                    ),
                  ],
                ),
              ),
            ),
            SectionCard(
              title: _mode == 'percent' ? 'Prices that differ from the rule' : 'Item prices',
              child: IgnorePointer(
                ignoring: !canEdit,
                child: PriceRowsEditor(
                  rows: _rows,
                  emptyText: _mode == 'percent'
                      ? 'Every item follows the percent. Add a price only where it should differ.'
                      : 'No item prices yet. Items not listed use their sale price.',
                  onChanged: () {
                    setState(() {});
                    markDirty();
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
