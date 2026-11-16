import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../reports/report_widgets.dart';
import '../reports/reports_hub_screen.dart' show LocationFilter;
import 'stock_tools_models.dart';
import 'stock_tools_repository.dart';

/// Per-bucket quantity (and value when the user may see cost) of stock by receipt age.
class StockAgeingScreen extends ConsumerStatefulWidget {
  const StockAgeingScreen({super.key});

  @override
  ConsumerState<StockAgeingScreen> createState() => _AgeingState();
}

class _AgeingState extends ConsumerState<StockAgeingScreen> {
  String? _locationId;

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(stockAgeingProvider(_locationId));
    return ReportPage(
      title: 'Stock ageing',
      subtitle: 'Stock still on hand, by how long ago it was received',
      controls: [
        LocationFilter(
          value: _locationId,
          onChanged: (v) => setState(() => _locationId = v),
        ),
      ],
      body: ReportBody<AgeingReport>(
        value: value,
        onRetry: () => ref.invalidate(stockAgeingProvider(_locationId)),
        isEmpty: (v) => v.rows.isEmpty,
        emptyMessage: 'No stock on hand.',
        emptyIcon: Icons.inventory_2_outlined,
        builder: (v) {
          final hasValue = v.totalValue != null;
          String cell(AgeingCell c) => hasValue
              ? '${formatQty(c.qty)} / ${formatMoney(c.value)}'
              : formatQty(c.qty);
          return [
            StatRow(
              children: [
                StatTile(label: 'Quantity', value: formatQty(v.totalQty)),
                if (hasValue)
                  StatTile(label: 'Value', value: formatMoney(v.totalValue)),
              ],
            ),
            ReportTable<AgeingRow>(
              rows: v.rows,
              columns: [
                ReportColumn('Item', (r) => r.name, flex: true, maxWidth: 260),
                ReportColumn('Location', (r) => r.locationName),
                for (var i = 0; i < v.bucketLabels.length; i++)
                  ReportColumn(
                    '${v.bucketLabels[i]} days',
                    (r) => cell(r.buckets[i]),
                    numeric: true,
                  ),
                ReportColumn(
                  'Total',
                  (r) => hasValue
                      ? '${formatQty(r.qty)} / ${formatMoney(r.value)}'
                      : formatQty(r.qty),
                  numeric: true,
                ),
              ],
            ),
          ];
        },
      ),
    );
  }
}

/// Items that have not sold for N days, or sell slowly for the stock held.
class SlowMovingScreen extends ConsumerStatefulWidget {
  const SlowMovingScreen({super.key});

  @override
  ConsumerState<SlowMovingScreen> createState() => _SlowState();
}

class _SlowState extends ConsumerState<SlowMovingScreen> {
  String _mode = 'non_moving';
  int _days = 90;
  String? _locationId;

  MovementKey get _key => (
    mode: _mode,
    days: _days,
    coverDays: 180,
    locationId: _locationId,
  );

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(stockMovementProvider(_key));
    final nonMoving = _mode == 'non_moving';
    return ReportPage(
      title: nonMoving ? 'Non-moving stock' : 'Slow-moving stock',
      subtitle: nonMoving
          ? 'In stock, with no sale in the last $_days days'
          : 'Sold in the last $_days days, but stock covers over 180 days',
      controls: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'non_moving', label: Text('Non-moving')),
            ButtonSegment(value: 'slow_moving', label: Text('Slow-moving')),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        DropdownButton<int>(
          value: _days,
          items: const [
            DropdownMenuItem(value: 30, child: Text('30 days')),
            DropdownMenuItem(value: 60, child: Text('60 days')),
            DropdownMenuItem(value: 90, child: Text('90 days')),
            DropdownMenuItem(value: 180, child: Text('180 days')),
            DropdownMenuItem(value: 365, child: Text('365 days')),
          ],
          onChanged: (v) => setState(() => _days = v ?? 90),
        ),
        LocationFilter(
          value: _locationId,
          onChanged: (v) => setState(() => _locationId = v),
        ),
      ],
      body: ReportBody<List<MovementRow>>(
        value: value,
        onRetry: () => ref.invalidate(stockMovementProvider(_key)),
        isEmpty: (v) => v.isEmpty,
        emptyMessage: 'No items match.',
        emptyIcon: Icons.inventory_2_outlined,
        builder: (rows) => [
          ReportTable<MovementRow>(
            rows: rows,
            columns: [
              ReportColumn('Item', (r) => r.name, flex: true, maxWidth: 260),
              ReportColumn('In stock', (r) => '${formatQty(r.qty)} ${r.unit}', numeric: true),
              if (rows.any((r) => r.value != null))
                ReportColumn('Value', (r) => formatMoney(r.value), numeric: true),
              ReportColumn('Last sale', (r) => r.lastSaleDate ?? 'Never'),
              ReportColumn(
                'Days',
                (r) => r.daysSinceSale == null ? '' : '${r.daysSinceSale}',
                numeric: true,
              ),
              if (!nonMoving)
                ReportColumn(
                  'Cover (days)',
                  (r) => r.coverDays == null ? '' : '${r.coverDays}',
                  numeric: true,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Choose weighted average or FIFO and see both values side by side.
class ValuationMethodScreen extends ConsumerStatefulWidget {
  const ValuationMethodScreen({super.key});

  @override
  ConsumerState<ValuationMethodScreen> createState() => _MethodState();
}

class _MethodState extends ConsumerState<ValuationMethodScreen> {
  String? _method;
  DateTime? _date;
  bool _busy = false;
  String? _error;

  Future<void> _save(ValuationSetting current) async {
    final method = _method ?? current.method;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final d = _date ?? DateTime.now();
      final iso =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      await ref.read(stockToolsRepositoryProvider).saveSetting(method, effectiveFrom: iso);
      ref.invalidate(valuationSettingProvider);
      ref.invalidate(valuationTotalProvider('average'));
      ref.invalidate(valuationTotalProvider('fifo'));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Valuation method saved.')),
        );
      }
    } on ApiException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final can = ref.watch(permissionsProvider).can(Perm.stockValuation);
    final setting = ref.watch(valuationSettingProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Stock valuation method',
          subtitle: 'How the cost of goods sold and closing stock are worked out',
        ),
        Expanded(
          child: setting.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorView(
              error: e,
              onRetry: () => ref.invalidate(valuationSettingProvider),
            ),
            data: (s) {
              final method = _method ?? s.method;
              return ListView(
                padding: EdgeInsets.all(pageGutter(context)),
                children: [
                  Text(
                    s.isFifo
                        ? 'Now: FIFO${s.effectiveFrom == null ? '' : ' from ${s.effectiveFrom}'}'
                        : 'Now: weighted average',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  RadioGroup<String>(
                    groupValue: method,
                    onChanged: (v) {
                      if (can) setState(() => _method = v);
                    },
                    child: const Column(
                      children: [
                        RadioListTile<String>(
                          value: 'average',
                          title: Text('Weighted average'),
                          subtitle: Text('Every issue costs the running average of all receipts.'),
                        ),
                        RadioListTile<String>(
                          value: 'fifo',
                          title: Text('FIFO'),
                          subtitle: Text('Every issue uses the oldest receipts first.'),
                        ),
                      ],
                    ),
                  ),
                  if (method == 'fifo' && method != s.method)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.event_outlined),
                        label: Text(
                          _date == null
                              ? 'Effective from today'
                              : 'Effective from ${_date!.day}/${_date!.month}/${_date!.year}',
                        ),
                        onPressed: () async {
                          final now = DateTime.now();
                          final d = await showDatePicker(
                            context: context,
                            initialDate: _date ?? now,
                            firstDate: DateTime(now.year, now.month, now.day),
                            lastDate: now.add(const Duration(days: 366)),
                          );
                          if (d != null) setState(() => _date = d);
                        },
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  if (can)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton(
                        onPressed: _busy || method == s.method ? null : () => _save(s),
                        child: const Text('Save method'),
                      ),
                    )
                  else
                    const Text('You do not have permission to change the method.'),
                  const SizedBox(height: 24),
                  Text('Stock value by method', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  const _MethodTotal(method: 'average', label: 'Weighted average'),
                  const _MethodTotal(method: 'fifo', label: 'FIFO'),
                  const SizedBox(height: 8),
                  Text(
                    'The method your books use shows the booked value. The other is rebuilt from the stock moves for comparison and changes nothing.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MethodTotal extends ConsumerWidget {
  const _MethodTotal({required this.method, required this.label});

  final String method;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(permissionsProvider).can(Perm.itemsViewCost)) {
      return const SizedBox.shrink();
    }
    final v = ref.watch(valuationTotalProvider(method));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: v.value == null ? null : Text(v.value!.comparison ? 'For comparison' : 'Used in your books'),
      trailing: Text(v.when(
        data: (t) => formatMoney(t.totalValue),
        loading: () => '...',
        error: (_, _) => 'Not available',
      )),
    );
  }
}
