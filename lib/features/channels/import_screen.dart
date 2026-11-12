import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'channels_models.dart';
import 'channels_perms.dart';
import 'channels_repository.dart';
import 'channels_widgets.dart';

/// `/channels/import`: choose an order file, see what it will create, then import it.
class ChannelImportScreen extends ConsumerStatefulWidget {
  const ChannelImportScreen({super.key, this.channelId});

  final String? channelId;

  @override
  ConsumerState<ChannelImportScreen> createState() =>
      _ChannelImportScreenState();
}

class _ChannelImportScreenState extends ConsumerState<ChannelImportScreen> {
  late String? _channelId = widget.channelId;
  final _csv = TextEditingController();
  ImportPreview? _preview;
  ImportResult? _result;
  bool _busy = false;

  @override
  void dispose() {
    _csv.dispose();
    super.dispose();
  }

  void _changed() => setState(() {
    _preview = null;
    _result = null;
  });

  Future<void> _previewIt() async {
    final id = _channelId;
    if (id == null || _csv.text.trim().isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final p = await ref
          .read(channelsRepositoryProvider)
          .previewOrders(id, _csv.text);
      if (mounted) setState(() => _preview = p);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importIt() async {
    final id = _channelId;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      final r = await ref
          .read(channelsRepositoryProvider)
          .importOrders(id, _csv.text);
      ref.bumpChannels();
      if (mounted) {
        setState(() {
          _result = r;
          _preview = null;
        });
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
    final r = _result;
    final creates = p?.summary['create'] ?? 0;
    final cancels = p?.summary['cancel'] ?? 0;
    final blocked = p?.summary['blocked'] ?? 0;
    return CGate(
      anyOf: const [ChPerm.manage],
      child: FormPage(
        maxWidth: 900,
        children: [
          Text('Import orders', style: theme.textTheme.titleLarge),
          const SizedBox(height: Space.xs),
          Text(
            'Columns: order_id, order_date, sku, title, qty, unit_price, discount, ship_state, status. '
            'Rows with the same order_id are one order. Importing a file twice does not repeat orders.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Space.lg),
          ChannelDropdown(
            value: _channelId,
            onChanged: (v) {
              _channelId = v;
              _changed();
            },
          ),
          const SizedBox(height: Space.md),
          CsvInput(
            controller: _csv,
            onChanged: _changed,
            hint:
                'order_id,order_date,sku,title,qty,unit_price,discount,ship_state,status',
          ),
          const SizedBox(height: Space.md),
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              FilledButton(
                key: const Key('import-preview'),
                style: bigButton,
                onPressed:
                    _busy || _channelId == null || _csv.text.trim().isEmpty
                    ? null
                    : _previewIt,
                child: Text(_busy && p == null ? 'Checking…' : 'Preview'),
              ),
              if (p != null)
                FilledButton(
                  key: const Key('import-run'),
                  style: bigButton,
                  onPressed: _busy || (creates + cancels == 0)
                      ? null
                      : _importIt,
                  child: Text(
                    creates == 0
                        ? 'Apply'
                        : 'Create $creates order${creates == 1 ? '' : 's'}',
                  ),
                ),
            ],
          ),
          if (p != null) ...[
            const SizedBox(height: Space.lg),
            Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                SummaryChip('to create', creates),
                SummaryChip('already imported', p.summary['duplicate'] ?? 0),
                SummaryChip('to cancel', cancels),
                SummaryChip(
                  'cannot import',
                  blocked,
                  color: blocked > 0 ? theme.colorScheme.error : null,
                ),
              ],
            ),
            if (blocked > 0) ...[
              const SizedBox(height: Space.sm),
              Row(
                children: [
                  const Icon(Icons.info_outline, size: 18),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      'Orders with unmapped SKUs wait in the inbox. Map the SKUs and they are created.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        context.go('/channels/mapping?channelId=$_channelId'),
                    child: const Text('Map SKUs'),
                  ),
                ],
              ),
            ],
            for (final issue in p.issues)
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: Text(
                  issue,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: Space.md),
            for (final o in p.orders) _PreviewRow(order: o),
          ],
          if (r != null) ...[
            const SizedBox(height: Space.lg),
            SectionCard(
              title: 'Import finished',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.sm,
                    children: [
                      SummaryChip('created', r.summary['created'] ?? 0),
                      SummaryChip(
                        'already imported',
                        r.summary['duplicates'] ?? 0,
                      ),
                      SummaryChip('cancelled', r.summary['cancelled'] ?? 0),
                      SummaryChip('need attention', r.summary['failed'] ?? 0),
                      if ((r.summary['heldAsDraft'] ?? 0) > 0)
                        SummaryChip(
                          'kept as drafts (short stock)',
                          r.summary['heldAsDraft']!,
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  TextButton(
                    onPressed: () =>
                        context.go('/channels/orders?channelId=$_channelId'),
                    child: const Text('See the orders'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.order});

  final PreviewOrder order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: Space.sm),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  order.externalRef,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              StatusPill(order.action),
            ],
          ),
          if (order.lines.isNotEmpty) Text(order.lines.join(', ')),
          if (order.total != null)
            Text(
              'About ${formatMoney(order.total)} with tax',
              style: theme.textTheme.bodySmall,
            ),
          if (order.reason != null)
            Text(order.reason!, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
