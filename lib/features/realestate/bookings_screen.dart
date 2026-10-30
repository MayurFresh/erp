import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../auth/session.dart';
import 're_models.dart';
import 're_perms.dart';
import 're_repository.dart';
import 're_widgets.dart';

/// `/bookings`: unit bookings with their sales status.
class BookingsScreen extends ConsumerStatefulWidget {
  const BookingsScreen({super.key});

  @override
  ConsumerState<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends ConsumerState<BookingsScreen> {
  String? _projectId;
  BookingStatus? _status;
  String _query = '';
  late final PagedController<Booking> _paged = PagedController(
    (offset, limit) => ref
        .read(realEstateRepositoryProvider)
        .bookings(
          projectId: _projectId,
          status: _status,
          q: _query,
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
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  void _reload(VoidCallback change) {
    setState(change);
    _paged.refresh();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(rRevisionProvider(RKind.bookings), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final manage = ref.watch(permissionsProvider).can(RePerm.bookingsManage);
    return CGate(
      anyOf: const [RePerm.bookingsView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Bookings',
            actions: [
              if (manage)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/bookings/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New booking'),
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
                  onChanged: (id) => _reload(() => _projectId = id),
                ),
              ),
              StatusChips<BookingStatus>(
                value: _status,
                options: {for (final s in BookingStatus.values) s: s.label},
                onChanged: (s) => _reload(() => _status = s),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: SearchField(
                  hintText: 'Search number, unit or customer',
                  onChanged: (q) => _reload(() => _query = q),
                ),
              ),
            ],
          ),
          Expanded(
            child: AdaptiveDataList<Booking>(
              controller: _paged,
              emptyMessage: 'No bookings found.',
              emptyIcon: Icons.event_available_outlined,
              onTap: (b) => context.go('/bookings/${b.id}'),
              columns: [
                TableColumnSpec('Booking', (b) => Text(b.number)),
                TableColumnSpec(
                  'Date',
                  (b) => Text(formatDate(parseApiDate(b.date))),
                ),
                TableColumnSpec('Project', (b) => Text(b.projectName)),
                TableColumnSpec('Unit', (b) => Text(b.unitCode)),
                TableColumnSpec('Customer', (b) => Text(b.customerName)),
                TableColumnSpec(
                  'Agreement value',
                  (b) => Text(formatMoney(b.agreementValue)),
                  numeric: true,
                ),
                TableColumnSpec(
                  'Due',
                  (b) => Text(formatMoney(b.totals.due)),
                  numeric: true,
                ),
                TableColumnSpec('Status', (b) => bookingStatusPill(b.status)),
              ],
              cardBuilder: (context, b) => CListCard(
                onTap: () => context.go('/bookings/${b.id}'),
                title: '${b.number} · ${b.unitCode}',
                trailing: formatMoney(b.agreementValue),
                subtitle: b.customerName,
                details: [
                  '${b.projectName} · ${formatDate(parseApiDate(b.date))}',
                  if (b.totals.due > 0) 'Due ${formatMoney(b.totals.due)}',
                ],
                pills: bookingStatusPill(b.status),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
