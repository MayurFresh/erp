import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../items/item_picker.dart';
import 'pricing_models.dart';
import 'pricing_repository.dart';

String schemeRule(PriceScheme s) => s.isFree
    ? 'Buy ${formatQty(s.buyQty)} get ${formatQty(s.freeQty)} free'
    : '${formatPercent(s.discountPct)} off from ${formatQty(s.minQty)}';

/// Date-bound schemes: free quantity and slab discounts.
class PriceSchemesScreen extends ConsumerWidget {
  const PriceSchemesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(permissionsProvider).can(Perm.pricingManage);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Schemes',
          subtitle: 'Free goods and quantity discounts for a period',
          actions: [
            OutlinedButton(
              onPressed: () => context.go('/price-lists'),
              child: const Text('Price lists'),
            ),
            if (canEdit)
              FilledButton.icon(
                onPressed: () => showSchemeDialog(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('New scheme'),
              ),
          ],
        ),
        Expanded(
          child: AsyncValueView(
            value: ref.watch(priceSchemesProvider),
            onRetry: () => ref.invalidate(priceSchemesProvider),
            data: (list) {
              if (list.isEmpty) {
                return const EmptyView(message: 'No schemes yet. Add one such as buy 10 get 1 free.');
              }
              return ListView.separated(
                padding: EdgeInsets.symmetric(horizontal: pageGutter(context), vertical: 8),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final s = list[i];
                  return ListTile(
                    minVerticalPadding: 12,
                    title: Text(s.name),
                    subtitle: Text(
                      [
                        s.itemName,
                        schemeRule(s),
                        if (s.validFrom != null || s.validTo != null)
                          '${s.validFrom ?? 'any time'} to ${s.validTo ?? 'no end'}',
                      ].join(' · '),
                    ),
                    trailing: StatusChip(
                      s.isActive ? 'active' : 'inactive',
                      label: s.isActive ? 'Active' : 'Inactive',
                    ),
                    onTap: canEdit ? () => showSchemeDialog(context, ref, existing: s) : null,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

Future<void> showSchemeDialog(
  BuildContext context,
  WidgetRef ref, {
  PriceScheme? existing,
}) => showFormDialog<void>(
  context: context,
  builder: (_) => _SchemeDialog(existing: existing),
);

class _SchemeDialog extends ConsumerStatefulWidget {
  const _SchemeDialog({this.existing});

  final PriceScheme? existing;

  @override
  ConsumerState<_SchemeDialog> createState() => _SchemeDialogState();
}

class _SchemeDialogState extends ConsumerState<_SchemeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _buy = TextEditingController();
  final _free = TextEditingController();
  final _min = TextEditingController();
  final _pct = TextEditingController();
  String _kind = 'free_qty';
  String? _itemId;
  String? _itemName;
  String? _freeItemId;
  String? _freeItemName;
  bool _active = true;
  DateTime? _from;
  DateTime? _to;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    if (s == null) return;
    _name.text = s.name;
    _kind = s.kind;
    _itemId = s.itemId;
    _itemName = s.itemName;
    _freeItemId = s.freeItemId;
    _buy.text = formatPlain(s.buyQty);
    _free.text = formatPlain(s.freeQty);
    _min.text = formatPlain(s.minQty);
    _pct.text = formatPlain(s.discountPct);
    _active = s.isActive;
    _from = DateTime.tryParse(s.validFrom ?? '');
    _to = DateTime.tryParse(s.validTo ?? '');
    if (_freeItemId != null) _freeItemName = 'Another item';
  }

  @override
  void dispose() {
    for (final c in [_name, _buy, _free, _min, _pct]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _date(bool from) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: (from ? _from : _to) ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 5),
    );
    if (d != null && mounted) setState(() => from ? _from = d : _to = d);
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    if (_itemId == null) {
      showInfoSnackBar(context, 'Choose the item the scheme is for.');
      return;
    }
    setState(() => _saving = true);
    final free = _kind == 'free_qty';
    final body = {
      'name': _name.text.trim(),
      'kind': _kind,
      'itemId': _itemId,
      if (free) 'buyQty': parseNumber(_buy.text),
      if (free) 'freeQty': parseNumber(_free.text),
      if (free) 'freeItemId': _freeItemId,
      if (!free) 'minQty': parseNumber(_min.text),
      if (!free) 'discountPct': parseNumber(_pct.text),
      'validFrom': _from == null ? null : apiDate(_from!),
      'validTo': _to == null ? null : apiDate(_to!),
      'isActive': _active,
    };
    try {
      final repo = ref.read(pricingRepositoryProvider);
      if (widget.existing == null) {
        await repo.createScheme(body);
      } else {
        await repo.updateScheme(widget.existing!.id, body);
      }
      ref.read(pricingRevisionProvider.notifier).bump();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remove() async {
    try {
      await ref.read(pricingRepositoryProvider).deleteScheme(widget.existing!.id);
      ref.read(pricingRevisionProvider.notifier).bump();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget num(TextEditingController c, String label, int d) => TextFormField(
      controller: c,
      keyboardType: decimalKeyboard,
      inputFormatters: <TextInputFormatter>[decimalInput(decimals: d)],
      decoration: InputDecoration(labelText: label),
      validator: (v) {
        final n = parseNumber(v ?? '');
        return n == null || n <= 0 ? 'Enter more than zero' : null;
      },
    );
    final free = _kind == 'free_qty';
    return AlertDialog(
      title: Text(widget.existing == null ? 'New scheme' : 'Edit scheme'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  maxLength: 100,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name' : null,
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'free_qty', label: Text('Free goods')),
                    ButtonSegment(value: 'slab_discount', label: Text('Discount')),
                  ],
                  selected: {_kind},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _kind = s.first),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () async {
                    final i = await pickItem(context, ref);
                    if (i != null && mounted) setState(() { _itemId = i.id; _itemName = i.name; });
                  },
                  child: Text(_itemName ?? 'Choose item'),
                ),
                const SizedBox(height: 12),
                if (free) ...[
                  num(_buy, 'Buy quantity', 3),
                  const SizedBox(height: 8),
                  num(_free, 'Free quantity', 3),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () async {
                      final i = await pickItem(context, ref);
                      if (i != null && mounted) setState(() { _freeItemId = i.id == _itemId ? null : i.id; _freeItemName = i.name; });
                    },
                    child: Text(
                      _freeItemId == null ? 'Free item: same item' : 'Free item: ${_freeItemName ?? ''}',
                    ),
                  ),
                ] else ...[
                  num(_min, 'From quantity', 3),
                  const SizedBox(height: 8),
                  num(_pct, 'Discount %', 2),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => _date(true),
                      child: Text(_from == null ? 'Valid from' : 'From ${formatDate(_from)}'),
                    ),
                    OutlinedButton(
                      onPressed: () => _date(false),
                      child: Text(_to == null ? 'Valid until' : 'Until ${formatDate(_to)}'),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(onPressed: _saving ? null : _remove, child: const Text('Delete')),
        TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
