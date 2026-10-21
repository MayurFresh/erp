import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/india_states.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../auth/session.dart';
import 'parties_repository.dart';
import 'party_model.dart';

class PartiesScreen extends ConsumerStatefulWidget {
  const PartiesScreen({super.key});

  @override
  ConsumerState<PartiesScreen> createState() => _PartiesScreenState();
}

class _PartiesScreenState extends ConsumerState<PartiesScreen> {
  String _query = '';
  PartyType? _type;
  late final PagedController<Party> _paged = PagedController(
    (offset, limit) => ref
        .read(partiesRepositoryProvider)
        .list(q: _query, type: _type, offset: offset, limit: limit),
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

  @override
  Widget build(BuildContext context) {
    ref.listen(revisionProvider(DataKind.parties), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final perms = ref.watch(permissionsProvider);

    void open(Party party) => context.go('/parties/${party.id}');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Parties',
          subtitle: 'Customers and vendors',
          actions: [
            if (perms.can(Perm.partiesCreate))
              FilledButton.icon(
                onPressed: () => context.go('/parties/new'),
                icon: const Icon(Icons.add),
                label: const Text('New party'),
              ),
          ],
        ),
        FilterBar(
          children: [
            SegmentedButton<PartyType?>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: null, label: Text('All')),
                ButtonSegment(
                  value: PartyType.customer,
                  label: Text('Customers'),
                ),
                ButtonSegment(value: PartyType.vendor, label: Text('Vendors')),
              ],
              selected: {_type},
              onSelectionChanged: (s) {
                setState(() => _type = s.first);
                _paged.refresh();
              },
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: SearchField(
                hintText: 'Search name, GSTIN or phone',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<Party>(
            controller: _paged,
            emptyMessage: 'No parties found.',
            emptyIcon: Icons.people_outline,
            onTap: open,
            tableBreakpoint: 1000,
            columns: [
              TableColumnSpec('Name', (p) => Text(p.name), maxWidth: 220),
              TableColumnSpec('Type', (p) => _TypePill(type: p.type)),
              TableColumnSpec('GSTIN', (p) => Text(p.gstin ?? '—')),
              TableColumnSpec('State', (p) => Text(stateLabel(p.stateCode))),
              TableColumnSpec('Phone', (p) => Text(p.phone ?? '—')),
              TableColumnSpec(
                'Email',
                (p) => Text(p.email ?? '—'),
                maxWidth: 200,
              ),
              TableColumnSpec(
                'Credit limit',
                (p) => Text(formatMoney(p.creditLimit)),
                numeric: true,
              ),
              TableColumnSpec(
                'Balance',
                (p) => _Balance(balance: p.balance),
                numeric: true,
              ),
            ],
            cardBuilder: (context, p) => ListCard(
              onTap: () => open(p),
              title: Text(p.name, overflow: TextOverflow.ellipsis),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [
                      if (p.gstin != null) p.gstin!,
                      if (p.stateCode != null)
                        stateName(p.stateCode) ?? p.stateCode!,
                      if (p.phone != null) p.phone!,
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (p.balance != null && p.balance != 0)
                    _Balance(balance: p.balance),
                ],
              ),
              trailing: _TypePill(type: p.type),
            ),
          ),
        ),
      ],
    );
  }
}

class _TypePill extends StatelessWidget {
  const _TypePill({required this.type});

  final PartyType type;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Pill(
      switch (type) {
        PartyType.customer => 'Customer',
        PartyType.vendor => 'Vendor',
        PartyType.both => 'Both',
      },
      color: switch (type) {
        PartyType.customer => scheme.primary,
        PartyType.vendor => scheme.tertiary,
        PartyType.both => scheme.secondary,
      },
    );
  }
}

/// `Receivable ₹x` / `Payable ₹x` from a debit-positive balance.
class _Balance extends StatelessWidget {
  const _Balance({required this.balance});

  final double? balance;

  @override
  Widget build(BuildContext context) {
    final b = balance;
    if (b == null) return const Text('—');
    if (b.abs() < 0.005) return const Text('Settled');
    final scheme = Theme.of(context).colorScheme;
    return Text(
      '${b > 0 ? 'Receivable' : 'Payable'} ${formatMoney(b.abs())}',
      style: TextStyle(
        color: b > 0 ? scheme.primary : scheme.tertiary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
