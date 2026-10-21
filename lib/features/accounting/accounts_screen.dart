import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../reports/report_widgets.dart' show tabularFigures;
import 'account_dialog.dart';
import 'accounting_models.dart';
import 'accounting_repository.dart';

/// `/accounts`: the chart of accounts grouped by type, with today's
/// balances shown as Dr / Cr.
class AccountsScreen extends ConsumerStatefulWidget {
  const AccountsScreen({super.key});

  @override
  ConsumerState<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends ConsumerState<AccountsScreen> {
  String _query = '';
  String? _type;
  bool _showInactive = false;

  Future<void> _create() async {
    final account = await showAccountDialog(context);
    if (account != null && mounted) {
      showInfoSnackBar(context, 'Created ${account.code} · ${account.name}');
    }
  }

  Future<void> _edit(Account account) async {
    final saved = await showAccountDialog(context, account: account);
    if (saved != null && mounted) {
      showInfoSnackBar(context, 'Saved ${saved.code} · ${saved.name}');
    }
  }

  Future<void> _setActive(Account account, bool active) async {
    if (!active) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          insetPadding: dialogInset(context),
          title: Text('Deactivate ${account.name}?'),
          content: const Text(
            'Its history and balance stay in the books, but it will not be '
            'offered for new entries. You can activate it again later.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep active'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Deactivate'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    try {
      await ref
          .read(accountingRepositoryProvider)
          .update(account, isActive: active);
      ref.bump(const [DataKind.accounts]);
      if (mounted) {
        showInfoSnackBar(
          context,
          '${account.name} ${active ? 'activated' : 'deactivated'}',
        );
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final canManage = perms.can(Perm.accountsManage);
    final chart = ref.watch(chartOfAccountsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Chart of accounts',
          subtitle: 'Balances as of today',
          actions: [
            if (canManage)
              FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add),
                label: const Text('New account'),
              ),
          ],
        ),
        FilterBar(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SearchField(
                hintText: 'Search code or name',
                debounce: const Duration(milliseconds: 150),
                onChanged: (q) => setState(() => _query = q),
              ),
            ),
            FilterDropdown<String>(
              label: 'Type',
              value: _type,
              width: 180,
              options: {for (final t in accountTypes) t: accountGroupLabel(t)},
              onChanged: (v) => setState(() => _type = v),
            ),
            FilterChip(
              label: const Text('Show inactive'),
              selected: _showInactive,
              onSelected: (v) => setState(() => _showInactive = v),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView(
            value: chart,
            onRetry: () => ref.invalidate(chartOfAccountsProvider),
            data: (accounts) {
              final visible = accounts.where(
                (a) =>
                    (_showInactive || a.isActive) &&
                    (_type == null || a.type == _type) &&
                    accountMatches(a, _query),
              );
              final groups = groupAccounts(visible);
              if (groups.isEmpty) {
                return EmptyView(
                  icon: Icons.account_tree_outlined,
                  message: accounts.isEmpty
                      ? 'No accounts yet.'
                      : 'No accounts match the filters.',
                );
              }
              return RefreshIndicator(
                onRefresh: () async => ref.invalidate(chartOfAccountsProvider),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: [
                    for (final group in groups)
                      _AccountGroupCard(
                        group: group,
                        canManage: canManage,
                        onOpen: (a) => context.go('/accounts/${a.id}'),
                        onEdit: _edit,
                        onSetActive: _setActive,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AccountGroupCard extends StatelessWidget {
  const _AccountGroupCard({
    required this.group,
    required this.canManage,
    required this.onOpen,
    required this.onEdit,
    required this.onSetActive,
  });

  final AccountGroup group;
  final bool canManage;
  final ValueChanged<Account> onOpen;
  final ValueChanged<Account> onEdit;
  final void Function(Account, bool) onSetActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = group.accounts.length;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      text: group.label,
                      style: theme.textTheme.titleMedium,
                      children: [
                        TextSpan(
                          text: '  $count ${count == 1 ? 'account' : 'accounts'}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  drCr(group.total, formatMoney),
                  style: theme.textTheme.titleSmall
                      ?.merge(tabularFigures)
                      .copyWith(fontWeight: FontWeight.w700),
                ),
                // Lines up with the balances above the row menus.
                if (canManage) const SizedBox(width: 32),
              ],
            ),
          ),
          const Divider(height: 1),
          for (final (i, account) in group.accounts.indexed) ...[
            if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            _AccountRow(
              account: account,
              canManage: canManage,
              onOpen: () => onOpen(account),
              onEdit: () => onEdit(account),
              onSetActive: (v) => onSetActive(account, v),
            ),
          ],
        ],
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    required this.canManage,
    required this.onOpen,
    required this.onEdit,
    required this.onSetActive,
  });

  final Account account;
  final bool canManage;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final ValueChanged<bool> onSetActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = account;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final pills = [
      if (a.subtype != 'other') Pill(accountSubtypeLabel(a.subtype)),
      if (a.isSystem) Pill('System', color: theme.colorScheme.tertiary),
      if (!a.isActive) Pill('Inactive', color: theme.colorScheme.outline),
    ];
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 8, canManage ? 0 : 16, 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 560;
            final name = Text(
              a.name,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: a.isActive ? null : theme.colorScheme.outline,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            );
            final balance = Text(
              drCr(a.balance, formatMoney),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium?.merge(tabularFigures).copyWith(
                fontWeight: FontWeight.w600,
              ),
            );
            return Row(
              children: [
                if (wide) SizedBox(width: 64, child: Text(a.code, style: muted)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (wide)
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [name, ...pills],
                        )
                      else ...[
                        name,
                        const SizedBox(height: 2),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [Text(a.code, style: muted), ...pills],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                balance,
                if (canManage)
                  PopupMenuButton<String>(
                    tooltip: 'Account actions',
                    onSelected: (v) => switch (v) {
                      'ledger' => onOpen(),
                      'edit' => onEdit(),
                      'deactivate' => onSetActive(false),
                      'activate' => onSetActive(true),
                      _ => null,
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'ledger',
                        child: Text('Open ledger'),
                      ),
                      PopupMenuItem(
                        value: 'edit',
                        child: Text(a.isSystem ? 'Rename' : 'Edit'),
                      ),
                      if (!a.isSystem)
                        PopupMenuItem(
                          value: a.isActive ? 'deactivate' : 'activate',
                          child: Text(a.isActive ? 'Deactivate' : 'Activate'),
                        ),
                    ],
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
