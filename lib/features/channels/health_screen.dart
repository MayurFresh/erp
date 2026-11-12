import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'channels_models.dart';
import 'channels_perms.dart';
import 'channels_repository.dart';
import 'channels_widgets.dart';

/// `/channels/:id/health`: connection, credentials, sync and stock push of a
/// live channel (Shopify, WooCommerce).
class ChannelHealthScreen extends ConsumerWidget {
  const ChannelHealthScreen({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = ref.watch(permissionsProvider).can(ChPerm.manage);
    return CGate(
      anyOf: const [ChPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Connection health',
            subtitle: 'Credentials, sync and stock updates',
            actions: [
              TextButton(
                onPressed: () => context.go('/channels'),
                child: const Text('Back to channels'),
              ),
            ],
          ),
          Expanded(
            child: AsyncValueView<ChannelHealth>(
              value: ref.watch(channelHealthProvider(channelId)),
              onRetry: () => ref.invalidate(channelHealthProvider(channelId)),
              data: (h) => ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  _StatusCard(health: h, manage: manage),
                  const SizedBox(height: Space.md),
                  _CountsCard(health: h),
                  if (h.live) ...[
                    const SizedBox(height: Space.md),
                    _CredentialsCard(
                      key: ValueKey(
                        'cred-${h.credentials.map((c) => c.isSet).join()}',
                      ),
                      health: h,
                      manage: manage,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _when(DateTime? d) => d == null ? 'never' : formatDateTime(d);

class _StatusCard extends ConsumerStatefulWidget {
  const _StatusCard({required this.health, required this.manage});

  final ChannelHealth health;
  final bool manage;

  @override
  ConsumerState<_StatusCard> createState() => _StatusCardState();
}

class _StatusCardState extends ConsumerState<_StatusCard> {
  String? _busy;

  Future<void> _run(String key, Future<void> Function() job) async {
    setState(() => _busy = key);
    try {
      await job();
      ref.bumpChannels();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.health;
    final repo = ref.read(channelsRepositoryProvider);
    final theme = Theme.of(context);
    final canAct = widget.manage && h.live && h.hasCredentials;
    return SectionCard(
      title: 'Status',
      trailing: StatusPill(h.status),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!h.live)
            Text(
              'This channel has no live connection. Orders come from CSV files.',
              style: theme.textTheme.bodySmall,
            )
          else ...[
            if (h.statusReason.isNotEmpty)
              Text(h.statusReason, style: theme.textTheme.bodyMedium),
            const SizedBox(height: Space.sm),
            Text('Last pull: ${_when(h.lastSuccessAt)}'),
            Text('Last check: ${_when(h.lastCheckAt)}'),
            if (h.lastError != null) ...[
              const SizedBox(height: Space.sm),
              Text(
                'Last error (${_when(h.lastErrorAt)}): ${h.lastError}',
                key: const Key('health-last-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: Space.md),
            Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                FilledButton.tonal(
                  key: const Key('health-check'),
                  onPressed: canAct && _busy == null
                      ? () => _run('check', () async {
                          final (ok, msg) = await repo.check(h.id);
                          if (mounted) {
                            showInfoSnackBar(
                              context,
                              msg.isEmpty
                                  ? (ok ? 'Connected' : 'Check failed')
                                  : msg,
                            );
                          }
                        })
                      : null,
                  child: Text(
                    _busy == 'check' ? 'Checking...' : 'Check connection',
                  ),
                ),
                OutlinedButton(
                  key: const Key('health-sync'),
                  onPressed: canAct && h.status == 'connected' && _busy == null
                      ? () => _run('sync', () async {
                          await repo.sync(h.id, 'orders');
                          if (context.mounted) {
                            showInfoSnackBar(context, 'Sync queued');
                          }
                        })
                      : null,
                  child: const Text('Sync now'),
                ),
              ],
            ),
            SwitchListTile(
              key: const Key('health-push-stock'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Push stock'),
              subtitle: const Text(
                'Send stock quantities to the store when they change',
              ),
              value: h.pushStock,
              onChanged: canAct && h.status == 'connected' && _busy == null
                  ? (v) => _run(
                      'push',
                      () => repo.updateChannel(h.id, {'pushStock': v}),
                    )
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

class _CredentialsCard extends ConsumerStatefulWidget {
  const _CredentialsCard({
    super.key,
    required this.health,
    required this.manage,
  });

  final ChannelHealth health;
  final bool manage;

  @override
  ConsumerState<_CredentialsCard> createState() => _CredentialsCardState();
}

class _CredentialsCardState extends ConsumerState<_CredentialsCard> {
  late final Map<String, TextEditingController> _ctl = {
    for (final f in widget.health.credentials) f.key: TextEditingController(),
  };
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final values = {for (final e in _ctl.entries) e.key: e.value.text.trim()};
    if (values.values.any((v) => v.isEmpty)) {
      showInfoSnackBar(
        context,
        'Fill every field. Saving replaces all values.',
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(channelsRepositoryProvider)
          .saveCredentials(widget.health.id, values);
      for (final c in _ctl.values) {
        c.clear();
      }
      ref.bumpChannels();
      if (mounted) showInfoSnackBar(context, 'Saved. Run Check connection.');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Remove credentials?'),
        content: const Text(
          'The connection stops and stock updates are switched off.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('cred-remove-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(channelsRepositoryProvider)
          .removeCredentials(widget.health.id);
      ref.bumpChannels();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.health;
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Credentials',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Saved values are never shown. Type new values for every field to replace them.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Space.md),
          for (final f in h.credentials)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.md),
              child: TextField(
                key: Key('cred-${f.key}'),
                controller: _ctl[f.key],
                enabled: widget.manage && !_busy,
                obscureText: f.secret,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: f.label,
                  helperText: f.isSet ? 'Saved' : 'Not set',
                ),
              ),
            ),
          if (widget.manage)
            Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                FilledButton(
                  key: const Key('cred-save'),
                  onPressed: _busy ? null : _save,
                  child: const Text('Save credentials'),
                ),
                if (h.hasCredentials)
                  OutlinedButton(
                    key: const Key('cred-remove'),
                    onPressed: _busy ? null : _remove,
                    child: const Text('Remove'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _CountsCard extends StatelessWidget {
  const _CountsCard({required this.health});

  final ChannelHealth health;

  @override
  Widget build(BuildContext context) {
    final h = health;
    return SectionCard(
      title: 'Queues and errors',
      child: Wrap(
        spacing: Space.sm,
        runSpacing: Space.sm,
        children: [
          SummaryChip('jobs queued', h.queuedJobs),
          SummaryChip('orders waiting', h.received),
          SummaryChip('orders failed', h.failed),
          SummaryChip('orders given up', h.dead),
          SummaryChip('SKUs to map', h.unmapped),
          SummaryChip('stock push errors', h.pushErrors),
          SummaryChip('webhooks rejected', h.webhookRejects),
        ],
      ),
    );
  }
}
