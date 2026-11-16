import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import 'export_models.dart';
import 'export_repository.dart';

class ChallansScreen extends ConsumerStatefulWidget {
  const ChallansScreen({super.key});

  @override
  ConsumerState<ChallansScreen> createState() => _ChallansScreenState();
}

class _ChallansScreenState extends ConsumerState<ChallansScreen> {
  String _query = '';
  String? _status;
  late final PagedController<ChallanSummary> _paged = PagedController(
    (offset, limit) => ref
        .read(exportRepositoryProvider)
        .challans(q: _query, status: _status, offset: offset, limit: limit),
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

  @override
  Widget build(BuildContext context) {
    ref.listen(exportRevisionProvider, (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final perms = ref.watch(permissionsProvider);
    void open(ChallanSummary c) => context.go('/delivery-challans/${c.id}');
    String word(ChallanSummary c) => challanStatuses[c.status] ?? c.status;
    String reason(ChallanSummary c) => challanReasons[c.reason] ?? c.reason;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Delivery challans',
          subtitle: 'Goods that move without a sale',
          actions: [
            if (perms.can(Perm.challansManage))
              FilledButton.icon(
                onPressed: () => context.go('/delivery-challans/new'),
                icon: const Icon(Icons.add),
                label: const Text('New challan'),
              ),
          ],
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Status',
              value: _status,
              width: 180,
              options: challanStatuses,
              onChanged: (v) {
                setState(() => _status = v);
                _paged.refresh();
              },
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SearchField(
                hintText: 'Search number or consignee',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<ChallanSummary>(
            controller: _paged,
            emptyMessage: _status != null || _query.isNotEmpty
                ? 'No challans match these filters.'
                : 'No delivery challans yet.',
            emptyIcon: Icons.local_shipping_outlined,
            onTap: open,
            tableBreakpoint: 900,
            columns: [
              TableColumnSpec('Number', (c) => Text(c.number)),
              TableColumnSpec('Date', (c) => Text(formatDate(c.date))),
              TableColumnSpec(
                'Consignee',
                (c) => Text(c.consigneeName),
                maxWidth: 240,
              ),
              TableColumnSpec('Reason', (c) => Text(reason(c))),
              TableColumnSpec(
                'Status',
                (c) => StatusChip(c.status, label: word(c)),
              ),
            ],
            cardBuilder: (context, c) => DocListCard(
              onTap: () => open(c),
              title: c.number,
              details: '${c.consigneeName} · ${reason(c)} · ${formatDate(c.date)}',
              pills: StatusChip(c.status, label: word(c)),
              amount: '',
            ),
          ),
        ),
      ],
    );
  }
}
