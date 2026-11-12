import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'hotel_models.dart';
import 'hotel_repository.dart';
import 'hotel_widgets.dart';

/// `/hotel/setup`: room types, rooms and rate plans.
class HotelSetupScreen extends ConsumerWidget {
  const HotelSetupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = ref.watch(permissionsProvider).can(Perm.hotelManage);
    return CGate(
      anyOf: const [Perm.hotelView],
      child: DefaultTabController(
        length: 3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PageHeader(title: 'Room and rate setup'),
            const TabBar(
              tabs: [
                Tab(text: 'Room types'),
                Tab(text: 'Rooms'),
                Tab(text: 'Rate plans'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _TypesTab(manage: manage),
                  _RoomsTab(manage: manage),
                  _PlansTab(manage: manage),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _addButton(String label, VoidCallback onTap) => Align(
  alignment: Alignment.centerLeft,
  child: FilledButton.icon(
    style: bigButton,
    onPressed: onTap,
    icon: const Icon(Icons.add),
    label: Text(label),
  ),
);

Widget _row(BuildContext context, String title, String sub, {Widget? trailing, VoidCallback? onTap}) =>
    InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    Text(sub, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );

class _TypesTab extends ConsumerWidget {
  const _TypesTab({required this.manage});

  final bool manage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(hotelRoomTypesProvider);
    Future<void> edit(RoomType? t) async {
      final saved = await showFormDialog<bool>(
        context: context,
        builder: (_) => _TypeDialog(type: t),
      );
      if (saved == true) ref.bumpHotel();
    }

    return AsyncValueView<List<RoomType>>(
      value: list,
      onRetry: () => ref.invalidate(hotelRoomTypesProvider),
      data: (types) => ListView(
        padding: EdgeInsets.all(pageGutter(context)),
        children: [
          if (manage) _addButton('Add room type', () => edit(null)),
          if (types.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No room types yet.')),
          for (final t in types)
            _row(
              context,
              t.name + (t.isActive ? '' : '  (not in use)'),
              '${formatMoney(t.baseTariff)} per night  |  ${t.baseOccupancy} to ${t.maxOccupancy} guests  |  extra person ${formatMoney(t.extraPersonCharge)}  |  ${t.roomCount} rooms',
              onTap: manage ? () => edit(t) : null,
            ),
        ],
      ),
    );
  }
}

class _TypeDialog extends ConsumerStatefulWidget {
  const _TypeDialog({this.type});

  final RoomType? type;

  @override
  ConsumerState<_TypeDialog> createState() => _TypeDialogState();
}

class _TypeDialogState extends ConsumerState<_TypeDialog> {
  late final _name = TextEditingController(text: widget.type?.name ?? '');
  late final _tariff = TextEditingController(text: widget.type == null ? '' : formatPlain(widget.type!.baseTariff));
  late final _extra = TextEditingController(text: widget.type == null ? '0' : formatPlain(widget.type!.extraPersonCharge));
  late final _base = TextEditingController(text: '${widget.type?.baseOccupancy ?? 2}');
  late final _max = TextEditingController(text: '${widget.type?.maxOccupancy ?? 3}');
  late bool _active = widget.type?.isActive ?? true;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _tariff, _extra, _base, _max]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || parseNumber(_tariff.text) == null) {
      showErrorSnackBar(context, 'Enter a name and the base tariff.');
      return;
    }
    setState(() => _saving = true);
    try {
      final Json body = {
        'name': _name.text.trim(),
        'baseTariff': parseNumber(_tariff.text),
        'extraPersonCharge': parseNumber(_extra.text) ?? 0,
        'baseOccupancy': int.tryParse(_base.text) ?? 2,
        'maxOccupancy': int.tryParse(_max.text) ?? 3,
        'isActive': _active,
        if (widget.type?.updatedAt != null) 'expectedUpdatedAt': widget.type!.updatedAt,
      };
      await ref.read(hotelRepositoryProvider).saveRoomType(widget.type?.id, body);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.type == null ? 'Add room type' : 'Edit room type'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 12),
            FormRow(
              minCellWidth: 150,
              children: [
                TextField(
                  controller: _tariff,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  decoration: const InputDecoration(labelText: 'Base tariff per night'),
                ),
                TextField(
                  controller: _extra,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  decoration: const InputDecoration(labelText: 'Extra person charge'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FormRow(
              minCellWidth: 150,
              children: [
                TextField(
                  controller: _base,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Base occupancy'),
                ),
                TextField(
                  controller: _max,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Max occupancy'),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('In use'),
              value: _active,
              onChanged: _saving ? null : (v) => setState(() => _active = v),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      BusyButton(busy: _saving, onPressed: _saving ? null : _save, label: 'Save'),
    ],
  );
}

class _RoomsTab extends ConsumerWidget {
  const _RoomsTab({required this.manage});

  final bool manage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(hotelRoomsProvider);
    final types = ref.watch(hotelRoomTypesProvider).value ?? const <RoomType>[];
    Future<void> edit(Room? r) async {
      final saved = await showFormDialog<bool>(
        context: context,
        builder: (_) => _RoomDialog(room: r, types: types),
      );
      if (saved == true) ref.bumpHotel();
    }

    return AsyncValueView<List<Room>>(
      value: list,
      onRetry: () => ref.invalidate(hotelRoomsProvider),
      data: (rooms) => ListView(
        padding: EdgeInsets.all(pageGutter(context)),
        children: [
          if (manage) _addButton('Add room', () => edit(null)),
          if (rooms.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No rooms yet.')),
          for (final r in rooms)
            _row(
              context,
              'Room ${r.number}${r.isActive ? '' : '  (not in use)'}',
              [r.type, if (r.floor != null) 'Floor ${r.floor}'].join('  |  '),
              trailing: RoomStatusChip(r.status),
              onTap: manage ? () => edit(r) : null,
            ),
        ],
      ),
    );
  }
}

class _RoomDialog extends ConsumerStatefulWidget {
  const _RoomDialog({this.room, required this.types});

  final Room? room;
  final List<RoomType> types;

  @override
  ConsumerState<_RoomDialog> createState() => _RoomDialogState();
}

class _RoomDialogState extends ConsumerState<_RoomDialog> {
  late final _number = TextEditingController(text: widget.room?.number ?? '');
  late final _floor = TextEditingController(text: widget.room?.floor ?? '');
  late String? _typeId = widget.room?.roomTypeId;
  late bool _active = widget.room?.isActive ?? true;
  bool _saving = false;

  @override
  void dispose() {
    _number.dispose();
    _floor.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_number.text.trim().isEmpty || _typeId == null) {
      showErrorSnackBar(context, 'Enter the room number and choose a type.');
      return;
    }
    setState(() => _saving = true);
    try {
      final Json body = {
        'number': _number.text.trim(),
        'roomTypeId': _typeId,
        'floor': widget.room == null ? trimmedOrNull(_floor.text) : _floor.text.trim(),
        if (widget.room != null) 'isActive': _active,
        if (widget.room?.updatedAt != null) 'expectedUpdatedAt': widget.room!.updatedAt,
      };
      await ref.read(hotelRepositoryProvider).saveRoom(widget.room?.id, body);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.room == null ? 'Add room' : 'Edit room'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormRow(
              minCellWidth: 150,
              children: [
                TextField(controller: _number, decoration: const InputDecoration(labelText: 'Room number')),
                TextField(controller: _floor, decoration: const InputDecoration(labelText: 'Floor')),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _typeId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Room type'),
              items: [
                for (final t in widget.types.where((t) => t.isActive || t.id == _typeId))
                  DropdownMenuItem(value: t.id, child: Text(t.name)),
              ],
              onChanged: (v) => setState(() => _typeId = v),
            ),
            if (widget.room != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('In use'),
                value: _active,
                onChanged: _saving ? null : (v) => setState(() => _active = v),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      BusyButton(busy: _saving, onPressed: _saving ? null : _save, label: 'Save'),
    ],
  );
}

class _PlansTab extends ConsumerWidget {
  const _PlansTab({required this.manage});

  final bool manage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(hotelRatePlansProvider);
    final types = ref.watch(hotelRoomTypesProvider).value ?? const <RoomType>[];
    Future<void> edit(RatePlan? p) async {
      final saved = await showFormDialog<bool>(
        context: context,
        builder: (_) => _PlanDialog(plan: p, types: types),
      );
      if (saved == true) ref.bumpHotel();
    }

    return AsyncValueView<List<RatePlan>>(
      value: list,
      onRetry: () => ref.invalidate(hotelRatePlansProvider),
      data: (plans) => ListView(
        padding: EdgeInsets.all(pageGutter(context)),
        children: [
          if (manage) _addButton('Add rate plan', () => edit(null)),
          if (plans.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No rate plans. Rooms use the room type tariff.')),
          for (final p in plans)
            _row(
              context,
              p.name + (p.isActive ? '' : '  (not in use)'),
              '${types.where((t) => t.id == p.roomTypeId).map((t) => t.name).join()}  |  ${p.meal == 'breakfast' ? 'With breakfast' : 'Room only'}  |  weekday ${formatMoney(p.weekdayTariff)}, weekend ${formatMoney(p.weekendTariff)}',
              onTap: manage ? () => edit(p) : null,
            ),
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('Friday and Saturday nights use the weekend tariff.'),
          ),
        ],
      ),
    );
  }
}

class _PlanDialog extends ConsumerStatefulWidget {
  const _PlanDialog({this.plan, required this.types});

  final RatePlan? plan;
  final List<RoomType> types;

  @override
  ConsumerState<_PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends ConsumerState<_PlanDialog> {
  late final _name = TextEditingController(text: widget.plan?.name ?? '');
  late final _weekday = TextEditingController(text: widget.plan == null ? '' : formatPlain(widget.plan!.weekdayTariff));
  late final _weekend = TextEditingController(text: widget.plan == null ? '' : formatPlain(widget.plan!.weekendTariff));
  late String? _typeId = widget.plan?.roomTypeId;
  late String _meal = widget.plan?.meal ?? 'room_only';
  late bool _active = widget.plan?.isActive ?? true;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _weekday, _weekend]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final wd = parseNumber(_weekday.text);
    final we = parseNumber(_weekend.text);
    if (_name.text.trim().isEmpty || _typeId == null || wd == null || we == null) {
      showErrorSnackBar(context, 'Fill in the name, room type and both tariffs.');
      return;
    }
    setState(() => _saving = true);
    try {
      final Json body = {
        'name': _name.text.trim(),
        'roomTypeId': _typeId,
        'meal': _meal,
        'weekdayTariff': wd,
        'weekendTariff': we,
        'isActive': _active,
        if (widget.plan?.updatedAt != null) 'expectedUpdatedAt': widget.plan!.updatedAt,
      };
      await ref.read(hotelRepositoryProvider).saveRatePlan(widget.plan?.id, body);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.plan == null ? 'Add rate plan' : 'Edit rate plan'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _typeId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Room type'),
              items: [
                for (final t in widget.types)
                  DropdownMenuItem(value: t.id, child: Text(t.name)),
              ],
              onChanged: (v) => setState(() => _typeId = v),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _meal,
              decoration: const InputDecoration(labelText: 'Meals'),
              items: const [
                DropdownMenuItem(value: 'room_only', child: Text('Room only')),
                DropdownMenuItem(value: 'breakfast', child: Text('With breakfast')),
              ],
              onChanged: (v) => setState(() => _meal = v ?? 'room_only'),
            ),
            const SizedBox(height: 12),
            FormRow(
              minCellWidth: 150,
              children: [
                TextField(
                  controller: _weekday,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  decoration: const InputDecoration(labelText: 'Weekday tariff'),
                ),
                TextField(
                  controller: _weekend,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  decoration: const InputDecoration(labelText: 'Weekend tariff'),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('In use'),
              value: _active,
              onChanged: _saving ? null : (v) => setState(() => _active = v),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      BusyButton(busy: _saving, onPressed: _saving ? null : _save, label: 'Save'),
    ],
  );
}
