import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'hotel_models.dart';
import 'hotel_repository.dart';
import 'hotel_widgets.dart';

/// `/hotel`: today's arrivals, departures and in-house guests, with room counts.
class HotelHomeScreen extends ConsumerStatefulWidget {
  const HotelHomeScreen({super.key});

  @override
  ConsumerState<HotelHomeScreen> createState() => _HotelHomeScreenState();
}

class _HotelHomeScreenState extends ConsumerState<HotelHomeScreen> {
  bool _posting = false;

  Future<void> _postNights() async {
    final ok = await confirm(
      context,
      title: 'Post tonight\'s room charges?',
      message:
          'Adds one room charge for every room in the house. Running it again '
          'for the same date adds nothing.',
      confirmLabel: 'Post charges',
    );
    if (!ok || !mounted) return;
    setState(() => _posting = true);
    try {
      final n = await ref.read(hotelRepositoryProvider).postNights();
      if (!mounted) return;
      ref.bumpHotel();
      showSuccess(context, n == 0 ? 'Already posted for today.' : 'Posted $n room charges.');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final desk = perms.canAny(const [Perm.hotelFrontOffice, Perm.hotelManage]);
    final today = ref.watch(hotelTodayProvider);
    return CGate(
      anyOf: const [Perm.hotelView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Front office',
            actions: [
              OutlinedButton.icon(
                style: bigOutlinedButton,
                onPressed: () => context.go('/hotel/board'),
                icon: const Icon(Icons.grid_view_outlined),
                label: const Text('Room board'),
              ),
              OutlinedButton.icon(
                style: bigOutlinedButton,
                onPressed: () => context.go('/hotel/housekeeping'),
                icon: const Icon(Icons.cleaning_services_outlined),
                label: const Text('Housekeeping'),
              ),
              if (desk)
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: _posting ? null : _postNights,
                  icon: const Icon(Icons.nights_stay_outlined),
                  label: const Text('Post night charges'),
                ),
              if (desk)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/hotel/reservations/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New reservation'),
                ),
            ],
          ),
          Expanded(
            child: AsyncValueView<TodayData>(
              value: today,
              onRetry: () => ref.invalidate(hotelTodayProvider),
              data: (d) => _Body(data: d, desk: desk),
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.data, required this.desk});

  final TodayData data;
  final bool desk;

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutter(context);
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final sections = [
      _Section(
        title: 'Arrivals today',
        items: data.arrivals,
        empty: 'No arrivals due.',
        action: desk ? 'Check in' : null,
        onAction: (i) => context.go('/hotel/reservations/${i.id}/check-in'),
      ),
      _Section(
        title: 'Departures today',
        items: data.departures,
        empty: 'No departures due.',
        action: desk ? 'Check out' : null,
        onAction: (i) => context.go('/hotel/reservations/${i.id}'),
      ),
      _Section(
        title: 'In house',
        items: data.inHouse,
        empty: 'No guests in the house.',
      ),
    ];
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Counts(data: data),
          const SizedBox(height: Space.md),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, s) in sections.indexed) ...[
                  if (i > 0) const SizedBox(width: Space.md),
                  Expanded(child: s),
                ],
              ],
            )
          else
            for (final s in sections) ...[s, const SizedBox(height: Space.md)],
        ],
      ),
    );
  }
}

class _Counts extends StatelessWidget {
  const _Counts({required this.data});

  final TodayData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = data.totalRooms == 0
        ? 0
        : (data.occupied * 100 / data.totalRooms).round();
    Widget cell(String label, String value, {Color? dot}) => ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (dot != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              Text(label, style: theme.textTheme.bodySmall),
            ],
          ),
          Text(value, style: theme.textTheme.titleLarge),
        ],
      ),
    );
    return SectionCard(
      child: Wrap(
        spacing: Space.xl,
        runSpacing: Space.md,
        children: [
          cell('Occupied', '${data.occupied} of ${data.totalRooms}  ($pct%)'),
          for (final s in const ['clean', 'inspected', 'dirty', 'out_of_order'])
            cell(
              roomStatusLabel(s),
              '${data.roomCounts[s] ?? 0}',
              dot: roomColour(context, s),
            ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.items,
    required this.empty,
    this.action,
    this.onAction,
  });

  final String title;
  final List<DeskItem> items;
  final String empty;
  final String? action;
  final void Function(DeskItem)? onAction;

  @override
  Widget build(BuildContext context) => SectionCard(
    title: '$title  (${items.length})',
    child: items.isEmpty
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(empty),
          )
        : Column(
            children: [
              for (final i in items)
                DeskTile(
                  item: i,
                  onTap: () => context.go('/hotel/reservations/${i.id}'),
                  trailing: action == null || onAction == null
                      ? null
                      : OutlinedButton(
                          style: bigOutlinedButton,
                          onPressed: () => onAction!(i),
                          child: Text(action!),
                        ),
                ),
            ],
          ),
  );
}
