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

/// `/demands`: demand letters raised against bookings.
class DemandsScreen extends ConsumerStatefulWidget {
  const DemandsScreen({super.key});

  @override
  ConsumerState<DemandsScreen> createState() => _DemandsScreenState();
}

class _DemandsScreenState extends ConsumerState<DemandsScreen> {
  String? _projectId;
  String? _paymentStatus;
  String _query = '';
  late final PagedController<Demand> _paged = PagedController(
    (offset, limit) => ref
        .read(realEstateRepositoryProvider)
        .demands(
          projectId: _projectId,
          paymentStatus: _paymentStatus,
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
    ref.listen(rRevisionProvider(RKind.demands), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    return CGate(
      anyOf: const [RePerm.bookingsView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Demands'),
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
              StatusChips<String>(
                value: _paymentStatus,
                options: const {
                  'unpaid': 'Unpaid',
                  'partial': 'Part paid',
                  'paid': 'Paid',
                },
                onChanged: (s) => _reload(() => _paymentStatus = s),
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
            child: AdaptiveDataList<Demand>(
              controller: _paged,
              emptyMessage: 'No demands found.',
              emptyIcon: Icons.request_quote_outlined,
              onTap: (d) => context.go('/demands/${d.id}'),
              columns: [
                TableColumnSpec('Demand', (d) => Text(d.number)),
                TableColumnSpec(
                  'Date',
                  (d) => Text(formatDate(parseApiDate(d.date))),
                ),
                TableColumnSpec('Booking', (d) => Text(d.bookingNumber)),
                TableColumnSpec('Unit', (d) => Text(d.unitCode)),
                TableColumnSpec('Customer', (d) => Text(d.partyName)),
                TableColumnSpec(
                  'Total',
                  (d) => Text(formatMoney(d.total)),
                  numeric: true,
                ),
                TableColumnSpec(
                  'Due',
                  (d) => Text(formatMoney(d.amountDue)),
                  numeric: true,
                ),
                TableColumnSpec('Status', demandStatusPills),
              ],
              cardBuilder: (context, d) => CListCard(
                onTap: () => context.go('/demands/${d.id}'),
                title: '${d.number} · ${d.unitCode}',
                trailing: formatMoney(d.total),
                subtitle: d.partyName,
                details: [
                  '${formatDate(parseApiDate(d.date))} · ${d.stageNames}',
                  if (d.amountDue > 0 && !d.isCancelled)
                    'Due ${formatMoney(d.amountDue)}',
                ],
                pills: demandStatusPills(d),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
