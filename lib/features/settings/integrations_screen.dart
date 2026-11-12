import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'settings_models.dart';
import 'settings_repository.dart';

class ApiKeyRow {
  ApiKeyRow(Json j)
    : id = asString(j['id']),
      name = asString(j['name']),
      prefix = asString(j['prefix']),
      roleName = asStringOrNull(j['roleName']),
      expiresAt = asStringOrNull(j['expiresAt']),
      lastUsedAt = asStringOrNull(j['lastUsedAt']),
      revokedAt = asStringOrNull(j['revokedAt']);

  final String id, name, prefix;
  final String? roleName, expiresAt, lastUsedAt, revokedAt;
}

class WebhookRow {
  WebhookRow(Json j)
    : id = asString(j['id']),
      url = asString(j['url']),
      description = asStringOrNull(j['description']),
      events = [for (final e in (j['events'] as List? ?? const [])) '$e'],
      isActive = asBool(j['isActive'], true),
      lastStatus = asStringOrNull(asJsonOrNull(j['lastDelivery'])?['status']);

  final String id, url;
  final String? description, lastStatus;
  final List<String> events;
  final bool isActive;
}

class DeliveryRow {
  DeliveryRow(Json j)
    : event = asString(j['event']),
      status = asString(j['status']),
      attempts = asInt(j['attempts']),
      responseStatus = j['responseStatus'] == null
          ? null
          : asInt(j['responseStatus']),
      error = asStringOrNull(j['error']),
      createdAt = asStringOrNull(j['createdAt']);

  final String event, status;
  final int attempts;
  final int? responseStatus;
  final String? error, createdAt;
}

final apiKeysProvider = FutureProvider.autoDispose<List<ApiKeyRow>>((
  ref,
) async {
  ref.watch(activeCompanyIdProvider);
  final body = await ref.watch(apiClientProvider).getJson('/api-keys');
  return asJsonList(body['data']).map(ApiKeyRow.new).toList();
});

final webhooksProvider = FutureProvider.autoDispose<List<WebhookRow>>((
  ref,
) async {
  ref.watch(activeCompanyIdProvider);
  final body = await ref.watch(apiClientProvider).getJson('/webhooks');
  return asJsonList(body['data']).map(WebhookRow.new).toList();
});

final webhookEventsProvider = FutureProvider.autoDispose<List<String>>((
  ref,
) async {
  final body = await ref.watch(apiClientProvider).getJson('/webhooks/events');
  return [for (final e in (body['data'] as List? ?? const [])) '$e'];
});

final webhookDeliveriesProvider = FutureProvider.autoDispose
    .family<List<DeliveryRow>, String>((ref, id) async {
      final body = await ref
          .watch(apiClientProvider)
          .getJson('/webhooks/$id/deliveries', query: {'limit': 50});
      return asJsonList(body['data']).map(DeliveryRow.new).toList();
    });

String _stamp(String? iso) {
  final d = DateTime.tryParse(iso ?? '')?.toLocal();
  return d == null ? '' : DateFormat('d MMM y, h:mm a').format(d);
}

/// `/integrations`: API keys and outbound webhooks (permission
/// `integrations.manage`). Secrets are shown once, right after creation.
class IntegrationsScreen extends ConsumerWidget {
  const IntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => DefaultTabController(
    length: 2,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: const [
        PageHeader(
          title: 'Integrations',
          subtitle: 'API keys and webhooks for other software',
        ),
        TabBar(
          tabs: [
            Tab(text: 'API keys'),
            Tab(text: 'Webhooks'),
          ],
        ),
        Expanded(child: TabBarView(children: [_KeysTab(), _HooksTab()])),
      ],
    ),
  );
}

Future<void> _showSecret(
  BuildContext context, {
  required String title,
  required String label,
  required String secret,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Copy this now. It is not shown again.'),
          const SizedBox(height: 12),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          SelectableText(
            secret,
            key: const Key('secret-text'),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const Key('secret-copy'),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: secret));
          if (context.mounted) showInfoSnackBar(context, 'Copied');
        },
        child: const Text('Copy'),
      ),
      FilledButton(
        key: const Key('secret-done'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Done'),
      ),
    ],
  ),
);

class _KeysTab extends ConsumerWidget {
  const _KeysTab();

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final roles = await ref.read(adminRolesProvider.future);
    if (!context.mounted) return;
    final body = await showFormDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => _KeyDialog(roles: roles),
    );
    if (body == null || !context.mounted) return;
    try {
      final made = await ref
          .read(apiClientProvider)
          .postJson('/api-keys', body: body);
      ref.invalidate(apiKeysProvider);
      if (!context.mounted) return;
      await _showSecret(
        context,
        title: 'API key created',
        label: 'Key',
        secret: asString(made['key']),
      );
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _revoke(BuildContext context, WidgetRef ref, ApiKeyRow k) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Revoke ${k.name}?'),
        content: const Text('Software using this key stops working at once.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('revoke-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(apiClientProvider).postJson('/api-keys/${k.id}/revoke');
      ref.invalidate(apiKeysProvider);
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const Key('key-new'),
              onPressed: () => _create(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('New API key'),
            ),
          ),
        ),
        Expanded(
          child: AsyncValueView(
            value: ref.watch(apiKeysProvider),
            onRetry: () => ref.invalidate(apiKeysProvider),
            data: (keys) => keys.isEmpty
                ? const EmptyView(message: 'No API keys yet.')
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: keys.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final k = keys[i];
                      final revoked = k.revokedAt != null;
                      return Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Wrap(
                                      spacing: 8,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        Text(
                                          k.name,
                                          style: theme.textTheme.titleMedium,
                                        ),
                                        if (revoked)
                                          Pill(
                                            'Revoked',
                                            color: theme.colorScheme.error,
                                          ),
                                      ],
                                    ),
                                    Text('${k.prefix}...  ${k.roleName ?? ''}'),
                                    Text(
                                      k.lastUsedAt == null
                                          ? 'Never used'
                                          : 'Last used ${_stamp(k.lastUsedAt)}',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                    if (k.expiresAt != null)
                                      Text(
                                        'Expires ${_stamp(k.expiresAt)}',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                  ],
                                ),
                              ),
                              if (!revoked)
                                TextButton(
                                  key: Key('revoke-${k.id}'),
                                  onPressed: () => _revoke(context, ref, k),
                                  child: const Text('Revoke'),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _KeyDialog extends StatefulWidget {
  const _KeyDialog({required this.roles});
  final List<Role> roles;

  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  final _name = TextEditingController();
  String? _role;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Required');
      return;
    }
    if (_role == null) {
      setState(() => _error = 'Pick a role');
      return;
    }
    Navigator.of(context).pop({'name': _name.text.trim(), 'roleId': _role});
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New API key'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('key-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('key-role'),
              isExpanded: true,
              initialValue: _role,
              decoration: const InputDecoration(
                labelText: 'Role',
                helperText: 'The key can do what this role can do.',
                helperMaxLines: 2,
              ),
              items: [
                for (final r in widget.roles)
                  DropdownMenuItem(
                    value: r.id,
                    child: Text(r.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _role = v),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('key-save'),
        onPressed: _save,
        child: const Text('Create'),
      ),
    ],
  );
}

class _HooksTab extends ConsumerWidget {
  const _HooksTab();

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final events = await ref.read(webhookEventsProvider.future);
    if (!context.mounted) return;
    final body = await showFormDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => _HookDialog(events: events),
    );
    if (body == null || !context.mounted) return;
    try {
      final made = await ref
          .read(apiClientProvider)
          .postJson('/webhooks', body: body);
      ref.invalidate(webhooksProvider);
      if (!context.mounted) return;
      await _showSecret(
        context,
        title: 'Webhook created',
        label: 'Signing secret',
        secret: asString(made['secret']),
      );
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _call(
    BuildContext context,
    WidgetRef ref,
    Future<Object?> Function(ApiClient api) run, {
    String? done,
  }) async {
    try {
      await run(ref.read(apiClientProvider));
      ref.invalidate(webhooksProvider);
      if (done != null && context.mounted) showInfoSnackBar(context, done);
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const Key('hook-new'),
              onPressed: () => _create(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('New webhook'),
            ),
          ),
        ),
        Expanded(
          child: AsyncValueView(
            value: ref.watch(webhooksProvider),
            onRetry: () => ref.invalidate(webhooksProvider),
            data: (hooks) => hooks.isEmpty
                ? const EmptyView(message: 'No webhooks yet.')
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: hooks.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final h = hooks[i];
                      return Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      h.url,
                                      style: theme.textTheme.titleSmall,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (h.description != null &&
                                        h.description!.isNotEmpty)
                                      Text(h.description!),
                                    Text(
                                      h.events.join(', '),
                                      style: theme.textTheme.bodySmall,
                                    ),
                                    Wrap(
                                      spacing: 8,
                                      children: [
                                        if (!h.isActive)
                                          Pill(
                                            'Paused',
                                            color: theme.colorScheme.error,
                                          ),
                                        if (h.lastStatus != null)
                                          Text(
                                            'Last delivery: ${h.lastStatus}',
                                            style: theme.textTheme.bodySmall,
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              PopupMenuButton<String>(
                                key: Key('hook-menu-${h.id}'),
                                onSelected: (v) async {
                                  switch (v) {
                                    case 'test':
                                      await _call(
                                        context,
                                        ref,
                                        (a) => a.post('/webhooks/${h.id}/test'),
                                        done: 'Test sent',
                                      );
                                    case 'toggle':
                                      await _call(
                                        context,
                                        ref,
                                        (a) => a.patch(
                                          '/webhooks/${h.id}',
                                          body: {'isActive': !h.isActive},
                                        ),
                                      );
                                    case 'rotate':
                                      try {
                                        final r = await ref
                                            .read(apiClientProvider)
                                            .postJson(
                                              '/webhooks/${h.id}/rotate-secret',
                                            );
                                        if (context.mounted) {
                                          await _showSecret(
                                            context,
                                            title: 'New signing secret',
                                            label: 'Signing secret',
                                            secret: asString(r['secret']),
                                          );
                                        }
                                      } catch (e) {
                                        if (context.mounted) {
                                          showErrorSnackBar(context, e);
                                        }
                                      }
                                    case 'log':
                                      await showModalBottomSheet<void>(
                                        context: context,
                                        isScrollControlled: true,
                                        builder: (_) =>
                                            _DeliveriesSheet(id: h.id),
                                      );
                                    case 'delete':
                                      await _call(
                                        context,
                                        ref,
                                        (a) => a.delete('/webhooks/${h.id}'),
                                      );
                                  }
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'test',
                                    child: Text('Send test'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'log',
                                    child: Text('Deliveries'),
                                  ),
                                  PopupMenuItem(
                                    value: 'toggle',
                                    child: Text(
                                      h.isActive ? 'Pause' : 'Resume',
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'rotate',
                                    child: Text('New secret'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _HookDialog extends StatefulWidget {
  const _HookDialog({required this.events});
  final List<String> events;

  @override
  State<_HookDialog> createState() => _HookDialogState();
}

class _HookDialogState extends State<_HookDialog> {
  final _url = TextEditingController();
  final _desc = TextEditingController();
  final _picked = <String>{};
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _save() {
    if (_url.text.trim().length < 8) {
      setState(() => _error = 'Enter the full https address');
      return;
    }
    if (_picked.isEmpty) {
      setState(() => _error = 'Pick at least one event');
      return;
    }
    Navigator.of(context).pop({
      'url': _url.text.trim(),
      if (_desc.text.trim().isNotEmpty) 'description': _desc.text.trim(),
      'events': _picked.toList(),
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New webhook'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('hook-url'),
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Address (https)'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('hook-desc'),
              controller: _desc,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            const SizedBox(height: 12),
            Text('Events', style: Theme.of(context).textTheme.labelLarge),
            for (final e in widget.events)
              CheckboxListTile(
                key: Key('hook-event-$e'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(e),
                value: _picked.contains(e),
                onChanged: (v) => setState(() {
                  v == true ? _picked.add(e) : _picked.remove(e);
                }),
              ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('hook-save'),
        onPressed: _save,
        child: const Text('Create'),
      ),
    ],
  );
}

class _DeliveriesSheet extends ConsumerWidget {
  const _DeliveriesSheet({required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
    height: MediaQuery.sizeOf(context).height * 0.7,
    child: AsyncValueView(
      value: ref.watch(webhookDeliveriesProvider(id)),
      onRetry: () => ref.invalidate(webhookDeliveriesProvider(id)),
      data: (rows) => rows.isEmpty
          ? const EmptyView(message: 'Nothing sent yet.')
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final d in rows)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${d.event}  ${d.status}'),
                    subtitle: Text(
                      [
                        _stamp(d.createdAt),
                        '${d.attempts} ${d.attempts == 1 ? 'try' : 'tries'}',
                        if (d.responseStatus != null)
                          'HTTP ${d.responseStatus}',
                        if (d.error != null) d.error!,
                      ].join('  |  '),
                    ),
                  ),
              ],
            ),
    ),
  );
}
