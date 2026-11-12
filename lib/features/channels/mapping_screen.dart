import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../items/item_picker.dart';
import 'channels_models.dart';
import 'channels_perms.dart';
import 'channels_repository.dart';
import 'channels_widgets.dart';

final _mappingProvider = FutureProvider.autoDispose
    .family<({List<Listing> listings, List<UnmappedSku> unmapped}), String>((
      ref,
      id,
    ) async {
      ref.watch(channelsRevisionProvider);
      final repo = ref.watch(channelsRepositoryProvider);
      final results = await Future.wait([
        repo.listings(id, limit: 200),
        repo.unmapped(id),
      ]);
      return (
        listings: (results[0] as Paged<Listing>).data,
        unmapped: (results[1] as Paged<UnmappedSku>).data,
      );
    });

/// `/channels/mapping`: which of your items each channel SKU stands for.
class SkuMappingScreen extends ConsumerStatefulWidget {
  const SkuMappingScreen({super.key, this.channelId});

  final String? channelId;

  @override
  ConsumerState<SkuMappingScreen> createState() => _SkuMappingScreenState();
}

class _SkuMappingScreenState extends ConsumerState<SkuMappingScreen> {
  late String? _channelId = widget.channelId;

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(ChPerm.manage);
    final channels = ref.watch(channelsProvider).value;
    _channelId ??= channels == null || channels.isEmpty
        ? null
        : channels.first.id;
    final id = _channelId;
    final theme = Theme.of(context);
    return CGate(
      anyOf: const [ChPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'SKU mapping',
            subtitle:
                'Say which item each channel SKU is. Orders with an unmapped SKU wait until you do.',
            actions: [
              if (manage && id != null)
                FilledButton.icon(
                  key: const Key('map-add'),
                  style: bigButton,
                  onPressed: () => _edit(context, id, null, null),
                  icon: const Icon(Icons.add),
                  label: const Text('Map a SKU'),
                ),
            ],
          ),
          FilterBar(
            children: [
              ChannelDropdown(
                value: id,
                onChanged: (v) => setState(() => _channelId = v),
              ),
            ],
          ),
          Expanded(
            child: id == null
                ? const EmptyView(
                    icon: Icons.link_outlined,
                    message: 'Add a channel first.',
                  )
                : AsyncValueView(
                    value: ref.watch(_mappingProvider(id)),
                    onRetry: () => ref.invalidate(_mappingProvider(id)),
                    data: (m) => ListView(
                      padding: EdgeInsets.fromLTRB(
                        pageGutter(context),
                        Space.sm,
                        pageGutter(context),
                        Space.xl,
                      ),
                      children: [
                        if (m.unmapped.isNotEmpty)
                          SectionCard(
                            title: 'To map (${m.unmapped.length})',
                            child: Column(
                              children: [
                                for (final u in m.unmapped)
                                  ListTile(
                                    key: Key('unmapped-${u.channelSku}'),
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(
                                      u.channelSku,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      [
                                        if (u.title != null) u.title!,
                                        'seen ${u.seenCount} time${u.seenCount == 1 ? '' : 's'}',
                                      ].join(' · '),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: manage
                                        ? FilledButton.tonal(
                                            onPressed: () =>
                                                _edit(context, id, null, u),
                                            child: const Text('Map'),
                                          )
                                        : null,
                                  ),
                              ],
                            ),
                          ),
                        if (m.unmapped.isNotEmpty)
                          const SizedBox(height: Space.md),
                        SectionCard(
                          title: 'Mapped (${m.listings.length})',
                          child: m.listings.isEmpty
                              ? Text(
                                  'Nothing mapped yet.',
                                  style: theme.textTheme.bodySmall,
                                )
                              : Column(
                                  children: [
                                    for (final l in m.listings)
                                      ListTile(
                                        key: Key('listing-${l.channelSku}'),
                                        contentPadding: EdgeInsets.zero,
                                        title: Text(
                                          l.channelSku,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: Text(
                                          l.components
                                              .map(
                                                (c) => c.qty == 1
                                                    ? c.itemName
                                                    : '${formatQty(c.qty)} x ${c.itemName}',
                                              )
                                              .join(' + '),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        trailing: manage
                                            ? Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  IconButton(
                                                    tooltip: 'Edit',
                                                    icon: const Icon(
                                                      Icons.edit_outlined,
                                                    ),
                                                    onPressed: () => _edit(
                                                      context,
                                                      id,
                                                      l,
                                                      null,
                                                    ),
                                                  ),
                                                  IconButton(
                                                    tooltip: 'Remove',
                                                    icon: const Icon(
                                                      Icons.delete_outline,
                                                    ),
                                                    onPressed: () =>
                                                        _remove(context, id, l),
                                                  ),
                                                ],
                                              )
                                            : null,
                                      ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    String channelId,
    Listing? listing,
    UnmappedSku? from,
  ) async {
    final created = await showFormDialog<int>(
      context: context,
      builder: (_) => _MapDialog(
        channelId: channelId,
        listing: listing,
        sku: from?.channelSku,
        title: from?.title,
      ),
    );
    if (created == null) return;
    ref.bumpChannels();
    if (created > 0 && context.mounted) {
      showInfoSnackBar(
        context,
        '$created waiting order${created == 1 ? '' : 's'} created',
      );
    }
  }

  Future<void> _remove(
    BuildContext context,
    String channelId,
    Listing l,
  ) async {
    final ok = await confirm(
      context,
      title: 'Remove mapping',
      message:
          'Orders with ${l.channelSku} will wait again until it is mapped.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(channelsRepositoryProvider).deleteListing(channelId, l.id);
      ref.bumpChannels();
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }
}

class _Comp {
  _Comp({this.itemId, this.itemName, String qty = '1'})
    : qty = TextEditingController(text: qty);
  String? itemId;
  String? itemName;
  final TextEditingController qty;
}

class _MapDialog extends ConsumerStatefulWidget {
  const _MapDialog({
    required this.channelId,
    this.listing,
    this.sku,
    this.title,
  });

  final String channelId;
  final Listing? listing;
  final String? sku;
  final String? title;

  @override
  ConsumerState<_MapDialog> createState() => _MapDialogState();
}

class _MapDialogState extends ConsumerState<_MapDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _sku = TextEditingController(
    text: widget.listing?.channelSku ?? widget.sku,
  );
  late final List<_Comp> _comps = [
    for (final c in widget.listing?.components ?? const <ListingComponent>[])
      _Comp(itemId: c.itemId, itemName: c.itemName, qty: formatPlain(c.qty)),
  ];
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (_comps.isEmpty) _comps.add(_Comp());
  }

  @override
  void dispose() {
    _sku.dispose();
    for (final c in _comps) {
      c.qty.dispose();
    }
    super.dispose();
  }

  Future<void> _pick(_Comp c) async {
    final item = await pickItem(context, ref, stockOnly: true);
    if (item == null) return;
    setState(() {
      c.itemId = item.id;
      c.itemName = item.name;
      _error = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final valid = validateAndReveal(_formKey);
    if (_comps.any((c) => c.itemId == null)) {
      setState(() => _error = 'Choose an item for each row');
      return;
    }
    if (!valid) return;
    setState(() => _saving = true);
    try {
      final created = await ref
          .read(channelsRepositoryProvider)
          .saveListing(
            widget.channelId,
            listingId: widget.listing?.id,
            channelSku: _sku.text.trim(),
            title: widget.title,
            components: [
              for (final c in _comps)
                (itemId: c.itemId!, qty: parseNumber(c.qty.text) ?? 1),
            ],
          );
      if (mounted) Navigator.of(context).pop(created);
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
      title: Text(widget.listing == null ? 'Map a SKU' : 'Edit mapping'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const Key('map-sku'),
                  controller: _sku,
                  decoration: const InputDecoration(labelText: 'Channel SKU'),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Enter the SKU' : null,
                ),
                const SizedBox(height: Space.md),
                Text(
                  'Your item${_comps.length > 1 ? 's' : ''}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: Space.xs),
                for (var i = 0; i < _comps.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.sm),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            key: Key('map-item-$i'),
                            onPressed: () => _pick(_comps[i]),
                            style: OutlinedButton.styleFrom(
                              alignment: Alignment.centerLeft,
                              minimumSize: const Size.fromHeight(48),
                            ),
                            child: Text(
                              _comps[i].itemName ?? 'Choose item',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(width: Space.sm),
                        SizedBox(
                          width: 72,
                          child: TextFormField(
                            controller: _comps[i].qty,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(labelText: 'Qty'),
                            validator: (v) =>
                                (parseNumber(v ?? '') ?? 0) > 0 ? null : 'Qty',
                          ),
                        ),
                        if (_comps.length > 1)
                          IconButton(
                            tooltip: 'Remove item',
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(
                              () => _comps.removeAt(i).qty.dispose(),
                            ),
                          ),
                      ],
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _comps.add(_Comp())),
                    icon: const Icon(Icons.add),
                    label: const Text('Add another item (bundle)'),
                  ),
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
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
          key: const Key('map-save'),
          onPressed: _saving ? null : _save,
          child: const Text('Save mapping'),
        ),
      ],
    );
  }
}
