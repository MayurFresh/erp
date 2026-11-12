import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/busy.dart';
import '../../widgets/key_value_list.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../business/business_repository.dart';
import 'super_activity_screen.dart';
import 'super_models.dart';
import 'super_repository.dart';
import 'super_widgets.dart';

final _tenantAuditProvider = FutureProvider.autoDispose
    .family<List<SuperAuditEntry>, String>((ref, tenantId) async {
      ref.watch(superRevisionProvider);
      final all = await ref.watch(superRepositoryProvider).audit(limit: 200);
      return all.where((e) => e.tenantId == tenantId).toList();
    });

/// `/platform/accounts/:id`: one account with its companies, users and activity.
class SuperAccountDetailScreen extends ConsumerWidget {
  const SuperAccountDetailScreen({super.key, required this.tenantId});

  final String tenantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(superTenantProvider(tenantId));
    return AsyncValueView<SuperTenantDetail>(
      value: detail,
      onRetry: () => ref.invalidate(superTenantProvider(tenantId)),
      data: (d) => _Detail(d),
    );
  }
}

class _Detail extends ConsumerWidget {
  const _Detail(this.d);

  final SuperTenantDetail d;

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() task,
    String done,
  ) async {
    try {
      await runBlocking(context, task);
      ref.read(superRevisionProvider.notifier).bump();
      if (context.mounted) showInfoSnackBar(context, done);
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _suspend(BuildContext context, WidgetRef ref) async {
    final reason = await askReason(
      context,
      title: 'Suspend ${d.tenant.name}?',
      message:
          'Nobody in this account can sign in, and open sessions stop working. '
          'Their data is kept.',
      confirmLabel: 'Suspend',
    );
    if (reason == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref.read(superRepositoryProvider).suspend(d.tenant.id, reason),
      'Account suspended',
    );
  }

  Future<void> _reactivate(BuildContext context, WidgetRef ref) async {
    final ok = await confirmAction(
      context,
      title: 'Reactivate ${d.tenant.name}?',
      message: 'Users can sign in again.',
      confirmLabel: 'Reactivate',
    );
    if (!ok || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref.read(superRepositoryProvider).reactivate(d.tenant.id),
      'Account reactivated',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = d.tenant;
    final gutter = pageGutter(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xl),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageHeader(
                title: t.name,
                subtitle: 'Created ${formatDate(t.createdAt)}',
                actions: [
                  TenantStatusChip(t),
                  if (t.suspended)
                    FilledButton(
                      key: const Key('reactivate-tenant'),
                      onPressed: () => _reactivate(context, ref),
                      child: const Text('Reactivate'),
                    )
                  else if (!t.hasPlatformAdmin)
                    OutlinedButton(
                      key: const Key('suspend-tenant'),
                      onPressed: () => _suspend(context, ref),
                      child: const Text('Suspend'),
                    ),
                ],
              ),
              if (t.suspended)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.md),
                  child: Text(
                    'Suspended ${whenText(t.suspendedAt)}: ${t.suspendedReason ?? ''}',
                    key: const Key('suspended-note'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              SectionCard(
                title: 'Account',
                child: KeyValueList(
                  items: [
                    KeyValue('Owner', t.ownerName ?? ''),
                    KeyValue('Owner email', t.ownerEmail ?? ''),
                    KeyValue(
                      'Users',
                      '${t.activeUsers} active of ${t.userCount}',
                    ),
                    KeyValue('Last sign-in', whenText(t.lastSignInAt)),
                  ],
                ),
              ),
              for (final c in d.companies) _CompanyCard(c),
              SectionCard(
                title: 'Users',
                child: Column(
                  children: [for (final u in d.users) _UserRow(u, d.companies)],
                ),
              ),
              SectionCard(title: 'Activity', child: _TenantActivity(t.id)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompanyCard extends ConsumerWidget {
  const _CompanyCard(this.c);

  final SuperCompany c;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
    title: c.name,
    icon: Icons.business_outlined,
    trailing: TextButton(
      key: Key('edit-company-${c.id}'),
      onPressed: () async {
        final changed = await showDialog<bool>(
          context: context,
          builder: (_) => _CompanyDialog(c),
        );
        if (changed == true) ref.read(superRevisionProvider.notifier).bump();
      },
      child: const Text('Change plan or type'),
    ),
    child: KeyValueList(
      items: [
        KeyValue('Business type', prettyKey(c.businessType)),
        KeyValue('Plan', prettyKey(c.plan)),
        KeyValue('Country', c.country),
        KeyValue(
          'Modules',
          c.enabledModules == null
              ? 'Defaults'
              : c.enabledModules!.map(prettyKey).join(', '),
        ),
        KeyValue(
          'Records',
          '${c.invoices} invoices, ${c.parties} parties, ${c.items} items',
        ),
        KeyValue('Created', formatDate(c.createdAt)),
      ],
    ),
  );
}

class _CompanyDialog extends ConsumerStatefulWidget {
  const _CompanyDialog(this.company);

  final SuperCompany company;

  @override
  ConsumerState<_CompanyDialog> createState() => _CompanyDialogState();
}

class _CompanyDialogState extends ConsumerState<_CompanyDialog> {
  late String _plan = widget.company.plan;
  late String _type = widget.company.businessType;
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(superRepositoryProvider)
          .updateCompany(
            widget.company.id,
            plan: _plan == widget.company.plan ? null : _plan,
            businessType: _type == widget.company.businessType ? null : _type,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = ref.watch(businessCatalogueProvider).value?.types ?? const [];
    final typeItems = {
      for (final t in types) t.id: t.name,
      _type: prettyKey(_type),
    };
    const plans = ['solo', 'team', 'business', 'enterprise'];
    final unchanged =
        _plan == widget.company.plan && _type == widget.company.businessType;
    return AlertDialog(
      title: Text(widget.company.name),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              key: const Key('company-plan'),
              initialValue: _plan,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Plan'),
              items: [
                for (final p in plans)
                  DropdownMenuItem(value: p, child: Text(prettyKey(p))),
              ],
              onChanged: (v) => setState(() => _plan = v ?? _plan),
            ),
            const SizedBox(height: Space.md),
            DropdownButtonFormField<String>(
              key: const Key('company-type'),
              initialValue: _type,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Business type'),
              items: [
                for (final e in typeItems.entries)
                  DropdownMenuItem(
                    value: e.key,
                    child: Text(e.value, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            const SizedBox(height: Space.sm),
            Text(
              'Modules are re-checked against the plan. A new business type '
              'resets modules to its defaults and adds its roles.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('company-save'),
          onPressed: _busy || unchanged ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _UserRow extends ConsumerWidget {
  const _UserRow(this.u, this.companies);

  final SuperUser u;
  final List<SuperCompany> companies;

  String _companyName(String id) {
    for (final c in companies) {
      if (c.id == id) return c.name;
    }
    return '';
  }

  Future<void> _act(BuildContext context, WidgetRef ref, String action) async {
    final repo = ref.read(superRepositoryProvider);
    final (title, message, label, danger) = switch (action) {
      'deactivate' => (
        'Deactivate ${u.name}?',
        'They are signed out and cannot sign in until activated again.',
        'Deactivate',
        true,
      ),
      'activate' => (
        'Activate ${u.name}?',
        'They can sign in again.',
        'Activate',
        false,
      ),
      'unlock' => (
        'Unlock ${u.name}?',
        'Clears the lock from too many failed attempts.',
        'Unlock',
        false,
      ),
      'sign-out' => (
        'Sign ${u.name} out everywhere?',
        'Every open session ends. They sign in again with their password.',
        'Sign out',
        true,
      ),
      _ => (
        'Create a reset link for ${u.name}?',
        'Any earlier link stops working. You share the new link yourself.',
        'Create link',
        false,
      ),
    };
    final ok = await confirmAction(
      context,
      title: title,
      message: message,
      confirmLabel: label,
      danger: danger,
    );
    if (!ok || !context.mounted) return;
    try {
      if (action == 'reset-link') {
        final link = await runBlocking(context, () => repo.resetLink(u.id));
        ref.read(superRevisionProvider.notifier).bump();
        if (link != null && context.mounted) {
          await showResetLink(context, u, link);
        }
        return;
      }
      await runBlocking(context, () => repo.userAction(u.id, action));
      ref.read(superRevisionProvider.notifier).bump();
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final roles = u.roles
        .map((r) {
          final company = _companyName(r.$1);
          return companies.length > 1 ? '${r.$2} at $company' : r.$2;
        })
        .join(', ');
    return ListTile(
      key: Key('user-${u.id}'),
      contentPadding: EdgeInsets.zero,
      title: Text(
        u.name,
        overflow: TextOverflow.ellipsis,
        style: u.isActive
            ? null
            : TextStyle(color: theme.colorScheme.onSurfaceVariant),
      ),
      subtitle: Text(
        [
          u.email,
          if (roles.isNotEmpty) roles,
          if (!u.isActive) 'Deactivated',
          if (u.isLocked) 'Locked',
          if (u.twoFactor) '2FA on',
          if (u.isPlatformAdmin) 'Platform admin',
          'Last sign-in ${whenText(u.lastSignInAt)}',
        ].join(' · '),
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
        key: Key('user-menu-${u.id}'),
        tooltip: 'Actions for ${u.name}',
        onSelected: (a) => _act(context, ref, a),
        itemBuilder: (_) => [
          if (!u.isPlatformAdmin && u.isActive)
            const PopupMenuItem(value: 'reset-link', child: Text('Reset link')),
          if (u.isLocked)
            const PopupMenuItem(value: 'unlock', child: Text('Unlock')),
          const PopupMenuItem(
            value: 'sign-out',
            child: Text('Sign out everywhere'),
          ),
          if (!u.isPlatformAdmin && u.isActive)
            const PopupMenuItem(value: 'deactivate', child: Text('Deactivate')),
          if (!u.isActive)
            const PopupMenuItem(value: 'activate', child: Text('Activate')),
        ],
      ),
    );
  }
}

class _TenantActivity extends ConsumerWidget {
  const _TenantActivity(this.tenantId);

  final String tenantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(_tenantAuditProvider(tenantId));
    return entries.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(Space.md),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Text(errorMessage(e)),
      data: (list) => list.isEmpty
          ? const Text('No platform changes for this account.')
          : Column(children: [for (final e in list) AuditTile(e)]),
    );
  }
}
