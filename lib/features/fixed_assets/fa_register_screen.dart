import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/json.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../auth/session.dart';
import '../compliance/tax_perms.dart';
import '../reports/report_widgets.dart' show StatRow, StatTile, tabularFigures;
import 'fa_depreciation_tab.dart';
import 'fa_it_schedule_tab.dart';
import 'fa_models.dart';
import 'fa_repository.dart';

/// `/fixed-assets`: the register, depreciation runs and the IT schedule.
class FixedAssetsScreen extends ConsumerWidget {
  const FixedAssetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = ref.watch(permissionsProvider).can(TaxPerm.assetsManage);
    return DefaultTabController(
      length: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Fixed assets',
            subtitle: 'Register, depreciation and the income-tax schedule',
            actions: [
              if (manage)
                FilledButton.icon(
                  onPressed: () => context.go('/fixed-assets/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add asset'),
                ),
            ],
          ),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Register'),
              Tab(text: 'Depreciation'),
              Tab(text: 'IT schedule'),
            ],
          ),
          const Expanded(
            child: TabBarView(
              children: [
                AssetRegisterTab(),
                DepreciationTab(),
                ItScheduleTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AssetRegisterTab extends ConsumerStatefulWidget {
  const AssetRegisterTab({super.key});

  @override
  ConsumerState<AssetRegisterTab> createState() => _AssetRegisterTabState();
}

class _AssetRegisterTabState extends ConsumerState<AssetRegisterTab> {
  late final PagedController<FixedAsset> _c;
  String? _status = 'active';
  String? _block;
  String _q = '';
  AssetTotals _totals = const AssetTotals();

  @override
  void initState() {
    super.initState();
    _c = PagedController<FixedAsset>((offset, limit) async {
      final page = await ref
          .read(fixedAssetRepositoryProvider)
          .list(
            status: _status,
            blockCode: _block,
            q: _q,
            offset: offset,
            limit: limit,
          );
      _totals = page.totals;
      return Paged(page.data, page.total);
    })..refresh();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(faRevisionProvider, (_, _) => _c.refresh());
    final blocks = ref.watch(itBlocksProvider).value ?? const <ItBlock>[];
    return Column(
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.4,
          ),
          child: SingleChildScrollView(
            child: Column(
              children: [
                FilterBar(
                  children: [
                    SizedBox(
                      width: 220,
                      child: SearchField(
                        hintText: 'Search assets',
                        onChanged: (v) {
                          _q = v;
                          _c.refresh();
                        },
                      ),
                    ),
                    FilterDropdown<String>(
                      label: 'Status',
                      value: _status,
                      options: const {
                        'active': 'Active',
                        'disposed': 'Disposed',
                      },
                      anyLabel: 'All',
                      width: 150,
                      onChanged: (v) {
                        _status = v;
                        _c.refresh();
                      },
                    ),
                    FilterDropdown<String>(
                      label: 'IT block',
                      value: _block,
                      options: {for (final b in blocks) b.code: b.name},
                      anyLabel: 'All blocks',
                      width: 200,
                      onChanged: (v) {
                        _block = v;
                        _c.refresh();
                      },
                    ),
                  ],
                ),
                ListenableBuilder(
                  listenable: _c,
                  builder: (context, _) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: StatRow(
                      children: [
                        StatTile(
                          label: 'Cost',
                          value: formatMoney(_totals.cost),
                        ),
                        StatTile(
                          label: 'Accumulated depreciation',
                          value: formatMoney(_totals.accumulatedDep),
                        ),
                        StatTile(
                          label: 'Book value',
                          value: formatMoney(_totals.bookValue),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: AdaptiveDataList<FixedAsset>(
            controller: _c,
            emptyMessage: 'No assets match.',
            emptyIcon: Icons.business_center_outlined,
            onTap: (a) => context.go('/fixed-assets/${a.id}'),
            columns: [
              TableColumnSpec('Number', (a) => Text(a.number)),
              TableColumnSpec('Name', (a) => Text(a.name), maxWidth: 240),
              TableColumnSpec('Block', (a) => Text(a.blockName), maxWidth: 200),
              TableColumnSpec(
                'Put to use',
                (a) => Text(formatDate(a.putToUseDate)),
              ),
              TableColumnSpec(
                'Cost',
                (a) => Text(formatAmount(a.cost), style: tabularFigures),
                numeric: true,
              ),
              TableColumnSpec(
                'Acc. dep.',
                (a) =>
                    Text(formatAmount(a.accumulatedDep), style: tabularFigures),
                numeric: true,
              ),
              TableColumnSpec(
                'Book value',
                (a) => Text(formatAmount(a.bookValue), style: tabularFigures),
                numeric: true,
              ),
              TableColumnSpec(
                'Status',
                (a) => Pill(
                  a.disposed ? 'Disposed' : 'Active',
                  color: a.disposed
                      ? Colors.grey.shade700
                      : Colors.green.shade700,
                ),
              ),
            ],
            cardBuilder: (context, a) => ListCard(
              onTap: () => context.go('/fixed-assets/${a.id}'),
              title: Text(a.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${a.number} · ${a.blockName}${a.disposed ? ' · Disposed' : ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(formatMoney(a.bookValue), style: tabularFigures),
                  Text(
                    'of ${formatMoney(a.cost)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
