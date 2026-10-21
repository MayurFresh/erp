import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import '../locations/location_filter.dart';
import 'transfer_model.dart';
import 'transfer_widgets.dart';
import 'transfers_repository.dart';

class TransfersScreen extends ConsumerStatefulWidget {
  const TransfersScreen({super.key});

  @override
  ConsumerState<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends ConsumerState<TransfersScreen> {
  String _query = '';
  TransferStatus? _status;
  String? _locationId;
  late final PagedController<Transfer> _paged = PagedController(
    (offset, limit) => ref
        .read(transfersRepositoryProvider)
        .list(
          q: _query,
          status: _status,
          locationId: _locationId,
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

  @override
  Widget build(BuildContext context) {
    ref.listen(
      revisionProvider(DataKind.transfers),
      (_, _) => _paged.refresh(),
    );
    ref.listen(activeCompanyIdProvider, (_, _) {
      _locationId = null;
      _paged.refresh();
    });
    final perms = ref.watch(permissionsProvider);
    final showValue = perms.can(Perm.itemsViewCost);

    void open(Transfer t) => context.go('/transfers/${t.id}');

    String route(Transfer t) => '${t.fromLocationName} → ${t.toLocationName}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Stock transfers',
          subtitle: 'Goods moving between locations',
          actions: [
            if (perms.can(Perm.transfersCreate))
              FilledButton.icon(
                onPressed: () => context.go('/transfers/new'),
                icon: const Icon(Icons.add),
                label: const Text('New transfer'),
              ),
          ],
        ),
        FilterBar(
          children: [
            FilterDropdown<TransferStatus>(
              label: 'Status',
              value: _status,
              width: 170,
              options: {for (final s in TransferStatus.values) s: s.label},
              onChanged: (v) {
                setState(() => _status = v);
                _paged.refresh();
              },
            ),
            LocationFilter(
              value: _locationId,
              onChanged: (id) {
                setState(() => _locationId = id);
                _paged.refresh();
              },
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SearchField(
                hintText: 'Search number',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<Transfer>(
            controller: _paged,
            emptyMessage: 'No transfers found.',
            emptyIcon: Icons.local_shipping_outlined,
            onTap: open,
            tableBreakpoint: 1000,
            columns: [
              TableColumnSpec('Number', (t) => Text(t.number)),
              TableColumnSpec('Date', (t) => Text(formatDate(t.transferDate))),
              TableColumnSpec(
                'From',
                (t) => Text(t.fromLocationName),
                maxWidth: 170,
              ),
              TableColumnSpec(
                'To',
                (t) => Text(t.toLocationName),
                maxWidth: 170,
              ),
              TableColumnSpec(
                'Items',
                (t) => Text('${t.lines.length}'),
                numeric: true,
              ),
              TableColumnSpec(
                'Status',
                (t) => TransferStatusPill(status: t.status),
              ),
              if (showValue)
                TableColumnSpec(
                  'Value',
                  (t) => Text(
                    t.totalValue == null ? '—' : formatMoney(t.totalValue),
                  ),
                  numeric: true,
                ),
            ],
            cardBuilder: (context, t) => DocListCard(
              onTap: () => open(t),
              title: t.number,
              details: '${route(t)} · ${formatDate(t.transferDate)}',
              pills: TransferStatusPill(status: t.status),
              amount: '${t.lines.length} item${t.lines.length == 1 ? '' : 's'}',
              secondary: t.totalValue == null
                  ? null
                  : formatMoney(t.totalValue),
            ),
          ),
        ),
      ],
    );
  }
}
