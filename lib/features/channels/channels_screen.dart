import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../locations/location_filter.dart';
import 'channels_models.dart';
import 'channels_perms.dart';
import 'channels_repository.dart';
import 'channels_widgets.dart';

const _providers = <String, String>{
  'manual': 'File import (CSV)',
  'amazon': 'Amazon',
  'flipkart': 'Flipkart',
  'meesho': 'Meesho',
  'shopify': 'Shopify',
  'woocommerce': 'WooCommerce',
  'other': 'Other channel',
};

/// `/channels`: the channels the business sells on, and how each is set up.
class ChannelsScreen extends ConsumerWidget {
  const ChannelsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = ref.watch(permissionsProvider).can(ChPerm.manage);
    final channels = ref.watch(channelsProvider);
    return CGate(
      anyOf: const [ChPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Channels',
            subtitle: 'Orders and payouts from marketplaces and web stores',
            actions: [
              if (manage)
                FilledButton.icon(
                  key: const Key('channel-add'),
                  style: bigButton,
                  onPressed: () => _add(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('Add channel'),
                ),
            ],
          ),
          Expanded(
            child: AsyncValueView<List<Channel>>(
              value: channels,
              onRetry: () => ref.invalidate(channelsProvider),
              data: (list) => list.isEmpty
                  ? const EmptyView(
                      icon: Icons.storefront_outlined,
                      message:
                          'No channels yet.\nAdd one, then import its order file.',
                    )
                  : ListView.separated(
                      padding: EdgeInsets.fromLTRB(
                        pageGutter(context),
                        Space.sm,
                        pageGutter(context),
                        Space.xl,
                      ),
                      itemCount: list.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: Space.sm),
                      itemBuilder: (context, i) =>
                          _ChannelCard(channel: list[i], manage: manage),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final done = await showFormDialog<bool>(
      context: context,
      builder: (_) => const _AddChannelDialog(),
    );
    if (done == true) ref.bumpChannels();
  }
}

class _ChannelCard extends ConsumerWidget {
  const _ChannelCard({required this.channel, required this.manage});

  final Channel channel;
  final bool manage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = channel;
    final theme = Theme.of(context);
    final orders = c.orderCounts.values.fold<int>(0, (a, b) => a + b);
    return SectionCard(
      title: c.name,
      trailing: StatusPill(c.status),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              _providers[c.provider] ?? c.provider,
              if (c.locationName.isNotEmpty) 'ships from ${c.locationName}',
              c.pricesIncludeTax ? 'prices include tax' : 'prices before tax',
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
          if (c.isFileOnly &&
              c.provider != 'shopify' &&
              c.provider != 'woocommerce') ...[
            const SizedBox(height: Space.xs),
            Text(
              'No live connection yet. Orders and payouts come from CSV files.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: Space.md),
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              SummaryChip('orders', orders),
              SummaryChip('SKUs mapped', c.listingCount),
              if (c.unmappedCount > 0)
                SummaryChip('SKUs to map', c.unmappedCount),
              if (c.failedCount > 0)
                SummaryChip('need attention', c.failedCount),
            ],
          ),
          if (c.lastImportAt != null) ...[
            const SizedBox(height: Space.sm),
            Text(
              'Last import ${formatDateTime(c.lastImportAt)}',
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: Space.md),
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              if (manage)
                FilledButton.tonal(
                  onPressed: () =>
                      context.go('/channels/import?channelId=${c.id}'),
                  child: const Text('Import orders'),
                ),
              OutlinedButton(
                onPressed: () =>
                    context.go('/channels/mapping?channelId=${c.id}'),
                child: Text(
                  c.unmappedCount > 0
                      ? 'Map SKUs (${c.unmappedCount})'
                      : 'SKU mapping',
                ),
              ),
              OutlinedButton(
                onPressed: () =>
                    context.go('/channels/orders?channelId=${c.id}'),
                child: const Text('Orders'),
              ),
              if (c.provider == 'shopify' || c.provider == 'woocommerce')
                OutlinedButton(
                  key: Key('channel-health-${c.id}'),
                  onPressed: () => context.go('/channels/${c.id}/health'),
                  child: const Text('Connection'),
                ),
              if (manage)
                TextButton(
                  onPressed: () async {
                    try {
                      await ref
                          .read(channelsRepositoryProvider)
                          .updateChannel(c.id, {
                            'status': c.status == 'disabled'
                                ? 'connected'
                                : 'disabled',
                            'expectedUpdatedAt': c.updatedAt,
                          });
                      ref.bumpChannels();
                    } catch (e) {
                      if (context.mounted) showErrorSnackBar(context, e);
                    }
                  },
                  child: Text(c.status == 'disabled' ? 'Turn on' : 'Turn off'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AddChannelDialog extends ConsumerStatefulWidget {
  const _AddChannelDialog();

  @override
  ConsumerState<_AddChannelDialog> createState() => _AddChannelDialogState();
}

class _AddChannelDialogState extends ConsumerState<_AddChannelDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  String _provider = 'manual';
  String? _locationId;
  bool _inclusive = true;
  bool _draft = false;
  bool _saving = false;
  String? _locationError;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final valid = validateAndReveal(_formKey);
    if (_locationId == null) {
      setState(() => _locationError = 'Choose where orders ship from');
    }
    if (!valid || _locationId == null) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(channelsRepositoryProvider)
          .createChannel(
            provider: _provider,
            name: _name.text.trim(),
            locationId: _locationId!,
            pricesIncludeTax: _inclusive,
            orderStatus: _draft ? 'draft' : 'confirmed',
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showErrorSnackBar(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add channel'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  key: const Key('channel-provider'),
                  initialValue: _provider,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Channel type'),
                  items: [
                    for (final e in _providers.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() => _provider = v ?? 'manual'),
                ),
                const SizedBox(height: Space.md),
                TextFormField(
                  key: const Key('channel-name'),
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Enter a name' : null,
                ),
                const SizedBox(height: Space.md),
                LocationField(
                  label: 'Ships from',
                  value: _locationId,
                  errorText: _locationError,
                  onChanged: (v) => setState(() {
                    _locationId = v;
                    _locationError = null;
                  }),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Prices include tax'),
                  value: _inclusive,
                  onChanged: (v) => setState(() => _inclusive = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Keep new orders as drafts'),
                  subtitle: const Text(
                    'Otherwise they are confirmed and stock is reserved.',
                  ),
                  value: _draft,
                  onChanged: (v) => setState(() => _draft = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('channel-save'),
          onPressed: _saving ? null : _save,
          child: const Text('Add channel'),
        ),
      ],
    );
  }
}
