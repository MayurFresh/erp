import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../items/items_repository.dart';
import 'stock_tools_models.dart';
import 'stock_tools_repository.dart';

/// Alternate units of one item: a box of 12, kg and g. Opens at `/items/:id/units`.
class ItemUnitsScreen extends ConsumerWidget {
  const ItemUnitsScreen({super.key, required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(itemProvider(itemId));
    final units = ref.watch(itemUnitsProvider(itemId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Units',
          subtitle: item.value?.name,
        ),
        Expanded(
          child: units.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorView(
              error: e,
              onRetry: () => ref.invalidate(itemUnitsProvider(itemId)),
            ),
            data: (u) => _UnitsForm(itemId: itemId, initial: u),
          ),
        ),
      ],
    );
  }
}

class _UnitsForm extends ConsumerStatefulWidget {
  const _UnitsForm({required this.itemId, required this.initial});

  final String itemId;
  final ItemUnits initial;

  @override
  ConsumerState<_UnitsForm> createState() => _UnitsFormState();
}

class _Row {
  _Row(String name, String factor)
    : name = TextEditingController(text: name),
      factor = TextEditingController(text: factor);

  final TextEditingController name;
  final TextEditingController factor;
}

String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v';

class _UnitsFormState extends ConsumerState<_UnitsForm> {
  late final List<_Row> _rows = [
    for (final u in widget.initial.units) _Row(u.name, _trim(u.factor)),
  ];
  late String? _purchase = widget.initial.defaultPurchaseUnit;
  late String? _sale = widget.initial.defaultSaleUnit;
  bool _busy = false;
  String? _error;

  List<UnitDef> get _defs => [
    for (final r in _rows)
      if (r.name.text.trim().isNotEmpty)
        UnitDef(name: r.name.text.trim(), factor: parseDecimal(r.factor.text) ?? 0),
  ];

  List<String> get _names => [widget.initial.baseUnit, ..._defs.map((d) => d.name)];

  Future<void> _save() async {
    final defs = _defs;
    if (defs.any((d) => d.factor <= 0)) {
      setState(() => _error = 'Each unit needs a factor above zero.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(stockToolsRepositoryProvider).saveUnits(
        widget.itemId,
        units: defs,
        defaultPurchaseUnit: _names.contains(_purchase) ? _purchase : null,
        defaultSaleUnit: _names.contains(_sale) ? _sale : null,
      );
      ref.invalidate(itemUnitsProvider(widget.itemId));
      if (mounted) context.pop();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.name.dispose();
      r.factor.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.initial.baseUnit;
    final can = ref.watch(permissionsProvider).can(Perm.itemsEdit);
    final names = _names;
    return ListView(
      padding: EdgeInsets.all(pageGutter(context)),
      children: [
        Text('Base unit: $base. Stock, rates and reports stay in the base unit.'),
        const SizedBox(height: 12),
        for (final (i, r) in _rows.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: r.name,
                    enabled: can,
                    decoration: const InputDecoration(labelText: 'Unit name'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: r.factor,
                    enabled: can,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Holds ($base)',
                      helperText: '1 ${r.name.text.isEmpty ? 'unit' : r.name.text} = ? $base',
                    ),
                  ),
                ),
                if (can)
                  IconButton(
                    tooltip: 'Remove unit',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => setState(() => _rows.removeAt(i)),
                  ),
              ],
            ),
          ),
        if (can)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add a unit'),
              onPressed: () => setState(() => _rows.add(_Row('', ''))),
            ),
          ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: names.contains(_purchase) ? _purchase : null,
          decoration: const InputDecoration(labelText: 'Default purchase unit'),
          items: [for (final n in names) DropdownMenuItem(value: n, child: Text(n))],
          onChanged: can ? (v) => setState(() => _purchase = v) : null,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: names.contains(_sale) ? _sale : null,
          decoration: const InputDecoration(labelText: 'Default sale unit'),
          items: [for (final n in names) DropdownMenuItem(value: n, child: Text(n))],
          onChanged: can ? (v) => setState(() => _sale = v) : null,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const SizedBox(height: 16),
        if (can)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy ? null : _save,
              child: const Text('Save units'),
            ),
          ),
      ],
    );
  }
}

/// Parses "12", "0.001" or "1,5".
double? parseDecimal(String text) => double.tryParse(text.trim().replaceAll(',', '.'));
