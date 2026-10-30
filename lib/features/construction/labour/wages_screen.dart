import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../widgets/adaptive_data_list.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/paged_controller.dart';
import '../../../widgets/search_field.dart';
import '../../auth/session.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../models/labour_models.dart';

/// Wage sheets for all sites.
class WagesScreen extends ConsumerStatefulWidget {
  const WagesScreen({super.key});

  @override
  ConsumerState<WagesScreen> createState() => _WagesScreenState();
}

class _WagesScreenState extends ConsumerState<WagesScreen> {
  String? _siteId;
  WageSheetStatus? _status;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    return CGate(
      anyOf: const [CPerm.wagesView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Wage sheets',
            actions: [
              if (perms.can(CPerm.wagesManage))
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/wage-sheets/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New wage sheet'),
                ),
            ],
          ),
          FilterBar(
            children: [
              StatusChips<WageSheetStatus>(
                value: _status,
                options: {
                  for (final status in WageSheetStatus.values)
                    status: status.label,
                },
                onChanged: (value) => setState(() => _status = value),
              ),
              SiteFilter(
                value: _siteId,
                onChanged: (value) => setState(() => _siteId = value),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300),
                child: SearchField(
                  hintText: 'Search number',
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
            ],
          ),
          Expanded(
            child: WageSheetList(
              siteId: _siteId,
              status: _status,
              query: _query,
            ),
          ),
        ],
      ),
    );
  }
}

/// Paged wage sheets for the selected filters.
class WageSheetList extends ConsumerStatefulWidget {
  const WageSheetList({super.key, this.siteId, this.status, this.query = ''});

  final String? siteId;
  final WageSheetStatus? status;
  final String query;

  @override
  ConsumerState<WageSheetList> createState() => _WageSheetListState();
}

class _WageSheetListState extends ConsumerState<WageSheetList> {
  late final PagedController<WageSheet> _paged = PagedController(
    (offset, limit) => ref
        .read(constructionRepositoryProvider)
        .wageSheets(
          q: widget.query,
          siteId: widget.siteId,
          status: widget.status,
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
  void didUpdateWidget(WageSheetList old) {
    super.didUpdateWidget(old);
    if (old.siteId != widget.siteId ||
        old.status != widget.status ||
        old.query != widget.query) {
      _paged.refresh();
    }
  }

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(cRevisionProvider(CKind.wages), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());

    void open(WageSheet sheet) => context.go('/wage-sheets/${sheet.id}');
    return AdaptiveDataList<WageSheet>(
      controller: _paged,
      emptyMessage: 'No wage sheets found.',
      emptyIcon: Icons.payments_outlined,
      onTap: open,
      columns: [
        TableColumnSpec('Number', (sheet) => Text(sheet.number)),
        TableColumnSpec('Site', (sheet) => Text(sheet.siteName), maxWidth: 200),
        TableColumnSpec(
          'Period',
          (sheet) =>
              Text('${formatDate(sheet.from)} – ${formatDate(sheet.to)}'),
        ),
        TableColumnSpec(
          'Gross',
          (sheet) => Text(formatMoney(sheet.totalGross)),
          numeric: true,
        ),
        TableColumnSpec(
          'Advances',
          (sheet) => Text(formatMoney(sheet.totalDeductions)),
          numeric: true,
        ),
        TableColumnSpec(
          'Net',
          (sheet) => Text(
            formatMoney(sheet.totalNet),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          numeric: true,
        ),
        TableColumnSpec(
          'Status',
          (sheet) => wageStatusPill(context, sheet.status),
        ),
      ],
      cardBuilder: (context, sheet) => CListCard(
        onTap: () => open(sheet),
        title: sheet.number,
        subtitle: sheet.siteName,
        trailing: formatMoney(sheet.totalNet),
        details: [
          '${formatDate(sheet.from)} – ${formatDate(sheet.to)}',
          'Gross ${formatMoney(sheet.totalGross)} · '
              'advances ${formatMoney(sheet.totalDeductions)}',
        ],
        pills: wageStatusPill(context, sheet.status),
      ),
    );
  }
}
