import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/adaptive_data_list.dart' show PagedFooter;
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../reports/report_period.dart';
import '../reports/report_widgets.dart';
import 'accounting_models.dart';
import 'accounting_repository.dart';
import 'journal_widgets.dart';

/// `/journals`: the day book — every journal entry, newest first, each
/// expandable to its lines.
class JournalsScreen extends ConsumerStatefulWidget {
  const JournalsScreen({super.key});

  @override
  ConsumerState<JournalsScreen> createState() => _JournalsScreenState();
}

class _JournalsScreenState extends ConsumerState<JournalsScreen> {
  DateRange _range = DateRange.fyToDate();
  String? _voucherType;
  String _query = '';

  late final PagedController<JournalEntry> _paged = PagedController(
    (offset, limit) => ref
        .read(accountingRepositoryProvider)
        .journals(
          q: _query,
          from: _range.apiFrom,
          to: _range.apiTo,
          voucherType: _voucherType,
          offset: offset,
          limit: limit,
        ),
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

  Future<void> _cancel(JournalEntry entry) async {
    final reversal = await cancelJournal(context, ref, entry);
    if (reversal != null) _paged.refresh();
  }

  @override
  Widget build(BuildContext context) {
    for (final kind in const [
      ...moneyKinds,
      DataKind.accounts,
      DataKind.expenses,
    ]) {
      ref.listen(revisionProvider(kind), (_, _) => _paged.refresh());
    }
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final perms = ref.watch(permissionsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Day book',
          subtitle: 'Every journal entry, newest first',
          actions: [
            if (perms.can(Perm.accountsJournal))
              FilledButton.icon(
                onPressed: () => context.go('/journals/new'),
                icon: const Icon(Icons.add),
                label: const Text('New journal'),
              ),
          ],
        ),
        FilterBar(
          children: [
            PeriodButton(
              value: _range,
              onChanged: (r) {
                setState(() => _range = r);
                _paged.refresh();
              },
            ),
            FilterDropdown<String>(
              label: 'Voucher type',
              value: _voucherType,
              width: 200,
              options: {for (final t in voucherTypes) t: voucherTypeLabel(t)},
              onChanged: (v) {
                setState(() => _voucherType = v);
                _paged.refresh();
              },
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SearchField(
                hintText: 'Search number or narration',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: _paged,
            builder: (context, _) {
              final c = _paged;
              if (c.items.isEmpty) {
                if (c.loading || !c.loaded) return const LoadingView();
                if (c.error != null) {
                  return ErrorView(error: c.error!, onRetry: c.refresh);
                }
                return EmptyView(
                  icon: Icons.menu_book_outlined,
                  message: _query.isEmpty && _voucherType == null
                      ? 'No entries in this period.'
                      : 'No entries match the filters.',
                );
              }
              return RefreshIndicator(
                onRefresh: c.refresh,
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: c.items.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => i == c.items.length
                      ? PagedFooter(controller: c)
                      : JournalEntryCard(
                          key: ValueKey(c.items[i].id),
                          entry: c.items[i],
                          canCancel:
                              c.items[i].canCancel &&
                              perms.can(Perm.accountsJournal),
                          documentRoute: openableDocumentRoute(
                            perms,
                            c.items[i].voucherType,
                            c.items[i].documentRoute,
                          ),
                          onCancel: () => _cancel(c.items[i]),
                        ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A day-book entry: date, number, narration and amount; expands to its
/// lines and actions.
class JournalEntryCard extends StatelessWidget {
  const JournalEntryCard({
    super.key,
    required this.entry,
    required this.canCancel,
    required this.onCancel,
    this.documentRoute,
  });

  final JournalEntry entry;
  final bool canCancel;
  final VoidCallback onCancel;
  final String? documentRoute;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = entry;
    final route = documentRoute;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                e.number ?? e.voucherLabel,
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatMoney(e.totalDebit),
              style: theme.textTheme.titleSmall
                  ?.merge(tabularFigures)
                  .copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                formatDate(e.date),
                if (e.narration != null && e.narration!.isNotEmpty)
                  e.narration!,
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            VoucherPill(e.voucherType, reversal: e.isReversal),
            if (e.isCancelled)
              Pill('Cancelled', color: Theme.of(context).colorScheme.error),
          ],
        ),
        children: [
          const Divider(height: 1),
          const SizedBox(height: 8),
          JournalLinesView(entry: e),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              if (e.createdBy != null)
                Text(
                  'Posted by ${e.createdBy!.name} · '
                  '${formatDateTime(e.createdAt)}',
                  style: theme.textTheme.bodySmall,
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (route != null)
                    OutlinedButton.icon(
                      onPressed: () => context.push(route),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open document'),
                    ),
                  if (canCancel)
                    OutlinedButton.icon(
                      onPressed: onCancel,
                      icon: const Icon(Icons.block),
                      label: const Text('Cancel journal'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
