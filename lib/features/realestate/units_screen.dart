import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart' show changedFields;
import '../../core/money.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 're_models.dart';
import 're_perms.dart';
import 're_repository.dart';
import 're_widgets.dart';

enum _UnitsView { list, stacking }

/// `/units`: unit list and a stacking view (wing × floor) with status colours.
class UnitsScreen extends ConsumerStatefulWidget {
  const UnitsScreen({super.key, this.initialProjectId});

  final String? initialProjectId;

  @override
  ConsumerState<UnitsScreen> createState() => _UnitsScreenState();
}

class _UnitsScreenState extends ConsumerState<UnitsScreen> {
  late String? _projectId = widget.initialProjectId;
  UnitStatus? _status;
  String _query = '';
  _UnitsView _view = _UnitsView.list;

  Future<void> _add() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => UnitFormDialog(projectId: _projectId),
    );
    if (saved == true) ref.bumpR(const [RKind.units]);
  }

  Future<void> _bulk() async {
    final saved = await showDialog<int>(
      context: context,
      builder: (_) => BulkUnitsDialog(projectId: _projectId),
    );
    if (saved != null) {
      ref.bumpR(const [RKind.units]);
      if (mounted) showSuccess(context, 'Added $saved units');
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final manage = perms.can(RePerm.unitsManage);
    return CGate(
      anyOf: const [RePerm.unitsView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Units',
            actions: [
              if (manage)
                OutlinedButton.icon(
                  style: bigButton,
                  onPressed: _bulk,
                  icon: const Icon(Icons.library_add_outlined),
                  label: const Text('Bulk add'),
                ),
              if (manage)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                  label: const Text('Add unit'),
                ),
            ],
          ),
          FilterBar(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280, minWidth: 200),
                child: ProjectField(
                  required: false,
                  value: _projectId,
                  onChanged: (id) => setState(() => _projectId = id),
                ),
              ),
              SegmentedButton<_UnitsView>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: _UnitsView.list,
                    icon: Icon(Icons.view_list_outlined),
                    label: Text('List'),
                  ),
                  ButtonSegment(
                    value: _UnitsView.stacking,
                    icon: Icon(Icons.grid_view_outlined),
                    label: Text('Stacking'),
                  ),
                ],
                selected: {_view},
                onSelectionChanged: (s) => setState(() => _view = s.first),
              ),
              if (_view == _UnitsView.list) ...[
                StatusChips<UnitStatus>(
                  value: _status,
                  options: {for (final s in UnitStatus.values) s: s.label},
                  onChanged: (s) => setState(() => _status = s),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: SearchField(
                    hintText: 'Search unit code',
                    onChanged: (q) => setState(() => _query = q),
                  ),
                ),
              ],
            ],
          ),
          Expanded(
            child: _view == _UnitsView.list
                ? UnitList(
                    projectId: _projectId,
                    status: _status,
                    query: _query,
                    onTap: (u) => showUnitActions(context, ref, u),
                  )
                : _projectId == null
                ? const EmptyView(
                    icon: Icons.apartment_outlined,
                    message: 'Choose a project to see its stacking plan.',
                  )
                : UnitStacking(
                    projectId: _projectId!,
                    onTap: (u) => showUnitActions(context, ref, u),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Paged unit list.
class UnitList extends ConsumerStatefulWidget {
  const UnitList({
    super.key,
    this.projectId,
    this.status,
    this.query = '',
    this.onTap,
  });

  final String? projectId;
  final UnitStatus? status;
  final String query;
  final void Function(Unit unit)? onTap;

  @override
  ConsumerState<UnitList> createState() => _UnitListState();
}

class _UnitListState extends ConsumerState<UnitList> {
  late final PagedController<Unit> _paged = PagedController(
    (offset, limit) => ref
        .read(realEstateRepositoryProvider)
        .units(
          projectId: widget.projectId,
          status: widget.status,
          q: widget.query,
          offset: offset,
          limit: limit,
        ),
  );

  @override
  void initState() {
    super.initState();
    _paged.refresh();
  }

  @override
  void didUpdateWidget(UnitList old) {
    super.didUpdateWidget(old);
    if (old.projectId != widget.projectId ||
        old.status != widget.status ||
        old.query != widget.query) {
      _paged.refresh();
    }
  }

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(rRevisionProvider(RKind.units), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    return AdaptiveDataList<Unit>(
      controller: _paged,
      emptyMessage: 'No units found.',
      emptyIcon: Icons.meeting_room_outlined,
      onTap: widget.onTap,
      columns: [
        TableColumnSpec('Unit', (u) => Text(u.code)),
        TableColumnSpec('Project', (u) => Text(u.projectName), maxWidth: 200),
        TableColumnSpec('Type', (u) => Text(u.unitType)),
        TableColumnSpec('Wing', (u) => Text(u.wing ?? '—')),
        TableColumnSpec(
          'Floor',
          (u) => Text(u.floor?.toString() ?? '—'),
          numeric: true,
        ),
        TableColumnSpec(
          'Carpet m²',
          (u) => Text(formatQty(u.carpetArea)),
          numeric: true,
        ),
        TableColumnSpec(
          'List price',
          (u) => Text(formatMoney(u.listPrice)),
          numeric: true,
        ),
        TableColumnSpec('Status', (u) => unitStatusPill(u.status)),
      ],
      cardBuilder: (context, u) => CListCard(
        onTap: widget.onTap == null ? null : () => widget.onTap!(u),
        title: u.code,
        trailing: formatMoney(u.listPrice),
        subtitle: '${u.unitType} · ${formatQty(u.carpetArea)} m²',
        details: [
          [
            u.projectName,
            if (u.wing != null) 'Wing ${u.wing}',
            if (u.floor != null) 'Floor ${u.floor}',
          ].where((e) => e.isNotEmpty).join(' · '),
        ],
        pills: unitStatusPill(u.status),
      ),
    );
  }
}

/// Wing × floor grid of coloured unit chips for one project.
class UnitStacking extends ConsumerWidget {
  const UnitStacking({super.key, required this.projectId, this.onTap});

  final String projectId;
  final void Function(Unit unit)? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lookup = ref.watch(projectUnitsProvider(projectId));
    return AsyncValueView(
      value: lookup,
      onRetry: () => ref.invalidate(projectUnitsProvider(projectId)),
      data: (units) {
        if (units.isEmpty) {
          return const EmptyView(
            icon: Icons.meeting_room_outlined,
            message: 'This project has no units yet.',
          );
        }
        final wings = <String, List<Unit>>{};
        for (final u in units) {
          wings.putIfAbsent(u.wing ?? '', () => []).add(u);
        }
        final names = wings.keys.toList()..sort();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [for (final s in UnitStatus.values) LegendDot(s)],
            ),
            const SizedBox(height: 12),
            for (final name in names)
              _WingCard(wing: name, units: wings[name]!, onTap: onTap),
          ],
        );
      },
    );
  }
}

class _WingCard extends StatelessWidget {
  const _WingCard({required this.wing, required this.units, this.onTap});

  final String wing;
  final List<Unit> units;
  final void Function(Unit unit)? onTap;

  @override
  Widget build(BuildContext context) {
    final byFloor = <int?, List<Unit>>{};
    for (final u in units) {
      byFloor.putIfAbsent(u.floor, () => []).add(u);
    }
    // Top floor first, like the building; units without a floor last.
    final floors = byFloor.keys.toList()
      ..sort((a, b) {
        if (a == null) return 1;
        if (b == null) return -1;
        return b.compareTo(a);
      });
    final sold = units.where((u) => !u.status.bookable).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SectionCard(
        title: wing.isEmpty
            ? 'Units ($sold of ${units.length} booked)'
            : 'Wing $wing ($sold of ${units.length} booked)',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final floor in floors)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 48,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          floor == null ? '—' : 'F$floor',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final u in byFloor[floor]!)
                            _UnitChip(unit: u, onTap: onTap),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _UnitChip extends StatelessWidget {
  const _UnitChip({required this.unit, this.onTap});

  final Unit unit;
  final void Function(Unit unit)? onTap;

  @override
  Widget build(BuildContext context) {
    final color = unit.status.color;
    final theme = Theme.of(context);
    return Tooltip(
      message:
          '${unit.code} · ${unit.unitType} · ${unit.status.label} · '
          '${formatMoney(unit.listPrice)}',
      child: Material(
        color: color.withValues(alpha: 0.14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: color, width: 1.5),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap == null ? null : () => onTap!(unit),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 76, minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    unit.code,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(unit.unitType, style: theme.textTheme.labelSmall),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Details of a unit with the actions the user may take.
Future<void> showUnitActions(BuildContext context, WidgetRef ref, Unit unit) {
  final perms = ref.read(permissionsProvider);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Unit ${unit.code}'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            unitStatusPill(unit.status),
            const SizedBox(height: 12),
            FactsWrap(
              facts: [
                ('Project', unit.projectName),
                ('Type', unit.unitType),
                if (unit.wing != null) ('Wing', unit.wing!),
                if (unit.floor != null) ('Floor', '${unit.floor}'),
                ('Carpet area', '${formatQty(unit.carpetArea)} m²'),
                if (unit.balconyArea != null)
                  ('Balcony', '${formatQty(unit.balconyArea)} m²'),
                ('List price', formatMoney(unit.listPrice)),
              ],
            ),
            if ((unit.notes ?? '').isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(unit.notes!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
        if (unit.bookingId != null && perms.can(RePerm.bookingsView))
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              context.go('/bookings/${unit.bookingId}');
            },
            child: const Text('Open booking'),
          ),
        if (perms.can(RePerm.unitsManage) && unit.status.togglesHold)
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              final hold = unit.status == UnitStatus.available;
              final ok = await guarded(
                context,
                () => ref
                    .read(realEstateRepositoryProvider)
                    .setUnitHold(unit.id, hold),
              );
              if (ok) ref.bumpR(const [RKind.units]);
            },
            child: Text(
              unit.status == UnitStatus.available ? 'Hold' : 'Release hold',
            ),
          ),
        if (perms.can(RePerm.unitsManage))
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              final saved = await showDialog<bool>(
                context: context,
                builder: (_) =>
                    UnitFormDialog(projectId: unit.projectId, unit: unit),
              );
              if (saved == true) ref.bumpR(const [RKind.units]);
            },
            child: const Text('Edit'),
          ),
        if (perms.can(RePerm.bookingsManage) && unit.status.bookable)
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              context.go('/bookings/new?unitId=${unit.id}');
            },
            child: const Text('Book'),
          ),
      ],
    ),
  );
}

/// Create or edit one unit. Pops `true` when saved.
class UnitFormDialog extends ConsumerStatefulWidget {
  const UnitFormDialog({super.key, this.projectId, this.unit});

  final String? projectId;
  final Unit? unit;

  @override
  ConsumerState<UnitFormDialog> createState() => _UnitFormDialogState();
}

class _UnitFormDialogState extends ConsumerState<UnitFormDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late String? _projectId = widget.projectId;
  late final _code = TextEditingController(text: widget.unit?.code);
  late final _wing = TextEditingController(text: widget.unit?.wing);
  late final _floor = TextEditingController(
    text: widget.unit?.floor?.toString(),
  );
  late final _type = TextEditingController(text: widget.unit?.unitType);
  late final _carpet = TextEditingController(
    text: widget.unit == null ? '' : formatPlain(widget.unit!.carpetArea),
  );
  late final _balcony = TextEditingController(
    text: widget.unit?.balconyArea == null
        ? ''
        : formatPlain(widget.unit!.balconyArea),
  );
  late final _price = TextEditingController(
    text: widget.unit == null ? '' : formatPlain(widget.unit!.listPrice),
  );
  late final _notes = TextEditingController(text: widget.unit?.notes);
  bool _saving = false;

  bool get _editing => widget.unit != null;

  @override
  void dispose() {
    for (final c in [
      _code,
      _wing,
      _floor,
      _type,
      _carpet,
      _balcony,
      _price,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!_formKey.currentState!.validate()) return;
    final body = <String, dynamic>{
      'code': _code.text.trim(),
      'wing': trimmedOrNull(_wing.text),
      'floor': int.tryParse(_floor.text.trim()),
      'unitType': _type.text.trim(),
      'carpetArea': parseNumber(_carpet.text),
      'balconyArea': parseNumber(_balcony.text),
      'listPrice': parseNumber(_price.text) ?? 0,
      'notes': trimmedOrNull(_notes.text),
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(realEstateRepositoryProvider);
      final original = widget.unit;
      if (original == null) {
        await repo.createUnit(_projectId!, body);
      } else {
        final before = original.toInputJson();
        final changes = changedFields(before, body);
        if (changes.isNotEmpty) await repo.updateUnit(original.id, changes);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _text(
    String key,
    TextEditingController c,
    String label, {
    String? Function(String?)? validator,
    TextInputType? keyboard,
    List<TextInputFormatter>? formatters,
    TextCapitalization caps = TextCapitalization.none,
    int maxLines = 1,
  }) => TextFormField(
    controller: c,
    decoration: InputDecoration(labelText: label),
    keyboardType: keyboard,
    inputFormatters: formatters,
    textCapitalization: caps,
    maxLines: maxLines,
    forceErrorText: serverError(key),
    onChanged: (_) => clearServerError(key),
    validator: validator,
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_editing ? 'Edit unit ${widget.unit!.code}' : 'Add unit'),
    scrollable: true,
    content: SizedBox(
      width: 520,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_editing) ...[
              ProjectField(
                value: _projectId,
                onChanged: (id) => setState(() => _projectId = id),
              ),
              const SizedBox(height: 16),
            ],
            FormRow(
              breakpoint: 440,
              children: [
                _text(
                  'code',
                  _code,
                  'Unit code',
                  caps: TextCapitalization.characters,
                  validator: (v) => requiredField(v, 'Code'),
                ),
                _text(
                  'unitType',
                  _type,
                  'Type (2 BHK)',
                  validator: (v) => requiredField(v, 'Type'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FormRow(
              breakpoint: 440,
              children: [
                _text(
                  'wing',
                  _wing,
                  'Wing (optional)',
                  caps: TextCapitalization.characters,
                ),
                _text(
                  'floor',
                  _floor,
                  'Floor (optional)',
                  keyboard: TextInputType.number,
                  formatters: [FilteringTextInputFormatter.digitsOnly],
                ),
              ],
            ),
            const SizedBox(height: 16),
            FormRow(
              breakpoint: 440,
              children: [
                _text(
                  'carpetArea',
                  _carpet,
                  'Carpet area (m²)',
                  keyboard: decimalKeyboard,
                  formatters: [decimalInput()],
                  validator: (v) =>
                      requiredNumber(v, label: 'Carpet area', min: 0.01),
                ),
                _text(
                  'balconyArea',
                  _balcony,
                  'Balcony area (m², optional)',
                  keyboard: decimalKeyboard,
                  formatters: [decimalInput()],
                ),
              ],
            ),
            const SizedBox(height: 16),
            _text(
              'listPrice',
              _price,
              'List price (₹)',
              keyboard: decimalKeyboard,
              formatters: [decimalInput()],
            ),
            const SizedBox(height: 16),
            _text('notes', _notes, 'Notes (optional)', maxLines: 2),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      BusyButton(busy: _saving, onPressed: _save, label: 'Save'),
    ],
  );
}

/// Bulk add: wing, floors and units per floor make codes like `A-101`.
/// Pops the number of units added.
class BulkUnitsDialog extends ConsumerStatefulWidget {
  const BulkUnitsDialog({super.key, this.projectId});

  final String? projectId;

  @override
  ConsumerState<BulkUnitsDialog> createState() => _BulkUnitsDialogState();
}

class _BulkUnitsDialogState extends ConsumerState<BulkUnitsDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late String? _projectId = widget.projectId;
  final _wing = TextEditingController();
  final _first = TextEditingController(text: '1');
  final _floors = TextEditingController(text: '5');
  final _perFloor = TextEditingController(text: '4');
  final _type = TextEditingController(text: '2 BHK');
  final _carpet = TextEditingController();
  final _price = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [
      _wing,
      _first,
      _floors,
      _perFloor,
      _type,
      _carpet,
      _price,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  List<({String code, int floor})> get _codes => generateUnitCodes(
    wing: _wing.text,
    firstFloor: int.tryParse(_first.text.trim()) ?? 1,
    floors: int.tryParse(_floors.text.trim()) ?? 0,
    unitsPerFloor: int.tryParse(_perFloor.text.trim()) ?? 0,
  );

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final codes = _codes;
    final wing = trimmedOrNull(_wing.text.toUpperCase());
    final carpet = parseNumber(_carpet.text);
    final price = parseNumber(_price.text) ?? 0;
    setState(() => _saving = true);
    try {
      final created = await ref.read(realEstateRepositoryProvider).createUnits(
        _projectId!,
        [
          for (final c in codes)
            {
              'code': c.code,
              'wing': wing,
              'floor': c.floor,
              'unitType': _type.text.trim(),
              'carpetArea': carpet,
              'listPrice': price,
            },
        ],
      );
      if (mounted) Navigator.of(context).pop(created.length);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _count(String? v, String label, {int max = 100}) {
    final n = int.tryParse((v ?? '').trim());
    if (n == null || n < 1) return '$label must be at least 1';
    if (n > max) return 'At most $max';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final codes = _codes;
    final tooMany = codes.length > kMaxBulkUnits;
    final preview = codes.isEmpty
        ? 'Enter floors and units per floor'
        : tooMany
        ? '${codes.length} units is too many; the limit is $kMaxBulkUnits'
        : '${codes.length} units: ${codes.first.code} … ${codes.last.code}';
    return AlertDialog(
      title: const Text('Add units in bulk'),
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ProjectField(
                value: _projectId,
                onChanged: (id) => setState(() => _projectId = id),
              ),
              const SizedBox(height: 16),
              FormRow(
                breakpoint: 440,
                children: [
                  TextFormField(
                    controller: _wing,
                    decoration: const InputDecoration(
                      labelText: 'Wing (optional)',
                    ),
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) => setState(() {}),
                  ),
                  TextFormField(
                    controller: _first,
                    decoration: const InputDecoration(labelText: 'First floor'),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setState(() {}),
                    validator: (v) => int.tryParse((v ?? '').trim()) == null
                        ? 'Enter a floor number'
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FormRow(
                breakpoint: 440,
                children: [
                  TextFormField(
                    controller: _floors,
                    decoration: const InputDecoration(labelText: 'Floors'),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setState(() {}),
                    validator: (v) => _count(v, 'Floors', max: 200),
                  ),
                  TextFormField(
                    controller: _perFloor,
                    decoration: const InputDecoration(
                      labelText: 'Units per floor',
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setState(() {}),
                    validator: (v) => _count(v, 'Units per floor', max: 99),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                preview,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: tooMany
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _type,
                decoration: const InputDecoration(labelText: 'Type'),
                validator: (v) => requiredField(v, 'Type'),
              ),
              const SizedBox(height: 16),
              FormRow(
                breakpoint: 440,
                children: [
                  TextFormField(
                    controller: _carpet,
                    decoration: const InputDecoration(
                      labelText: 'Carpet area (m²)',
                    ),
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput()],
                    validator: (v) =>
                        requiredNumber(v, label: 'Carpet area', min: 0.01),
                  ),
                  TextFormField(
                    controller: _price,
                    decoration: const InputDecoration(
                      labelText: 'List price (₹)',
                    ),
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput()],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        BusyButton(
          busy: _saving,
          onPressed: tooMany || codes.isEmpty ? null : _save,
          label: 'Add units',
        ),
      ],
    );
  }
}
