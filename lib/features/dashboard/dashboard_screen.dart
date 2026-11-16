import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/business_profile.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../core/design_tokens.dart';
import '../../widgets/kpi_tile.dart';
import '../../widgets/layout.dart';
import '../../widgets/money_text.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../compliance/alerts_card.dart';
import '../compliance/tax_perms.dart';
import '../crm/crm_follow_ups_card.dart';
import '../filings/filing_models.dart';
import '../filings/filings_repository.dart';
import '../filings/needs_you_card.dart';
import '../insights/analytics_models.dart';
import '../insights/analytics_repository.dart';
import '../insights/analytics_widgets.dart';
import '../invoices/invoice_widgets.dart';
import '../reports/report_period.dart';
import '../shell/nav.dart';
import 'dashboard_repository.dart';

/// The owner's morning view: money position, trends, what is due.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  RangePreset _preset = RangePreset.thisMonth;

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(dashboardProvider);
    final session = ref.watch(sessionProvider).value;
    final perms = ref.watch(permissionsProvider);
    final today = DateFormat('EEEE, d MMMM yyyy').format(DateTime.now());
    final company = session?.company?.name;
    final canAnalyse = perms.can(Perm.reportsView);
    final range = _preset.resolve();
    final analytics = canAnalyse ? ref.watch(analyticsProvider(range)) : null;
    return AsyncValueView(
      value: value,
      onRetry: () => ref.invalidate(dashboardProvider),
      data: (d) => RefreshIndicator(
        onRefresh: () async {
          if (canAnalyse) ref.invalidate(analyticsProvider(range));
          ref.invalidate(dashboardProvider);
          await ref.read(dashboardProvider.future);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: Space.xl),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: Layout.contentMaxWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PageHeader(
                      title: 'Dashboard',
                      subtitle: company == null ? today : '$company  ·  $today',
                      actions: _headerActions(context, perms),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.lg),
                      child: LayoutBuilder(
                        builder: (context, box) => _body(
                          context,
                          d,
                          perms,
                          analytics?.value,
                          range,
                          box.maxWidth,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    Dashboard d,
    PermissionSet perms,
    Analytics? a,
    DateRange range,
    double width,
  ) {
    void open(String path) => context.go(path);
    VoidCallback? link(bool ok, String path) => ok ? () => open(path) : null;
    final cols = chartColumns(width);
    final calendar = perms.can(TaxPerm.complianceView)
        ? ref.watch(filingCalendarProvider(contractFy(DateTime.now()))).value
        : null;
    final gst = _gstTile(calendar);
    final tiles = a == null
        ? _legacyTiles(d, perms, gst)
        : [...statTiles(context, a, perms, open), ?gst];
    final tileWidgets = [for (final t in tiles) (1, t)];

    final cards = <(int, Widget)>[];
    if (a != null) {
      cards.add((
        2,
        salesPurchasesCard(
          a,
          onTap: link(perms.can(Perm.invoicesView), '/invoices'),
        ),
      ));
      if (a.cashFlow != null) {
        cards.add((
          1,
          cashCard(a, onTap: link(perms.can(Perm.paymentsView), '/receipts')),
        ));
      }
      cards.add((
        1,
        ageingCard(
          'Receivables ageing',
          a.receivableAgeing,
          onTap: () => open('/reports/receivables-ageing'),
        ),
      ));
      cards.add((
        1,
        rankedCard(
          'Top customers',
          a.topCustomers,
          subtitle: 'Share of sales in this period',
          caption: shareCaption,
          onTap: link(perms.can(Perm.partiesView), '/parties'),
        ),
      ));
      cards.add((
        1,
        rankedCard(
          'Top items',
          a.topItems,
          subtitle: 'By sales value',
          onTap: link(perms.can(Perm.itemsView), '/items'),
        ),
      ));
    } else {
      cards.add((1, _TopItems(dashboard: d)));
    }
    cards.addAll([
      // Only roles that can see returns ask for the filing calendar.
      if (perms.can(TaxPerm.complianceView)) (1, const NeedsYouCard()),
      if (perms.can(Perm.crmView) &&
          ref.watch(businessProfileProvider).hasModule('crm'))
        (1, const CrmFollowUpsCard()),
      (1, const AlertsCard()),
      if (d.lowStockCount > 0)
        (
          1,
          _LowStock(count: d.lowStockCount, canOpen: perms.can(Perm.stockView)),
        ),
      (2, _RecentInvoices(dashboard: d, canOpen: perms.can(Perm.invoicesView))),
    ]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (perms.can(Perm.reportsView)) ...[
          Row(
            children: [
              Expanded(
                child: PeriodChips(
                  value: _preset,
                  onChanged: (p) => setState(() => _preset = p),
                ),
              ),
              TextButton(
                onPressed: () => open('/insights'),
                child: const Text('More detail'),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
        ],
        FlowGrid(
          equalHeight: true,
          columns: tileColumns(width),
          children: tileWidgets,
        ),
        const SizedBox(height: Space.md),
        FlowGrid(columns: cols, children: cards),
      ],
    );
  }

  /// The company's quick actions from its business type, or the usual four
  /// while the catalogue loads or when it has none.
  List<Widget> _headerActions(BuildContext context, PermissionSet perms) {
    final profile = ref.watch(businessProfileProvider);
    final quick = ref
        .watch(quickActionsProvider)
        .where((q) => moduleAllows(q.route, profile))
        .toList();
    if (quick.isNotEmpty) {
      return [
        for (final (i, q) in quick.indexed)
          i == 0
              ? FilledButton.icon(
                  onPressed: () => context.go(q.route),
                  icon: const Icon(Icons.add),
                  label: Text(q.label),
                )
              : OutlinedButton(
                  onPressed: () => context.go(q.route),
                  child: Text(q.label),
                ),
      ];
    }
    return [
      if (perms.can(Perm.invoicesCreate))
        FilledButton.icon(
          onPressed: () => context.go('/invoices/new'),
          icon: const Icon(Icons.add),
          label: Text(context.w('New invoice')),
        ),
      if (perms.can(Perm.paymentsCreate))
        OutlinedButton(
          onPressed: () => context.go('/receipts/new'),
          child: Text(context.w('Record receipt')),
        ),
      if (perms.can(Perm.purchasesCreate))
        OutlinedButton(
          onPressed: () => context.go('/purchases/new'),
          child: Text(context.w('New bill')),
        ),
      if (perms.can(Perm.expensesCreate))
        OutlinedButton(
          onPressed: () => context.go('/expenses/new'),
          child: const Text('New expense'),
        ),
    ];
  }

  Widget? _gstTile(List<FilingCalendarRow>? calendar) {
    if (calendar == null) return null;
    final due = calendar.where((r) => r.needsYou).toList();
    final overdue = due.any((r) => r.status == 'overdue');
    return KpiTile(
      label: 'GST and TDS returns due',
      value: due.isEmpty ? 'None' : '${due.length}',
      hint: due.isEmpty
          ? 'Nothing due this period'
          : '${overdue ? 'Overdue: ' : 'Next: '}'
                '${due.first.label}, ${formatDate(due.first.dueDate)}',
      tone: due.isEmpty
          ? StatusTone.neutral
          : overdue
          ? StatusTone.danger
          : StatusTone.warning,
      onTap: () => context.go('/filings/calendar'),
    );
  }

  /// Tiles from `/dashboard` for roles without `reports.view`.
  List<Widget> _legacyTiles(Dashboard d, PermissionSet perms, Widget? gst) {
    return [
      KpiTile(
        label: 'Sales this month',
        value: _rupees(d.salesThisMonth),
        hint:
            '${_rupees(d.salesToday)} today  ·  '
            '${d.invoicesThisMonth} ${d.invoicesThisMonth == 1 ? 'invoice' : 'invoices'}',
        onTap: perms.can(Perm.invoicesView)
            ? () => context.go('/invoices')
            : null,
      ),
      if (d.receivables != null)
        KpiTile(
          label: 'Receivables',
          value: _rupees(d.receivables),
          hint: 'Owed to you',
          onTap: perms.can(Perm.paymentsView)
              ? () => context.go('/receipts')
              : null,
        ),
      if (d.payables != null)
        KpiTile(
          label: 'Payables',
          value: _rupees(d.payables),
          hint: 'You owe suppliers',
          onTap: perms.can(Perm.paymentsView)
              ? () => context.go('/payments')
              : null,
        ),
      if (d.cashAndBank != null)
        KpiTile(
          label: 'Cash and bank',
          value: _rupees(d.cashAndBank),
          hint: 'Book balance',
        ),
      if (d.purchasesThisMonth != null)
        KpiTile(
          label: 'Purchases this month',
          value: _rupees(d.purchasesThisMonth),
          onTap: perms.can(Perm.purchasesView)
              ? () => context.go('/purchases')
              : null,
        ),
      ?gst,
    ];
  }
}

String _rupees(num? v) => formatMoneySigned(v, decimals: 0);

class _LowStock extends StatelessWidget {
  const _LowStock({required this.count, required this.canOpen});

  final int count;
  final bool canOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Low stock',
      padding: const EdgeInsets.fromLTRB(
        Space.lg,
        Space.lg,
        Space.lg,
        Space.sm,
      ),
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(
          '$count ${count == 1 ? 'item is' : 'items are'} below the reorder level',
        ),
        subtitle: Text(
          'Check stock before the next purchase order.',
          style: theme.textTheme.bodySmall,
        ),
        trailing: canOpen ? const Icon(Icons.chevron_right) : null,
        onTap: canOpen ? () => context.go('/stock?lowOnly=true') : null,
      ),
    );
  }
}

class _RecentInvoices extends StatelessWidget {
  const _RecentInvoices({required this.dashboard, required this.canOpen});

  final Dashboard dashboard;
  final bool canOpen;

  @override
  Widget build(BuildContext context) {
    final invoices = dashboard.recentInvoices;
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Recent invoices',
      trailing: canOpen
          ? TextButton(
              onPressed: () => context.go('/invoices'),
              child: const Text('View all'),
            )
          : null,
      child: invoices.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: Space.lg),
              child: Text(
                'No invoices yet. Create the first one from New invoice.',
              ),
            )
          : Column(
              children: [
                for (final (i, invoice) in invoices.indexed) ...[
                  if (i > 0) const Divider(),
                  InkWell(
                    onTap: invoice.id == null
                        ? null
                        : () => context.go('/invoices/${invoice.id}'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Space.sm),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: Space.sm,
                                  runSpacing: Space.xs,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      invoice.number ?? 'Draft',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    InvoiceStatusPill(status: invoice.status),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${invoice.partyName}  ·  '
                                  '${formatDate(invoice.invoiceDate)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: Space.md),
                          MoneyText(
                            invoice.total,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
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
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Top items this month',
      child: items.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: Space.lg),
              child: Text('No sales this month yet.'),
            )
          : Column(
              children: [
                for (final (i, item) in items.indexed) ...[
                  if (i > 0) const Divider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.sm),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                'Qty ${formatQty(item.qty)}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: Space.md),
                        MoneyText(item.amount),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
