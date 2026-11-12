import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'hotel_models.dart';
import 'hotel_repository.dart';
import 'hotel_widgets.dart';

const _idTypes = {
  'aadhaar': 'Aadhaar',
  'passport': 'Passport',
  'driving_licence': 'Driving licence',
  'voter_id': 'Voter ID',
  'pan': 'PAN',
  'other': 'Other',
};

class _GuestForm {
  _GuestForm(BookedRoom room, String defaultName, String? defaultPhone)
    : roomId = room.roomId,
      name = TextEditingController(text: room.guest?.name ?? defaultName),
      phone = TextEditingController(text: room.guest?.phone ?? defaultPhone ?? ''),
      address = TextEditingController(text: room.guest?.address ?? ''),
      idNumber = TextEditingController(text: room.guest?.idNumber ?? ''),
      nationality = TextEditingController(text: room.guest?.nationality ?? 'Indian'),
      passport = TextEditingController(text: room.guest?.passportNo ?? ''),
      visaNo = TextEditingController(text: room.guest?.visaNo ?? ''),
      visaType = TextEditingController(text: room.guest?.visaType ?? ''),
      visaExpiry = TextEditingController(text: room.guest?.visaExpiry ?? ''),
      from = TextEditingController(text: room.guest?.arrivedFrom ?? ''),
      goingTo = TextEditingController(text: room.guest?.goingTo ?? ''),
      purpose = TextEditingController(text: room.guest?.purpose ?? ''),
      idType = room.guest?.idType ?? 'aadhaar';

  String? roomId;
  String idType;
  final TextEditingController name, phone, address, idNumber, nationality;
  final TextEditingController passport, visaNo, visaType, visaExpiry;
  final TextEditingController from, goingTo, purpose;

  bool get foreign {
    final n = nationality.text.trim().toLowerCase();
    return n.isNotEmpty && n != 'indian' && n != 'india';
  }

  void dispose() {
    for (final c in [
      name, phone, address, idNumber, nationality, passport, visaNo,
      visaType, visaExpiry, from, goingTo, purpose,
    ]) {
      c.dispose();
    }
  }

  String? problem() {
    if (name.text.trim().isEmpty) return 'Enter the guest name.';
    if (roomId == null) return 'Assign a room.';
    if (idNumber.text.trim().isEmpty) return 'Enter the ID number.';
    if (foreign &&
        (passport.text.trim().isEmpty ||
            visaNo.text.trim().isEmpty ||
            visaExpiry.text.trim().isEmpty)) {
      return 'A foreign guest needs passport number, visa number and visa expiry (YYYY-MM-DD).';
    }
    return null;
  }
}

/// `/hotel/reservations/:id/check-in`: room assignment and a registration
/// card for each room.
class CheckInScreen extends ConsumerStatefulWidget {
  const CheckInScreen({super.key, required this.reservationId});

  final String reservationId;

  @override
  ConsumerState<CheckInScreen> createState() => _CheckInScreenState();
}

class _CheckInScreenState extends ConsumerState<CheckInScreen> {
  List<_GuestForm>? _forms;
  bool _saving = false;

  @override
  void dispose() {
    for (final f in _forms ?? const <_GuestForm>[]) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _save(Reservation r) async {
    final forms = _forms!;
    for (final (i, f) in forms.indexed) {
      final p = f.problem();
      if (p != null) {
        showErrorSnackBar(context, forms.length > 1 ? 'Room ${i + 1}: $p' : p);
        return;
      }
    }
    setState(() => _saving = true);
    try {
      await ref.read(hotelRepositoryProvider).checkIn(r.id, {
        'rooms': [
          for (final (i, f) in forms.indexed)
            {
              'id': r.rooms[i].id,
              'roomId': f.roomId,
              'guest': {
                'name': f.name.text.trim(),
                'phone': trimmedOrNull(f.phone.text),
                'address': trimmedOrNull(f.address.text),
                'idType': f.idType,
                'idNumber': f.idNumber.text.trim(),
                'nationality': trimmedOrNull(f.nationality.text),
                if (f.foreign) ...{
                  'passportNo': trimmedOrNull(f.passport.text),
                  'visaNo': trimmedOrNull(f.visaNo.text),
                  'visaType': trimmedOrNull(f.visaType.text),
                  'visaExpiry': trimmedOrNull(f.visaExpiry.text),
                },
                'arrivedFrom': trimmedOrNull(f.from.text),
                'goingTo': trimmedOrNull(f.goingTo.text),
                'purpose': trimmedOrNull(f.purpose.text),
              },
            },
        ],
      });
      if (!mounted) return;
      ref.bumpHotel();
      showSuccess(context, '${r.guestName} checked in');
      context.go('/hotel/reservations/${r.id}');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final res = ref.watch(hotelReservationProvider(widget.reservationId));
    final rooms = ref.watch(hotelRoomsProvider).value ?? const <Room>[];
    return CGate(
      anyOf: const [Perm.hotelFrontOffice, Perm.hotelManage],
      child: AsyncValueView<Reservation>(
        value: res,
        onRetry: () => ref.invalidate(hotelReservationProvider(widget.reservationId)),
        data: (r) {
          if (!r.canCheckIn) {
            return EmptyView(
              icon: Icons.info_outline,
              message: 'This reservation is ${resStatusLabel(r.status).toLowerCase()}.',
              action: TextButton(
                onPressed: () => context.go('/hotel/reservations/${r.id}'),
                child: const Text('Open reservation'),
              ),
            );
          }
          _forms ??= [for (final b in r.rooms) _GuestForm(b, r.guestName, r.guestPhone)];
          final forms = _forms!;
          final theme = Theme.of(context);
          return FormPage(
            bottomBar: FormActionBar(
              children: [
                TextButton(
                  onPressed: _saving ? null : () => context.go('/hotel/reservations/${r.id}'),
                  child: const Text('Cancel'),
                ),
                BusyButton(
                  busy: _saving,
                  onPressed: _saving ? null : () => _save(r),
                  label: 'Check in',
                ),
              ],
            ),
            children: [
              Text('Check in ${r.guestName}', style: theme.textTheme.headlineSmall),
              Text(
                '${r.number}  |  ${shortDate(r.arrival)} to ${shortDate(r.departure)}  |  ${nightsText(r.nights)}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              for (final (i, f) in forms.indexed) ...[
                _RoomGuest(
                  booked: r.rooms[i],
                  form: f,
                  rooms: rooms,
                  index: i,
                  count: forms.length,
                  saving: _saving,
                  onChanged: () => setState(() {}),
                ),
                const SizedBox(height: Space.md),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _RoomGuest extends StatelessWidget {
  const _RoomGuest({
    required this.booked,
    required this.form,
    required this.rooms,
    required this.index,
    required this.count,
    required this.saving,
    required this.onChanged,
  });

  final BookedRoom booked;
  final _GuestForm form;
  final List<Room> rooms;
  final int index;
  final int count;
  final bool saving;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final options = rooms
        .where((r) => r.roomTypeId == booked.roomTypeId && r.isActive)
        .toList();
    return SectionCard(
      title: count > 1 ? 'Room ${index + 1}: ${booked.typeName}' : booked.typeName,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: options.any((r) => r.id == form.roomId) ? form.roomId : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Room'),
            items: [
              for (final r in options)
                DropdownMenuItem(
                  value: r.id,
                  child: Text(
                    'Room ${r.number}  (${roomStatusLabel(r.status)}${r.occupied ? ', guest in' : ''})',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              form.roomId = v;
              onChanged();
            },
          ),
          const SizedBox(height: Space.md),
          FormRow(
            minCellWidth: 180,
            children: [
              TextField(
                controller: form.name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Guest name'),
              ),
              TextField(
                controller: form.phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone'),
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: form.address,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Address'),
          ),
          const SizedBox(height: Space.md),
          FormRow(
            minCellWidth: 180,
            children: [
              DropdownButtonFormField<String>(
                initialValue: form.idType,
                decoration: const InputDecoration(labelText: 'ID type'),
                items: [
                  for (final e in _idTypes.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) {
                  form.idType = v ?? 'aadhaar';
                  onChanged();
                },
              ),
              TextField(
                controller: form.idNumber,
                decoration: const InputDecoration(labelText: 'ID number'),
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: form.nationality,
            onChanged: (_) => onChanged(),
            decoration: const InputDecoration(labelText: 'Nationality'),
          ),
          if (form.foreign) ...[
            const SizedBox(height: Space.md),
            Text(
              'Foreign guest (Form C)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: Space.sm),
            FormRow(
              minCellWidth: 180,
              children: [
                TextField(
                  controller: form.passport,
                  decoration: const InputDecoration(labelText: 'Passport number'),
                ),
                TextField(
                  controller: form.visaNo,
                  decoration: const InputDecoration(labelText: 'Visa number'),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            FormRow(
              minCellWidth: 180,
              children: [
                TextField(
                  controller: form.visaType,
                  decoration: const InputDecoration(labelText: 'Visa type'),
                ),
                TextField(
                  controller: form.visaExpiry,
                  keyboardType: TextInputType.datetime,
                  decoration: const InputDecoration(
                    labelText: 'Visa expiry',
                    helperText: 'YYYY-MM-DD',
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: Space.md),
          FormRow(
            minCellWidth: 150,
            maxColumns: 3,
            children: [
              TextField(
                controller: form.from,
                decoration: const InputDecoration(labelText: 'Coming from'),
              ),
              TextField(
                controller: form.goingTo,
                decoration: const InputDecoration(labelText: 'Going to'),
              ),
              TextField(
                controller: form.purpose,
                decoration: const InputDecoration(labelText: 'Purpose of visit'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
