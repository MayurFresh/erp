import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, showSuccess;
import 'rest_models.dart';
import 'rest_perms.dart';
import 'rest_repository.dart';
import 'rest_widgets.dart';
import 'setup_widgets.dart';

/// `/restaurant/setup`: service charge, areas and tables.
class FloorSetupScreen extends ConsumerStatefulWidget {
  const FloorSetupScreen({super.key});

  @override
  ConsumerState<FloorSetupScreen> createState() => _FloorSetupScreenState();
}

class _FloorSetupScreenState extends ConsumerState<FloorSetupScreen> {
  Future<void> _area([FloorArea? area]) async {
    final saved = await showFormDialog<bool>(
      context: context,
      builder: (_) => _AreaDialog(area: area),
    );
    if (saved == true) ref.bumpRest();
  }

  Future<void> _table(
    List<FloorArea> areas, {
    FloorArea? area,
    FloorTable? table,
  }) async {
    final saved = await showFormDialog<bool>(
      context: context,
      builder: (_) => _TableDialog(areas: areas, area: area, table: table),
    );
    if (saved == true) ref.bumpRest();
  }

  Future<void> _delete(String what, Future<void> Function() call) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $what?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final ok = await restGuarded(context, call);
    if (ok) ref.bumpRest();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final repo = ref.read(restaurantRepositoryProvider);
    return CGate(
      anyOf: const [RestPerm.manage],
      child: AsyncValueView(
        value: ref.watch(restFloorProvider),
        onRetry: () => ref.invalidate(restFloorProvider),
        data: (areas) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: 'Floor setup',
              actions: [
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => _area(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add area'),
                ),
              ],
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.all(pageGutter(context)),
                children: [
                  const _ServiceChargeCard(),
                  const SizedBox(height: Space.lg),
                  if (areas.isEmpty)
                    const EmptyView(
                      icon: Icons.table_restaurant_outlined,
                      message:
                          'No areas yet. Add one, for example Ground floor.',
                    ),
                  for (final area in areas) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: Space.md),
                      padding: const EdgeInsets.all(Space.md),
                      decoration: BoxDecoration(
                        border: Border.all(color: colors.hairline),
                        borderRadius: Radii.mediumAll,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  area.isActive
                                      ? area.name
                                      : '${area.name} (hidden)',
                                  style: theme.textTheme.titleMedium,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Edit area',
                                onPressed: () => _area(area),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                tooltip: 'Delete area',
                                onPressed: () => _delete(
                                  'area ${area.name}',
                                  () => repo.deleteArea(area.id),
                                ),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                          for (final t in area.tables)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              title: Text(
                                t.isActive ? t.name : '${t.name} (not in use)',
                              ),
                              subtitle: Text('${t.seats} seats'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Edit table ${t.name}',
                                    onPressed: () =>
                                        _table(areas, area: area, table: t),
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                  IconButton(
                                    tooltip: 'Delete table ${t.name}',
                                    onPressed: () => _delete(
                                      'table ${t.name}',
                                      () => repo.deleteTable(t.id),
                                    ),
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                                ],
                              ),
                            ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: () => _table(areas, area: area),
                              icon: const Icon(Icons.add),
                              label: const Text('Add table'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServiceChargeCard extends ConsumerStatefulWidget {
  const _ServiceChargeCard();

  @override
  ConsumerState<_ServiceChargeCard> createState() => _ServiceChargeCardState();
}

class _ServiceChargeCardState extends ConsumerState<_ServiceChargeCard> {
  final _formKey = GlobalKey<FormState>();
  final _pct = TextEditingController();
  final _gst = TextEditingController();
  bool _loaded = false;
  bool _saving = false;

  @override
  void dispose() {
    _pct.dispose();
    _gst.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final ok = await restGuarded(
      context,
      () => ref
          .read(restaurantRepositoryProvider)
          .saveSettings(
            serviceChargePct: parseNumber(_pct.text.trim()) ?? 0,
            serviceChargeGst: parseNumber(_gst.text.trim()) ?? 5,
          ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref.bumpRest();
      showSuccess(context, 'Service charge saved');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(restSettingsProvider).value;
    if (settings != null && !_loaded) {
      _loaded = true;
      _pct.text = formatPlain(settings.serviceChargePct);
      _gst.text = formatPlain(settings.serviceChargeGst);
    }
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        border: Border.all(color: context.colors.hairline),
        borderRadius: Radii.mediumAll,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Service charge',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Space.xs),
            Text(
              'Added to dine-in bills after any discount. A manager can waive it on a bill. Use 0 for none.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            FormRow(
              children: [
                TextFormField(
                  controller: _pct,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Service charge %',
                  ),
                  validator: (v) =>
                      requiredNumber(v, label: 'Percent', min: 0, max: 30),
                ),
                TextFormField(
                  controller: _gst,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'GST on the charge %',
                  ),
                  validator: (v) =>
                      requiredNumber(v, label: 'GST', min: 0, max: 28),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            Align(
              alignment: Alignment.centerLeft,
              child: BusyButton(busy: _saving, onPressed: _save, label: 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AreaDialog extends ConsumerStatefulWidget {
  const _AreaDialog({this.area});

  final FloorArea? area;

  @override
  ConsumerState<_AreaDialog> createState() => _AreaDialogState();
}

class _AreaDialogState extends ConsumerState<_AreaDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.area?.name ?? '');
  late final _sort = TextEditingController(
    text: '${widget.area?.sortOrder ?? 0}',
  );
  late bool _active = widget.area?.isActive ?? true;

  @override
  void dispose() {
    _name.dispose();
    _sort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => EditDialog(
    title: widget.area == null ? 'Add area' : 'Edit area',
    formKey: _formKey,
    onSave: () => ref
        .read(restaurantRepositoryProvider)
        .saveArea(
          id: widget.area?.id,
          body: {
            'name': _name.text.trim(),
            'sortOrder': int.tryParse(_sort.text.trim()) ?? 0,
            'isActive': _active,
          },
        ),
    children: [
      TextFormField(
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Area name'),
        validator: (v) => requiredField(v, 'Name'),
      ),
      const SizedBox(height: Space.md),
      TextFormField(
        controller: _sort,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(
          labelText: 'Position',
          helperText: 'Smaller numbers come first',
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _active,
        onChanged: (v) => setState(() => _active = v),
        title: const Text('Show on the floor'),
      ),
    ],
  );
}

class _TableDialog extends ConsumerStatefulWidget {
  const _TableDialog({required this.areas, this.area, this.table});

  final List<FloorArea> areas;
  final FloorArea? area;
  final FloorTable? table;

  @override
  ConsumerState<_TableDialog> createState() => _TableDialogState();
}

class _TableDialogState extends ConsumerState<_TableDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.table?.name ?? '');
  late final _seats = TextEditingController(
    text: '${widget.table?.seats ?? 4}',
  );
  late final _sort = TextEditingController(
    text:
        '${widget.table?.sortOrder ?? ((widget.area?.tables.length ?? 0) + 1)}',
  );
  late String? _areaId = widget.area?.id ?? widget.areas.firstOrNull?.id;
  late bool _active = widget.table?.isActive ?? true;

  @override
  void dispose() {
    for (final c in [_name, _seats, _sort]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => EditDialog(
    title: widget.table == null ? 'Add table' : 'Edit table',
    formKey: _formKey,
    onSave: () => ref
        .read(restaurantRepositoryProvider)
        .saveTable(
          id: widget.table?.id,
          body: {
            'areaId': _areaId,
            'name': _name.text.trim(),
            'seats': int.tryParse(_seats.text.trim()) ?? 4,
            'sortOrder': int.tryParse(_sort.text.trim()) ?? 0,
            'isActive': _active,
          },
        ),
    children: [
      DropdownButtonFormField<String>(
        initialValue: _areaId,
        decoration: const InputDecoration(labelText: 'Area'),
        items: [
          for (final a in widget.areas)
            DropdownMenuItem(value: a.id, child: Text(a.name)),
        ],
        onChanged: (v) => _areaId = v,
        validator: (v) => v == null ? 'Choose an area' : null,
      ),
      const SizedBox(height: Space.md),
      TextFormField(
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Table name',
          helperText: 'For example T1 or Window 2',
        ),
        validator: (v) => requiredField(v, 'Name'),
      ),
      const SizedBox(height: Space.md),
      FieldPair(
        TextFormField(
          controller: _seats,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Seats'),
          validator: (v) => requiredNumber(v, label: 'Seats', min: 1, max: 100),
        ),
        TextFormField(
          controller: _sort,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Position'),
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _active,
        onChanged: (v) => setState(() => _active = v),
        title: const Text('In use'),
      ),
    ],
  );
}
