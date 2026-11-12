import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'hotel_models.dart';
import 'hotel_repository.dart';
import 'hotel_widgets.dart';

/// What one tap does to a room: dirty to clean to inspected, and back to dirty.
({String status, String label})? nextStep(String status) => switch (status) {
  'dirty' => (status: 'clean', label: 'Mark clean'),
  'clean' => (status: 'inspected', label: 'Mark inspected'),
  'inspected' => (status: 'dirty', label: 'Mark dirty'),
  'out_of_order' => (status: 'dirty', label: 'Back in service'),
  _ => null,
};

/// `/hotel/housekeeping`: rooms by status for a phone, one tap per step.
class HousekeepingScreen extends ConsumerStatefulWidget {
  const HousekeepingScreen({super.key});

  @override
  ConsumerState<HousekeepingScreen> createState() => _HousekeepingScreenState();
}

class _HousekeepingScreenState extends ConsumerState<HousekeepingScreen> {
  String _filter = 'all';
  final Set<String> _saving = {};

  Future<void> _set(Room r, String status, {String? reason}) async {
    if (_saving.contains(r.id)) return;
    setState(() => _saving.add(r.id));
    try {
      await ref.read(hotelRepositoryProvider).setRoomStatus(r.id, status, reason: reason);
      if (mounted) ref.bumpHotel();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving.remove(r.id));
    }
  }

  Future<void> _outOfOrder(Room r) async {
    final reason = await showReasonDialog(
      context,
      title: 'Room ${r.number} out of order?',
      message: 'Say what is wrong, for example "Leaking tap".',
      confirmLabel: 'Take out of order',
    );
    if (reason != null) await _set(r, 'out_of_order', reason: reason);
  }

  @override
  Widget build(BuildContext context) {
    final rooms = ref.watch(hotelRoomsProvider);
    final can = ref.watch(permissionsProvider).canAny(const [
      Perm.hotelHousekeeping,
      Perm.hotelManage,
    ]);
    return CGate(
      anyOf: const [Perm.hotelView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Housekeeping'),
          Expanded(
            child: AsyncValueView<List<Room>>(
              value: rooms,
              onRetry: () => ref.invalidate(hotelRoomsProvider),
              data: (all) {
                final active = all.where((r) => r.isActive).toList();
                int count(String s) => active.where((r) => r.status == s).length;
                final shown = _filter == 'all'
                    ? active
                    : active.where((r) => r.status == _filter).toList();
                final gutter = pageGutter(context);
                return Column(
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.symmetric(horizontal: gutter),
                      child: Row(
                        children: [
                          for (final s in const ['all', 'dirty', 'clean', 'inspected', 'out_of_order'])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(
                                  '${s == 'all' ? 'All' : roomStatusLabel(s)}  ${s == 'all' ? active.length : count(s)}',
                                ),
                                selected: _filter == s,
                                onSelected: (_) => setState(() => _filter = s),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    Expanded(
                      child: shown.isEmpty
                          ? const EmptyView(
                              icon: Icons.cleaning_services_outlined,
                              message: 'No rooms in this list.',
                            )
                          : ListView.separated(
                              padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xl),
                              itemCount: shown.length,
                              separatorBuilder: (_, _) => const SizedBox(height: Space.sm),
                              itemBuilder: (_, i) => _RoomTile(
                                room: shown[i],
                                can: can,
                                saving: _saving.contains(shown[i].id),
                                onStep: (s) => _set(shown[i], s),
                                onOutOfOrder: () => _outOfOrder(shown[i]),
                              ),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RoomTile extends StatelessWidget {
  const _RoomTile({
    required this.room,
    required this.can,
    required this.saving,
    required this.onStep,
    required this.onOutOfOrder,
  });

  final Room room;
  final bool can;
  final bool saving;
  final ValueChanged<String> onStep;
  final VoidCallback onOutOfOrder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final step = nextStep(room.status);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(4),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 6, color: roomColour(context, room.status)),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(Space.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('Room ${room.number}', style: theme.textTheme.titleMedium),
                        RoomStatusChip(room.status),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        room.type,
                        if (room.floor != null) 'Floor ${room.floor}',
                        if (room.occupied) 'Guest in: ${room.guest}',
                        if (room.statusReason != null) room.statusReason!,
                      ].join('  |  '),
                      style: theme.textTheme.bodySmall,
                    ),
                    if (can && step != null) ...[
                      const SizedBox(height: Space.sm),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              style: bigButton,
                              onPressed: saving ? null : () => onStep(step.status),
                              child: Text(step.label),
                            ),
                          ),
                          if (room.status != 'out_of_order' && !room.occupied) ...[
                            const SizedBox(width: Space.sm),
                            TextButton(
                              onPressed: saving ? null : onOutOfOrder,
                              child: const Text('Out of order'),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
