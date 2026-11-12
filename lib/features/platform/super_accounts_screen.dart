import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import 'super_models.dart';
import 'super_repository.dart';
import 'super_widgets.dart';

const _plans = {
  'solo': 'Solo',
  'team': 'Team',
  'business': 'Business',
  'enterprise': 'Enterprise',
};

/// `/platform/accounts`: every account, searchable and filterable.
class SuperAccountsScreen extends ConsumerStatefulWidget {
  const SuperAccountsScreen({super.key, this.initialStatus});

  final String? initialStatus;

  @override
  ConsumerState<SuperAccountsScreen> createState() =>
      _SuperAccountsScreenState();
}

class _SuperAccountsScreenState extends ConsumerState<SuperAccountsScreen> {
  late final PagedController<SuperTenant> _paged;
  late String? _status = widget.initialStatus;
  String _query = '';
  String? _plan;
  String? _type;

  @override
  void initState() {
    super.initState();
    _paged = PagedController<SuperTenant>(
      (offset, limit) => ref
          .read(superRepositoryProvider)
          .tenants(
            q: _query,
            status: _status,
            plan: _plan,
            businessType: _type,
            offset: offset,
            limit: limit,
          ),
    )..refresh();
  }

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {});
    _paged.refresh();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(superRevisionProvider, (_, _) => _paged.refresh());
    final types =
        ref.watch(superOverviewProvider).value?.byBusinessType ?? const [];
    void open(SuperTenant t) => context.go('/platform/accounts/${t.id}');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(title: 'Accounts'),
        FilterBar(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320, minWidth: 200),
              child: SearchField(
                hintText: 'Search name, owner or email',
                onChanged: (q) {
                  _query = q;
                  _reload();
                },
              ),
            ),
            FilterDropdown<String>(
              key: const Key('filter-status'),
              label: 'Status',
              value: _status,
              width: 150,
              options: const {'active': 'Active', 'suspended': 'Suspended'},
              onChanged: (v) {
                _status = v;
                _reload();
              },
            ),
            FilterDropdown<String>(
              key: const Key('filter-plan'),
              label: 'Plan',
              value: _plan,
              width: 150,
              options: _plans,
              onChanged: (v) {
                _plan = v;
                _reload();
              },
            ),
            FilterDropdown<String>(
              key: const Key('filter-type'),
              label: 'Business type',
              value: _type,
              width: 200,
              options: {for (final c in types) c.key: prettyKey(c.key)},
              onChanged: (v) {
                _type = v;
                _reload();
              },
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<SuperTenant>(
            controller: _paged,
            emptyMessage: 'No accounts match.',
            emptyIcon: Icons.business_outlined,
            tableBreakpoint: 900,
            onTap: open,
            columns: [
              TableColumnSpec('Account', (t) => Text(t.name), maxWidth: 220),
              TableColumnSpec('Status', (t) => TenantStatusChip(t)),
              TableColumnSpec(
                'Business type',
                (t) => Text(prettyKey(t.businessType)),
              ),
              TableColumnSpec('Plan', (t) => Text(prettyKey(t.plan))),
              TableColumnSpec('Country', (t) => Text(t.country ?? '—')),
              TableColumnSpec(
                'Owner',
                (t) => Text(t.ownerEmail ?? '—'),
                maxWidth: 220,
              ),
              TableColumnSpec(
                'Users',
                (t) => Text('${t.activeUsers}/${t.userCount}'),
                numeric: true,
              ),
              TableColumnSpec(
                'Last sign-in',
                (t) => Text(whenText(t.lastSignInAt)),
              ),
              TableColumnSpec('Created', (t) => Text(formatDate(t.createdAt))),
            ],
            cardBuilder: (context, t) => ListCard(
              onTap: () => open(t),
              title: Text(t.name, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [
                  prettyKey(t.businessType),
                  prettyKey(t.plan),
                  if (t.country != null) t.country!,
                  '${t.activeUsers} users',
                  if (t.ownerEmail != null) t.ownerEmail!,
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: TenantStatusChip(t),
            ),
          ),
        ),
      ],
    );
  }
}
