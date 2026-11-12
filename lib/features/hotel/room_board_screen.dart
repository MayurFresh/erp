import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_colors.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import 'hotel_models.dart';
import 'hotel_repository.dart';
import 'hotel_widgets.dart';

const double _kNameWidth = 76;
const double _kCell = 54;
const double _kRow = 44;

/// `/hotel/board`: rooms down the side, 14 nights across. Tap a stay to open
/// it, or an empty night to start a reservation for that room.
class RoomBoardScreen extends ConsumerStatefulWidget {
  const RoomBoardScreen({super.key});

  @override
  ConsumerState<RoomBoardScreen> createState() => _RoomBoardScreenState();
}

class _RoomBoardScreenState extends ConsumerState<RoomBoardScreen> {
  DateTime _from = today();

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(hotelBoardProvider(apiDate(_from)));
    final desk = ref.watch(permissionsProvider).canAny(const [
      Perm.hotelFrontOffice,
      Perm.hotelManage,
    ]);
    return CGate(
      anyOf: const [Perm.hotelView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Room board',
            actions: [
              if (desk)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/hotel/reservations/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New reservation'),
                ),
            ],
          ),
          FilterBar(
            children: [
              IconButton(
                tooltip: 'Back 7 days',
                onPressed: () =>
                    setState(() => _from = _from.subtract(const Duration(days: 7))),
                icon: const Icon(Icons.chevron_left),
              ),
              TextButton(
                onPressed: () => setState(() => _from = today()),
                child: Text('From ${shortDate(apiDate(_from))}'),
              ),
              IconButton(
                tooltip: 'Forward 7 days',
                onPressed: () =>
                    setState(() => _from = _from.add(const Duration(days: 7))),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          Expanded(
            child: AsyncValueView<Board>(
              value: board,
              onRetry: () => ref.invalidate(hotelBoardProvider(apiDate(_from))),
              data: (b) => _BoardGrid(board: b, desk: desk),
            ),
          ),
        ],
      ),
    );
  }
}

Color _stayColour(BuildContext context, String status) {
  final c = context.colors;
  return switch (status) {
    'checked_in' => c.toneBackground(StatusTone.success),
    'checked_out' => c.toneBackground(StatusTone.neutral),
    'tentative' => c.toneBackground(StatusTone.warning),
    _ => c.toneBackground(StatusTone.info),
  };
}

class _BoardGrid extends StatelessWidget {
  const _BoardGrid({required this.board, required this.desk});

  final Board board;
  final bool desk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = pageGutter(context);
    if (board.rooms.isEmpty) {
      return const EmptyView(
        icon: Icons.meeting_room_outlined,
        message: 'No rooms yet. Add rooms in Room and rate setup.',
      );
    }
    final line = theme.dividerColor;
    return ListView(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xl),
      children: [
        if (board.unassigned.isNotEmpty) ...[
          Text('Rooms not yet assigned', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in board.unassigned)
                ActionChip(
                  label: Text(
                    '${s.guest}  ${s.typeName}  ${shortDate(s.arrival)}-${shortDate(s.departure)}',
                  ),
                  onPressed: () => context.go('/hotel/reservations/${s.reservationId}'),
                ),
            ],
          ),
          const SizedBox(height: Space.md),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _kNameWidth,
              child: Column(
                children: [
                  const SizedBox(height: _kRow),
                  for (final r in board.rooms)
                    Container(
                      height: _kRow,
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: line)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              color: roomColour(context, r.status),
                              shape: BoxShape.circle,
                            ),
                          ),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(r.number, style: theme.textTheme.titleSmall),
                                Text(
                                  r.type,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Column(
                  children: [
                    Row(
                      children: [
                        for (final d in board.dates)
                          SizedBox(
                            width: _kCell,
                            height: _kRow,
                            child: Center(
                              child: Text(
                                _dayHead(d),
                                textAlign: TextAlign.center,
                                style: theme.textTheme.labelSmall,
                              ),
                            ),
                          ),
                      ],
                    ),
                    for (final r in board.rooms)
                      Row(
                        children: [
                          for (final d in board.dates)
                            _Cell(
                              room: r,
                              date: d,
                              firstDate: board.dates.first,
                              line: line,
                              desk: desk,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            for (final s in const ['checked_in', 'confirmed', 'tentative', 'checked_out'])
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 14, height: 14, color: _stayColour(context, s)),
                  const SizedBox(width: 6),
                  Text(resStatusLabel(s), style: theme.textTheme.bodySmall),
                ],
              ),
          ],
        ),
      ],
    );
  }

  static String _dayHead(String ymd) {
    final d = DateTime.tryParse(ymd);
    if (d == null) return ymd;
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[d.weekday - 1]}\n${d.day}';
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.room,
    required this.date,
    required this.firstDate,
    required this.line,
    required this.desk,
  });

  final BoardRoom room;
  final String date;
  final String firstDate;
  final Color line;
  final bool desk;

  @override
  Widget build(BuildContext context) {
    Stay? stay;
    for (final s in room.stays) {
      if (s.arrival.compareTo(date) <= 0 && s.departure.compareTo(date) > 0) {
        stay = s;
        break;
      }
    }
    final border = Border(
      top: BorderSide(color: line),
      left: BorderSide(color: line.withValues(alpha: 0.5)),
    );
    if (stay == null) {
      return InkWell(
        onTap: desk
            ? () => context.go('/hotel/reservations/new?arrival=$date')
            : null,
        child: Container(
          width: _kCell,
          height: _kRow,
          decoration: BoxDecoration(border: border),
        ),
      );
    }
    final first = stay.arrival == date || date == firstDate;
    return InkWell(
      onTap: () => context.go('/hotel/reservations/${stay!.reservationId}'),
      child: Container(
        width: _kCell,
        height: _kRow,
        padding: const EdgeInsets.symmetric(horizontal: 3),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: _stayColour(context, stay.status),
          border: border,
        ),
        child: first
            ? Text(
                stay.guest,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              )
            : null,
      ),
    );
  }
}
