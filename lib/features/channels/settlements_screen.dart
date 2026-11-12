import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'channels_models.dart';
import 'channels_perms.dart';
import 'channels_repository.dart';
import 'channels_widgets.dart';

/// `/channels/settlements`: payout reports from the channels.
class SettlementsScreen extends ConsumerStatefulWidget {
  const SettlementsScreen({super.key});

  @override
  ConsumerState<SettlementsScreen> createState() => _SettlementsScreenState();
}

class _SettlementsScreenState extends ConsumerState<SettlementsScreen> {
  late final PagedController<Settlement> _paged = PagedController(
    (offset, limit) => ref
        .read(channelsRepositoryProvider)
        .settlements(offset: offset, limit: limit),
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

  Future<void> _import() async {
    final done = await showFormDialog<bool>(
      context: context,
      builder: (_) => const _ImportSettlementDialog(),
    );
    if (done == true) ref.bumpChannels();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(channelsRevisionProvider, (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final manage = ref.watch(permissionsProvider).can(ChPerm.settlements);
    return CGate(
      anyOf: const [ChPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Settlements',
            subtitle: 'What each channel paid out, and what it kept',
            actions: [
              if (manage)
                FilledButton.icon(
                  key: const Key('settlement-import'),
                  style: bigButton,
                  onPressed: _import,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('Import report'),
                ),
            ],
          ),
          Expanded(
            child: AdaptiveDataList<Settlement>(
              controller: _paged,
              emptyMessage: 'No settlement reports yet.',
              emptyIcon: Icons.account_balance_wallet_outlined,
              onTap: (s) => context.go('/channels/settlements/${s.id}'),
              columns: [
                TableColumnSpec('Report', (s) => Text(s.ref)),
                TableColumnSpec('Channel', (s) => Text(s.connectionName)),
                TableColumnSpec(
                  'Paid on',
                  (s) => Text(formatDate(s.payoutDate)),
                ),
                TableColumnSpec(
                  'Payout',
                  (s) => Text(formatMoney(s.payout)),
                  numeric: true,
                ),
                TableColumnSpec(
                  'Difference',
                  (s) => Text(formatMoney(s.difference)),
                  numeric: true,
                ),
                TableColumnSpec('Status', (s) => StatusPill(s.status)),
              ],
              cardBuilder: (context, s) => Card(
                margin: const EdgeInsets.symmetric(
                  horizontal: Space.md,
                  vertical: Space.xs,
                ),
                child: InkWell(
                  onTap: () => context.go('/channels/settlements/${s.id}'),
                  child: Padding(
                    padding: const EdgeInsets.all(Space.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                s.ref,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            StatusPill(s.status),
                          ],
                        ),
                        Text(
                          '${s.connectionName} · ${formatDate(s.payoutDate)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: Space.xs),
                        Text('Payout ${formatMoney(s.payout)}'),
                        if (s.difference != 0)
                          Text(
                            'Does not add up: ${formatMoney(s.difference)} off',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
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

class _ImportSettlementDialog extends ConsumerStatefulWidget {
  const _ImportSettlementDialog();

  @override
  ConsumerState<_ImportSettlementDialog> createState() =>
      _ImportSettlementDialogState();
}

class _ImportSettlementDialogState
    extends ConsumerState<_ImportSettlementDialog> {
  final _csv = TextEditingController();
  String? _channelId;
  SettlementPreview? _preview;
  bool _busy = false;

  @override
  void dispose() {
    _csv.dispose();
    super.dispose();
  }

  Future<void> _run(bool dryRun) async {
    final id = _channelId;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(channelsRepositoryProvider);
      if (dryRun) {
        final p = await repo.previewSettlements(id, _csv.text);
        if (mounted) setState(() => _preview = p);
      } else {
        await repo.importSettlements(id, _csv.text);
        if (mounted) Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _preview;
    final fresh = p?.items.where((i) => !i.duplicate).length ?? 0;
    return AlertDialog(
      title: const Text('Import settlement report'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Columns: settlement_id, payout_date, order_id, type, amount. Money to you is positive. '
                'A row of type "net payout" states the amount paid into the bank.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              ChannelDropdown(
                value: _channelId,
                onChanged: (v) => setState(() {
                  _channelId = v;
                  _preview = null;
                }),
              ),
              const SizedBox(height: Space.md),
              CsvInput(
                controller: _csv,
                onChanged: () => setState(() => _preview = null),
              ),
              if (p != null) ...[
                const SizedBox(height: Space.md),
                for (final i in p.items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                i.ref,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (i.duplicate)
                              const Pill('Already imported')
                            else
                              StatusPill(i.status),
                          ],
                        ),
                        Text(
                          'Payout ${formatMoney(i.payout)} on ${formatDate(i.payoutDate)}',
                        ),
                        if (i.difference != 0)
                          Text(
                            'Lines add to ${formatMoney(i.linesTotal)}, ${formatMoney(i.difference)} off. It cannot be posted until fixed.',
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        if (i.unmatched.isNotEmpty)
                          Text(
                            'No order found for ${i.unmatched.join(', ')}',
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                for (final issue in p.issues)
                  Text(issue, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        if (p == null)
          FilledButton(
            key: const Key('settlement-preview'),
            onPressed: _busy || _channelId == null || _csv.text.trim().isEmpty
                ? null
                : () => _run(true),
            child: const Text('Preview'),
          )
        else
          FilledButton(
            key: const Key('settlement-run'),
            onPressed: _busy || fresh == 0 ? null : () => _run(false),
            child: Text('Import $fresh report${fresh == 1 ? '' : 's'}'),
          ),
      ],
    );
  }
}

/// `/channels/settlements/:id`: expected against received, order by order.
class SettlementScreen extends ConsumerWidget {
  const SettlementScreen({super.key, required this.settlementId});

  final String settlementId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = ref.watch(permissionsProvider).can(ChPerm.settlements);
    return CGate(
      anyOf: const [ChPerm.view],
      child: AsyncValueView<Settlement>(
        value: ref.watch(settlementProvider(settlementId)),
        onRetry: () => ref.invalidate(settlementProvider(settlementId)),
        data: (s) => _Body(settlement: s, manage: manage),
      ),
    );
  }
}

const _kindWords = <String, String>{
  'sale': 'Sales',
  'refund': 'Refunds',
  'commission': 'Commission',
  'fee': 'Fees',
  'shipping': 'Shipping',
  'gst_on_fees': 'GST on fees',
  'tcs': 'TCS held',
  'tds': 'TDS held',
  'reserve': 'Reserve held',
  'reserve_release': 'Reserve released',
  'adjustment': 'Adjustments',
};

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.settlement, required this.manage});

  final Settlement settlement;
  final bool manage;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  bool _busy = false;

  Future<void> _post() async {
    final s = widget.settlement;
    final ok = await confirm(
      context,
      title: 'Post to the books',
      message:
          'This records ${formatMoney(s.payout)} received, the fees and the tax held, dated ${formatDate(s.payoutDate)}.',
      confirmLabel: 'Post',
    );
    if (!ok || _busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(channelsRepositoryProvider).post(s.id);
      ref.bumpChannels();
      if (mounted) showSuccess(context, 'Posted to the books');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settlement;
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 720;
    return FormPage(
      maxWidth: 1000,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Settlement ${s.ref}',
                style: theme.textTheme.titleLarge,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            StatusPill(s.status),
          ],
        ),
        Text(
          '${s.connectionName} · paid ${formatDate(s.payoutDate)}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: Space.lg),
        Wrap(
          spacing: Space.xl,
          runSpacing: Space.md,
          children: [
            LabeledValue('Payout', formatMoney(s.payout)),
            LabeledValue('Lines add to', formatMoney(s.linesTotal)),
            if (s.difference != 0)
              LabeledValue('Difference', formatMoney(s.difference)),
            if (s.unmatchedOrders > 0)
              LabeledValue('Orders not found', '${s.unmatchedOrders}'),
          ],
        ),
        if (s.status == 'unbalanced')
          Padding(
            padding: const EdgeInsets.only(top: Space.md),
            child: Text(
              'The payout does not match the lines, so this cannot be posted. Correct the report and import it again.',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        const SizedBox(height: Space.lg),
        SectionCard(
          title: 'Expected and received, by order',
          child: s.orders.isEmpty
              ? Text(
                  'No order lines in this report.',
                  style: theme.textTheme.bodySmall,
                )
              : wide
              ? _OrdersTable(orders: s.orders)
              : Column(
                  children: [for (final o in s.orders) _OrderTile(order: o)],
                ),
        ),
        const SizedBox(height: Space.md),
        SectionCard(
          title: 'Where the money went',
          child: Column(
            children: [
              for (final e in s.totals.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(child: Text(_kindWords[e.key] ?? e.key)),
                      Text(
                        formatMoney(e.value),
                        style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (s.tcs != null && s.tds != null) ...[
          const SizedBox(height: Space.md),
          SectionCard(
            title: 'Tax held by the channel',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _StatutoryRow(label: 'TCS (GST section 52)', line: s.tcs!),
                const SizedBox(height: Space.sm),
                _StatutoryRow(label: 'TDS (section 194-O)', line: s.tds!),
                const SizedBox(height: Space.sm),
                Text(
                  s.note.isEmpty ? 'Check the rates before filing.' : s.note,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
        if (widget.manage && s.canPost) ...[
          const SizedBox(height: Space.lg),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const Key('settlement-post'),
              style: bigButton,
              onPressed: _busy ? null : _post,
              child: const Text('Post to the books'),
            ),
          ),
        ],
      ],
    );
  }
}

class _OrdersTable extends StatelessWidget {
  const _OrdersTable({required this.orders});

  final List<OrderRecon> orders;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('Order')),
          DataColumn(label: Text('Sales order')),
          DataColumn(label: Text('Expected'), numeric: true),
          DataColumn(label: Text('Received'), numeric: true),
          DataColumn(label: Text('Difference'), numeric: true),
          DataColumn(label: Text('Fees'), numeric: true),
        ],
        rows: [
          for (final o in orders)
            DataRow(
              cells: [
                DataCell(Text(o.orderRef)),
                DataCell(Text(o.matched ? (o.orderNumber ?? '') : 'Not found')),
                DataCell(
                  Text(o.expected == null ? '' : formatMoney(o.expected)),
                ),
                DataCell(Text(formatMoney(o.received))),
                DataCell(
                  Text(o.difference == null ? '' : formatMoney(o.difference)),
                ),
                DataCell(Text(formatMoney(o.fees))),
              ],
            ),
        ],
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order});

  final OrderRecon order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final off = order.difference != null && order.difference != 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  order.orderRef,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!order.matched) const Pill('Order not found'),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Expected ${order.expected == null ? 'unknown' : formatMoney(order.expected)}',
                ),
              ),
              Text('Received ${formatMoney(order.received)}'),
            ],
          ),
          if (off)
            Text(
              'Difference ${formatMoney(order.difference)}',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          if (order.fees != 0)
            Text(
              'Fees and tax ${formatMoney(order.fees)}',
              style: theme.textTheme.bodySmall,
            ),
          const Divider(height: Space.lg),
        ],
      ),
    );
  }
}

class _StatutoryRow extends StatelessWidget {
  const _StatutoryRow({required this.label, required this.line});

  final String label;
  final StatutoryLine line;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Space.lg,
      runSpacing: Space.xs,
      children: [
        SizedBox(
          width: 190,
          child: Text('$label at ${formatPercent(line.rate)}'),
        ),
        Text('Expected ${formatMoney(line.expected)}'),
        Text('Held ${formatMoney(line.received)}'),
        if (line.difference != 0)
          Text('Difference ${formatMoney(line.difference)}'),
      ],
    );
  }
}
