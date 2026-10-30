import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../filings/needs_you_card.dart';
import '../compliance/alerts_card.dart';
import '../invoices/invoice_widgets.dart';
import 'dashboard_repository.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(dashboardProvider);
    final session = ref.watch(sessionProvider).value;
    final perms = ref.watch(permissionsProvider);
    return AsyncValueView(
      value: value,
      onRetry: () => ref.invalidate(dashboardProvider),
      data: (d) => RefreshIndicator(
        onRefresh: () => ref.refresh(dashboardProvider.future),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            PageHeader(
              title: 'Dashboard',
              subtitle: session?.company?.name,
              actions: [
                if (perms.can(Perm.invoicesCreate))
                  FilledButton.icon(
                    onPressed: () => context.go('/invoices/new'),
                    icon: const Icon(Icons.add),
                    label: const Text('New invoice'),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _KpiGrid(
                cards: [
                  _Kpi(
                    'Sales today',
                    formatMoney(d.salesToday),
                    Icons.today_outlined,
                  ),
                  _Kpi(
                    'Sales this month',
                    formatMoney(d.salesThisMonth),
                    Icons.calendar_month_outlined,
                  ),
                  _Kpi(
                    'Invoices this month',
                    '${d.invoicesThisMonth}',
                    Icons.receipt_long_outlined,
                    onTap: perms.can(Perm.invoicesView)
                        ? () => context.go('/invoices')
                        : null,
                  ),
                  _Kpi(
                    'Low-stock items',
                    '${d.lowStockCount}',
                    Icons.warning_amber_outlined,
                    highlight: d.lowStockCount > 0,
                    onTap: perms.can(Perm.stockView)
                        ? () => context.go('/stock?lowOnly=true')
                        : null,
                  ),
                  // v1.1 figures appear only when the server sends them.
                  if (d.receivables != null)
                    _Kpi(
                      'Receivables',
                      formatMoney(d.receivables),
                      Icons.call_received,
                      onTap: perms.can(Perm.paymentsView)
                          ? () => context.go('/receipts')
                          : null,
                    ),
                  if (d.payables != null)
                    _Kpi(
                      'Payables',
                      formatMoney(d.payables),
                      Icons.call_made,
                      onTap: perms.can(Perm.paymentsView)
                          ? () => context.go('/payments')
                          : null,
                    ),
                  if (d.cashAndBank != null)
                    _Kpi(
                      'Cash & bank',
                      formatMoney(d.cashAndBank),
                      Icons.account_balance_outlined,
                    ),
                  if (d.purchasesThisMonth != null)
                    _Kpi(
                      'Purchases this month',
                      formatMoney(d.purchasesThisMonth),
                      Icons.shopping_cart_outlined,
                      onTap: perms.can(Perm.purchasesView)
                          ? () => context.go('/purchases')
                          : null,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Column(children: [NeedsYouCard(), AlertsCard()]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FormRow(
                breakpoint: 900,
                children: [
                  _RecentInvoices(dashboard: d),
                  _TopItems(dashboard: d),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Kpi {
  const _Kpi(
    this.label,
    this.value,
    this.icon, {
    this.onTap,
    this.highlight = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final VoidCallback? onTap;
  final bool highlight;
}

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.cards});

  final List<_Kpi> cards;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 1000 ? 4 : (width >= 340 ? 2 : 1);
        const gap = 12.0;
        final cardWidth = (width - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final kpi in cards)
              SizedBox(
                width: cardWidth,
                child: _KpiCard(kpi: kpi),
              ),
          ],
        );
      },
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.kpi});

  final _Kpi kpi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = kpi.highlight
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: kpi.onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(kpi.icon, size: 20, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      kpi.label,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  kpi.value,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: kpi.highlight ? color : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentInvoices extends StatelessWidget {
  const _RecentInvoices({required this.dashboard});

  final Dashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final invoices = dashboard.recentInvoices;
    return SectionCard(
      title: 'Recent invoices',
      child: invoices.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No invoices yet.'),
            )
          : Column(
              children: [
                for (final invoice in invoices)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            invoice.number ?? 'Draft',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        InvoiceStatusPill(status: invoice.status),
                      ],
                    ),
                    subtitle: Text(
                      '${invoice.partyName} · ${formatDate(invoice.invoiceDate)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(formatMoney(invoice.total)),
                    onTap: invoice.id == null
                        ? null
                        : () => context.go('/invoices/${invoice.id}'),
                  ),
              ],
            ),
    );
  }
}

class _TopItems extends StatelessWidget {
  const _TopItems({required this.dashboard});

  final Dashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final items = dashboard.topItems;
    return SectionCard(
      title: 'Top items this month',
      child: items.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No sales this month yet.'),
            )
          : Column(
              children: [
                for (final (index, item) in items.indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 14,
                      child: Text('${index + 1}'),
                    ),
                    title: Text(item.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text('Qty ${formatQty(item.qty)}'),
                    trailing: Text(formatMoney(item.amount)),
                  ),
              ],
            ),
    );
  }
}
