import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../accounts/accounts_repository.dart';
import '../auth/session.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'hotel_models.dart';
import 'hotel_repository.dart';
import 'hotel_widgets.dart';

class _RoomEntry {
  String? typeId;
  String? roomId;
  String? ratePlanId;
  int adults = 2;
  int children = 0;
}

/// `/hotel/reservations/new`: a booking for one or more rooms.
class ReservationFormScreen extends ConsumerStatefulWidget {
  const ReservationFormScreen({super.key, this.arrival});

  /// `YYYY-MM-DD` from the room board, if the user tapped a night there.
  final String? arrival;

  @override
  ConsumerState<ReservationFormScreen> createState() =>
      _ReservationFormScreenState();
}

class _ReservationFormScreenState extends ConsumerState<ReservationFormScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _sourceName = TextEditingController();
  final _override = TextEditingController();
  final _advance = TextEditingController();
  final _notes = TextEditingController();
  Party? _party;
  bool _newGuest = true;
  late DateTime _arrival = parseApiDate(widget.arrival) ?? today();
  late DateTime _departure = _arrival.add(const Duration(days: 1));
  final List<_RoomEntry> _rooms = [_RoomEntry()];
  String _source = 'walk_in';
  String _status = 'confirmed';
  String _mode = 'cash';
  String? _accountId;
  bool _saving = false;
  String? _guestError;
  Map<String, int> _free = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFree());
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _sourceName, _override, _advance, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadFree() async {
    if (!_departure.isAfter(_arrival)) return;
    try {
      final list = await ref
          .read(hotelRepositoryProvider)
          .availability(apiDate(_arrival), apiDate(_departure));
      if (mounted) {
        setState(() => _free = {for (final t in list) t.roomTypeId: t.minAvailable});
      }
    } catch (_) {
      // The hint is optional; the server checks again on save.
    }
  }

  void _setArrival(DateTime d) {
    setState(() {
      _arrival = d;
      if (!_departure.isAfter(d)) _departure = d.add(const Duration(days: 1));
    });
    _loadFree();
  }

  Future<void> _pickGuest() async {
    final p = await pickParty(context, ref, type: PartyType.customer);
    if (p != null) {
      setState(() {
        _party = p;
        _guestError = null;
      });
    }
  }

  Future<void> _save() async {
    if (_newGuest && (_name.text.trim().isEmpty || _phone.text.trim().length < 5)) {
      setState(() => _guestError = 'Enter the guest name and a phone number.');
      return;
    }
    if (!_newGuest && _party == null) {
      setState(() => _guestError = 'Choose a guest.');
      return;
    }
    if (_rooms.any((r) => r.typeId == null)) {
      showErrorSnackBar(context, 'Choose a room type for every room.');
      return;
    }
    final advance = parseNumber(_advance.text) ?? 0;
    if (advance > 0 && _accountId == null) {
      showErrorSnackBar(context, 'Choose the account for the advance.');
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await ref.read(hotelRepositoryProvider).createReservation({
        'guest': _newGuest
            ? {'name': _name.text.trim(), 'phone': _phone.text.trim()}
            : {'partyId': _party!.id},
        'arrival': apiDate(_arrival),
        'departure': apiDate(_departure),
        'rooms': [
          for (final e in _rooms)
            {
              'roomTypeId': e.typeId,
              if (e.roomId != null) 'roomId': e.roomId,
              if (e.ratePlanId != null) 'ratePlanId': e.ratePlanId,
              'adults': e.adults,
              'children': e.children,
            },
        ],
        'source': _source,
        'sourceName': trimmedOrNull(_sourceName.text),
        'status': _status,
        'notes': trimmedOrNull(_notes.text),
        if (parseNumber(_override.text) != null)
          'overrideTariff': parseNumber(_override.text),
        if (advance > 0)
          'advance': {'accountId': _accountId, 'mode': _mode, 'amount': advance},
      });
      if (!mounted) return;
      ref.bumpHotel(money: advance > 0);
      showSuccess(context, 'Reservation ${r.number} saved');
      context.go('/hotel/reservations/${r.id}');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final types = (ref.watch(hotelRoomTypesProvider).value ?? const <RoomType>[])
        .where((t) => t.isActive)
        .toList();
    final rooms = ref.watch(hotelRoomsProvider).value ?? const <Room>[];
    final plans = ref.watch(hotelRatePlansProvider).value ?? const <RatePlan>[];
    final accounts = ref.watch(cashBankAccountsProvider).value ?? const [];
    final canPay = ref.watch(permissionsProvider).can(Perm.paymentsCreate);
    final nights = _departure.difference(_arrival).inDays;
    return CGate(
      anyOf: const [Perm.hotelFrontOffice, Perm.hotelManage],
      child: FormPage(
        bottomBar: FormActionBar(
          children: [
            TextButton(
              onPressed: _saving ? null : () => context.go('/hotel'),
              child: const Text('Cancel'),
            ),
            BusyButton(
              busy: _saving,
              onPressed: _saving ? null : _save,
              label: 'Save reservation',
            ),
          ],
        ),
        children: [
          Text('New reservation', style: theme.textTheme.headlineSmall),
          const SizedBox(height: Space.md),
          SectionCard(
            title: 'Guest',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('New guest')),
                    ButtonSegment(value: false, label: Text('Existing guest')),
                  ],
                  selected: {_newGuest},
                  onSelectionChanged: (s) => setState(() {
                    _newGuest = s.first;
                    _guestError = null;
                  }),
                ),
                const SizedBox(height: Space.md),
                if (_newGuest)
                  FormRow(
                    minCellWidth: 180,
                    children: [
                      TextField(
                        controller: _name,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(labelText: 'Guest name'),
                      ),
                      TextField(
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(labelText: 'Phone'),
                      ),
                    ],
                  )
                else
                  OutlinedButton.icon(
                    style: bigOutlinedButton,
                    onPressed: _pickGuest,
                    icon: const Icon(Icons.search),
                    label: Text(_party?.name ?? 'Find guest'),
                  ),
                if (_guestError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _guestError!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: Space.md),
          SectionCard(
            title: 'Stay  ($nights ${nights == 1 ? 'night' : 'nights'})',
            child: FormRow(
              minCellWidth: 180,
              children: [
                DateField(
                  label: 'Arrival',
                  value: _arrival,
                  firstDate: today(),
                  onChanged: _setArrival,
                ),
                DateField(
                  label: 'Departure',
                  value: _departure,
                  firstDate: _arrival.add(const Duration(days: 1)),
                  onChanged: (d) {
                    setState(() => _departure = d);
                    _loadFree();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.md),
          SectionCard(
            title: 'Rooms',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, e) in _rooms.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.md),
                    child: _RoomCard(
                      index: i,
                      entry: e,
                      types: types,
                      rooms: rooms,
                      plans: plans,
                      free: _free,
                      saving: _saving,
                      onChanged: () => setState(() {}),
                      onRemove: _rooms.length == 1
                          ? null
                          : () => setState(() => _rooms.removeAt(i)),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _saving
                        ? null
                        : () => setState(() => _rooms.add(_RoomEntry())),
                    icon: const Icon(Icons.add),
                    label: const Text('Add another room'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.md),
          SectionCard(
            title: 'Booking',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  minCellWidth: 180,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _source,
                      decoration: const InputDecoration(labelText: 'Source'),
                      items: [
                        for (final s in const ['walk_in', 'phone', 'ota', 'agent'])
                          DropdownMenuItem(value: s, child: Text(sourceLabel(s))),
                      ],
                      onChanged: (v) => setState(() => _source = v ?? 'walk_in'),
                    ),
                    TextField(
                      controller: _sourceName,
                      decoration: InputDecoration(
                        labelText: _source == 'ota' ? 'Agent or site name' : 'Source name (optional)',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.md),
                FormRow(
                  minCellWidth: 180,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _status,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: const [
                        DropdownMenuItem(value: 'confirmed', child: Text('Confirmed')),
                        DropdownMenuItem(value: 'tentative', child: Text('Tentative')),
                      ],
                      onChanged: (v) => setState(() => _status = v ?? 'confirmed'),
                    ),
                    TextField(
                      controller: _override,
                      keyboardType: decimalKeyboard,
                      inputFormatters: [decimalInput()],
                      decoration: const InputDecoration(
                        labelText: 'Tariff per night (optional)',
                        helperText: 'Replaces the rate plan for every room',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.md),
                TextField(
                  controller: _notes,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Notes (optional)'),
                ),
              ],
            ),
          ),
          if (canPay) ...[
            const SizedBox(height: Space.md),
            SectionCard(
              title: 'Advance (optional)',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormRow(
                    minCellWidth: 150,
                    children: [
                      TextField(
                        controller: _advance,
                        keyboardType: decimalKeyboard,
                        inputFormatters: [decimalInput()],
                        decoration: const InputDecoration(labelText: 'Amount received'),
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: _mode,
                        decoration: const InputDecoration(labelText: 'Mode'),
                        items: const [
                          DropdownMenuItem(value: 'cash', child: Text('Cash')),
                          DropdownMenuItem(value: 'upi', child: Text('UPI')),
                          DropdownMenuItem(value: 'card', child: Text('Card')),
                          DropdownMenuItem(value: 'bank', child: Text('Bank transfer')),
                        ],
                        onChanged: (v) => setState(() => _mode = v ?? 'cash'),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  DropdownButtonFormField<String>(
                    initialValue: _accountId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Deposit to'),
                    items: [
                      for (final a in accounts)
                        DropdownMenuItem(
                          value: a.id,
                          child: Text(a.name, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => setState(() => _accountId = v),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RoomCard extends StatelessWidget {
  const _RoomCard({
    required this.index,
    required this.entry,
    required this.types,
    required this.rooms,
    required this.plans,
    required this.free,
    required this.saving,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final _RoomEntry entry;
  final List<RoomType> types;
  final List<Room> rooms;
  final List<RatePlan> plans;
  final Map<String, int> free;
  final bool saving;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final typeRooms = rooms
        .where((r) => r.roomTypeId == entry.typeId && r.isActive && r.status != 'out_of_order')
        .toList();
    final typePlans = plans
        .where((p) => p.roomTypeId == entry.typeId && p.isActive)
        .toList();
    final left = entry.typeId == null ? null : free[entry.typeId];
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Room ${index + 1}', style: theme.textTheme.titleSmall),
                ),
                if (left != null)
                  Text(
                    left == 0 ? 'None free' : '$left free',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: left == 0 ? theme.colorScheme.error : null,
                    ),
                  ),
                if (onRemove != null)
                  IconButton(
                    tooltip: 'Remove room ${index + 1}',
                    onPressed: saving ? null : onRemove,
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
            DropdownButtonFormField<String>(
              initialValue: entry.typeId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Room type'),
              items: [
                for (final t in types)
                  DropdownMenuItem(
                    value: t.id,
                    child: Text(
                      '${t.name}  ${formatMoney(t.baseTariff)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                entry
                  ..typeId = v
                  ..roomId = null
                  ..ratePlanId = null;
                onChanged();
              },
            ),
            if (entry.typeId != null) ...[
              const SizedBox(height: Space.md),
              FormRow(
                minCellWidth: 170,
                children: [
                  DropdownButtonFormField<String?>(
                    initialValue: entry.roomId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Room (optional)'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Assign later')),
                      for (final r in typeRooms)
                        DropdownMenuItem(
                          value: r.id,
                          child: Text('Room ${r.number}'),
                        ),
                    ],
                    onChanged: (v) {
                      entry.roomId = v;
                      onChanged();
                    },
                  ),
                  DropdownButtonFormField<String?>(
                    initialValue: entry.ratePlanId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Rate plan'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Standard tariff')),
                      for (final p in typePlans)
                        DropdownMenuItem(
                          value: p.id,
                          child: Text(p.name, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) {
                      entry.ratePlanId = v;
                      onChanged();
                    },
                  ),
                ],
              ),
            ],
            const SizedBox(height: Space.md),
            Wrap(
              spacing: Space.lg,
              runSpacing: Space.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Adults'),
                    CountStepper(
                      value: entry.adults.toDouble(),
                      min: 1,
                      max: 20,
                      label: 'Adults',
                      enabled: !saving,
                      onChanged: (v) {
                        entry.adults = v.round();
                        onChanged();
                      },
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Children'),
                    CountStepper(
                      value: entry.children.toDouble(),
                      min: 0,
                      max: 20,
                      label: 'Children',
                      enabled: !saving,
                      onChanged: (v) {
                        entry.children = v.round();
                        onChanged();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
