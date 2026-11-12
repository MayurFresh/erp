import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'hotel_models.dart';
import 'hotel_repository.dart';
import 'hotel_widgets.dart';

typedef _Range = ({String from, String to});

final _occupancyProvider = FutureProvider.autoDispose
    .family<List<OccupancyRow>, _Range>((ref, r) {
      ref.watch(hotelRevisionProvider(HotelKind.rooms));
      return ref.watch(hotelRepositoryProvider).occupancy(r.from, r.to);
    });

final _registerProvider = FutureProvider.autoDispose
    .family<List<RegisterRow>, _Range>((ref, r) {
      ref.watch(hotelRevisionProvider(HotelKind.reservations));
      return ref.watch(hotelRepositoryProvider).guestRegister(r.from, r.to);
    });

/// `/hotel/reports`: occupancy, ADR and RevPAR, and the guest register.
class HotelReportsScreen extends ConsumerStatefulWidget {
  const HotelReportsScreen({super.key});

  @override
  ConsumerState<HotelReportsScreen> createState() => _HotelReportsScreenState();
}

class _HotelReportsScreenState extends ConsumerState<HotelReportsScreen> {
  DateTime _from = today().subtract(const Duration(days: 6));
  DateTime _to = today();

  @override
  Widget build(BuildContext context) {
    final range = (from: apiDate(_from), to: apiDate(_to));
    final gutter = pageGutter(context);
    return CGate(
      anyOf: const [Perm.hotelView],
      child: DefaultTabController(
        length: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PageHeader(title: 'Hotel reports'),
            FilterBar(
              children: [
                SizedBox(
                  width: 170,
                  child: DateField(
                    label: 'From',
                    value: _from,
                    lastDate: _to,
                    onChanged: (d) => setState(() => _from = d),
                  ),
                ),
                SizedBox(
                  width: 170,
                  child: DateField(
                    label: 'To',
                    value: _to,
                    firstDate: _from,
                    onChanged: (d) => setState(() => _to = d),
                  ),
                ),
              ],
            ),
            const TabBar(tabs: [Tab(text: 'Occupancy'), Tab(text: 'Guest register')]),
            Expanded(
              child: TabBarView(
                children: [
                  AsyncValueView<List<OccupancyRow>>(
                    value: ref.watch(_occupancyProvider(range)),
                    onRetry: () => ref.invalidate(_occupancyProvider(range)),
                    data: (rows) => _Occupancy(rows: rows, gutter: gutter),
                  ),
                  AsyncValueView<List<RegisterRow>>(
                    value: ref.watch(_registerProvider(range)),
                    onRetry: () => ref.invalidate(_registerProvider(range)),
                    data: (rows) => rows.isEmpty
                        ? const EmptyView(
                            icon: Icons.menu_book_outlined,
                            message: 'No guests stayed in this period.',
                          )
                        : ListView.separated(
                            padding: EdgeInsets.fromLTRB(gutter, Space.sm, gutter, Space.xl),
                            itemCount: rows.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final r = rows[i];
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${r.serial}. ${r.name}  |  Room ${r.room}',
                                      style: Theme.of(context).textTheme.titleSmall,
                                    ),
                                    Text(
                                      [
                                        r.nationality,
                                        '${r.idType.replaceAll('_', ' ')} ${r.idNumber}',
                                        if (r.passportNo.isNotEmpty) 'Passport ${r.passportNo}',
                                        if (r.visaNo.isNotEmpty) 'Visa ${r.visaNo}',
                                        r.phone,
                                        r.address,
                                      ].where((s) => s.trim().isNotEmpty).join('  |  '),
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              );
                            },
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

class _Occupancy extends StatelessWidget {
  const _Occupancy({required this.rows, required this.gutter});

  final List<OccupancyRow> rows;
  final double gutter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sold = rows.fold<int>(0, (s, r) => s + r.sold);
    final cap = rows.fold<int>(0, (s, r) => s + r.available);
    final rev = rows.fold<double>(0, (s, r) => s + r.revenue);
    final occ = cap == 0 ? 0.0 : sold * 100 / cap;
    final adr = sold == 0 ? 0.0 : rev / sold;
    final revpar = cap == 0 ? 0.0 : rev / cap;
    Widget stat(String label, String value) => ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 110),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          Text(value, style: theme.textTheme.titleLarge),
        ],
      ),
    );
    return ListView(
      padding: EdgeInsets.fromLTRB(gutter, Space.sm, gutter, Space.xl),
      children: [
        SectionCard(
          child: Wrap(
            spacing: Space.xl,
            runSpacing: Space.md,
            children: [
              stat('Occupancy', '${occ.toStringAsFixed(1)}%'),
              stat('ADR', formatMoney(adr)),
              stat('RevPAR', formatMoney(revpar)),
              stat('Room revenue', formatMoney(rev)),
              stat('Room nights', '$sold of $cap'),
            ],
          ),
        ),
        const SizedBox(height: Space.sm),
        Text(
          'From posted room nights. Revenue is the tariff before tax unless prices include tax.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: Space.sm),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                SizedBox(width: 64, child: Text(shortDate(r.date))),
                Expanded(
                  child: LinearProgressIndicator(
                    value: (r.occupancyPct / 100).clamp(0, 1),
                    minHeight: 8,
                  ),
                ),
                SizedBox(
                  width: 150,
                  child: Text(
                    '${r.sold}/${r.available}  ${r.occupancyPct.toStringAsFixed(0)}%  ${formatMoney(r.adr)}',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
