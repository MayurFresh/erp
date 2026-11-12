import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/layout.dart';
import '../../core/json.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'channels_models.dart';
import 'channels_perms.dart';
import 'channels_repository.dart';
import 'channels_widgets.dart';

const _filters = <(String?, String)>[
  (null, 'All'),
  ('processed', 'Done'),
  ('failed', 'Needs attention'),
  ('ignored', 'Skipped'),
];

/// `/channels/orders`: every order that came in from a channel, with its status.
class ChannelOrdersScreen extends ConsumerStatefulWidget {
  const ChannelOrdersScreen({super.key, this.channelId});

  final String? channelId;

  @override
  ConsumerState<ChannelOrdersScreen> createState() =>
      _ChannelOrdersScreenState();
}

class _ChannelOrdersScreenState extends ConsumerState<ChannelOrdersScreen> {
  late String? _channelId = widget.channelId;
  String? _status;
  Map<String, int> _counts = const {};
  late final PagedController<InboxOrder> _paged = PagedController((
    offset,
    limit,
  ) async {
    final page = await ref
        .read(channelsRepositoryProvider)
        .inbox(
          connectionId: _channelId,
          status: _status,
          offset: offset,
          limit: limit,
        );
    if (mounted) setState(() => _counts = page.counts);
    return Paged(page.data, page.total);
  });

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

  Future<void> _retry(InboxOrder o) async {
    try {
      await ref.read(channelsRepositoryProvider).retry(o.id);
      ref.bumpChannels();
      await _paged.refresh();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Widget _statusCell(InboxOrder o) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      StatusPill(o.status),
      if (o.error != null)
        Padding(
          padding: const EdgeInsets.only(top: Space.xs),
          child: Text(
            o.error!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    ref.listen(channelsRevisionProvider, (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final manage = ref.watch(permissionsProvider).can(ChPerm.manage);
    return CGate(
      anyOf: const [ChPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Channel orders',
            actions: [
              if (manage)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go(
                    '/channels/import${_channelId == null ? '' : '?channelId=$_channelId'}',
                  ),
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('Import orders'),
                ),
            ],
          ),
          FilterBar(
            children: [
              ChannelDropdown(
                allowAll: true,
                value: _channelId,
                onChanged: (v) {
                  setState(() => _channelId = v);
                  _paged.refresh();
                },
              ),
              for (final f in _filters)
                ChoiceChip(
                  key: Key('orders-filter-${f.$1 ?? 'all'}'),
                  label: Text(
                    f.$1 == null ? f.$2 : '${f.$2} (${_counts[f.$1] ?? 0})',
                  ),
                  selected: _status == f.$1,
                  onSelected: (_) {
                    setState(() => _status = f.$1);
                    _paged.refresh();
                  },
                ),
            ],
          ),
          Expanded(
            child: AdaptiveDataList<InboxOrder>(
              controller: _paged,
              emptyMessage: 'No channel orders yet.',
              emptyIcon: Icons.shopping_bag_outlined,
              onTap: (o) {
                final id = o.salesOrderId;
                if (id != null) context.go('/sales-orders/$id');
              },
              columns: [
                TableColumnSpec('Order', (o) => Text(o.externalRef)),
                TableColumnSpec('Channel', (o) => Text(o.connectionName)),
                TableColumnSpec('Date', (o) => Text(formatDate(o.orderDate))),
                TableColumnSpec(
                  'Items',
                  (o) => Text(
                    o.lines.join(', '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TableColumnSpec(
                  'Total',
                  (o) => Text(o.total == null ? '' : formatMoney(o.total)),
                  numeric: true,
                ),
                TableColumnSpec(
                  'Sales order',
                  (o) => Text(o.salesOrderNumber ?? ''),
                ),
                TableColumnSpec('Status', _statusCell),
                TableColumnSpec(
                  '',
                  (o) => o.canRetry && manage
                      ? TextButton(
                          onPressed: () => _retry(o),
                          child: const Text('Try again'),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
              cardBuilder: (context, o) => Card(
                margin: const EdgeInsets.symmetric(
                  horizontal: Space.md,
                  vertical: Space.xs,
                ),
                child: InkWell(
                  onTap: o.salesOrderId == null
                      ? null
                      : () => context.go('/sales-orders/${o.salesOrderId}'),
                  child: Padding(
                    padding: const EdgeInsets.all(Space.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                o.externalRef,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            StatusPill(o.status),
                          ],
                        ),
                        const SizedBox(height: Space.xs),
                        Text(
                          [
                            o.connectionName,
                            if (o.orderDate != null) formatDate(o.orderDate),
                            if (o.total != null) formatMoney(o.total),
                          ].join(' · '),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (o.lines.isNotEmpty)
                          Text(
                            o.lines.join(', '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (o.salesOrderNumber != null)
                          Text(
                            'Sales order ${o.salesOrderNumber} (${o.salesOrderStatus ?? ''})',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        if (o.error != null)
                          Text(
                            o.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        if (o.canRetry && manage)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () => _retry(o),
                              child: const Text('Try again'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
