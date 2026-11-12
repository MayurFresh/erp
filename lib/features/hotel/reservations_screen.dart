import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'hotel_models.dart';
import 'hotel_repository.dart';
import 'hotel_widgets.dart';

/// `/hotel/reservations`: every booking, with a search and a status filter.
class ReservationsScreen extends ConsumerStatefulWidget {
  const ReservationsScreen({super.key});

  @override
  ConsumerState<ReservationsScreen> createState() => _ReservationsScreenState();
}

class _ReservationsScreenState extends ConsumerState<ReservationsScreen> {
  final _search = TextEditingController();
  String? _status;
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desk = ref.watch(permissionsProvider).canAny(const [
      Perm.hotelFrontOffice,
      Perm.hotelManage,
    ]);
    final list = ref.watch(hotelReservationsProvider((status: _status, q: _q.isEmpty ? null : _q)));
    final gutter = pageGutter(context);
    return CGate(
      anyOf: const [Perm.hotelView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Reservations',
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
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    labelText: 'Search guest, phone or number',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onSubmitted: (v) => setState(() => _q = v.trim()),
                ),
              ),
              DropdownMenu<String?>(
                initialSelection: _status,
                label: const Text('Status'),
                onSelected: (v) => setState(() => _status = v),
                dropdownMenuEntries: [
                  const DropdownMenuEntry(value: null, label: 'All'),
                  for (final s in const ['tentative', 'confirmed', 'checked_in', 'checked_out', 'cancelled', 'no_show'])
                    DropdownMenuEntry(value: s, label: resStatusLabel(s)),
                ],
              ),
            ],
          ),
          Expanded(
            child: AsyncValueView<List<Reservation>>(
              value: list,
              onRetry: () => ref.invalidate(hotelReservationsProvider),
              data: (rows) => rows.isEmpty
                  ? const EmptyView(
                      icon: Icons.event_available_outlined,
                      message: 'No reservations match.',
                    )
                  : ListView.separated(
                      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xl),
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final r = rows[i];
                        return InkWell(
                          onTap: () => context.go('/hotel/reservations/${r.id}'),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 60),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(r.guestName, style: Theme.of(context).textTheme.titleSmall),
                                        Text(
                                          '${r.number}  |  ${shortDate(r.arrival)} to ${shortDate(r.departure)}  |  ${r.roomsLine}'
                                          '${r.advance > 0 ? '  |  Advance ${formatMoney(r.advance)}' : ''}',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  ReservationChip(r.status),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
