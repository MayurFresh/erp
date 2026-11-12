import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import '../items/item_model.dart';
import '../items/item_picker.dart';
import '../locations/location_filter.dart';
import 'count_models.dart';
import 'count_repository.dart';
import '../../widgets/form_support.dart';

const _statusLabels = {
  'open': 'Open',
  'posted': 'Posted',
  'cancelled': 'Cancelled',
};

class StockCountStatusChip extends StatelessWidget {
  const StockCountStatusChip(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) =>
      StatusChip(status, label: _statusLabels[status] ?? status);
}

class StockCountsScreen extends ConsumerStatefulWidget {
  const StockCountsScreen({super.key});

  @override
  ConsumerState<StockCountsScreen> createState() => _StockCountsState();
}

class _StockCountsState extends ConsumerState<StockCountsScreen> {
  String? _status;
  String? _locationId;
  late final PagedController<StockCount> _paged = PagedController(
    (offset, limit) => ref
        .read(stockCountsRepositoryProvider)
        .list(
          status: _status,
          locationId: _locationId,
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

  Future<void> _new() async {
    final created = await showFormDialog<StockCount>(
      context: context,
      builder: (_) => const _NewCountDialog(),
    );
    if (created != null && mounted) {
      ref.bump(const [DataKind.stock]);
      context.go('/stock-counts/${created.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(revisionProvider(DataKind.stock), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) {
      _locationId = null;
      _paged.refresh();
    });
    final canManage = ref
        .watch(permissionsProvider)
        .can(Perm.stockCountsManage);
    void open(StockCount c) => context.go('/stock-counts/${c.id}');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Stock counts',
          actions: [
            if (canManage)
              FilledButton.icon(
                onPressed: _new,
                icon: const Icon(Icons.add),
                label: const Text('New count'),
              ),
          ],
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Status',
              value: _status,
              width: 160,
              options: _statusLabels,
              onChanged: (v) {
                setState(() => _status = v);
                _paged.refresh();
              },
            ),
            LocationFilter(
              value: _locationId,
              onChanged: (id) {
                setState(() => _locationId = id);
                _paged.refresh();
              },
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<StockCount>(
            controller: _paged,
            emptyMessage: 'No stock counts yet.',
            emptyIcon: Icons.fact_check_outlined,
            onTap: open,
            tableBreakpoint: 900,
            columns: [
              TableColumnSpec('Number', (c) => Text(c.number)),
              TableColumnSpec('Location', (c) => Text(c.locationName)),
              TableColumnSpec(
                'Started',
                (c) => Text(formatDateTime(c.snapshotAt)),
              ),
              TableColumnSpec('Status', (c) => StockCountStatusChip(c.status)),
              TableColumnSpec(
                'Counted',
                (c) => Text('${c.countedCount} of ${c.lineCount}'),
                numeric: true,
              ),
              TableColumnSpec(
                'Variance',
                (c) => Text(
                  c.varianceValue == null ? '—' : formatMoney(c.varianceValue),
                ),
                numeric: true,
              ),
            ],
            cardBuilder: (context, c) => DocListCard(
              onTap: () => open(c),
              title: c.number,
              details: [
                c.locationName,
                formatDateTime(c.snapshotAt),
              ].join(' · '),
              pills: StockCountStatusChip(c.status),
              amount: c.varianceValue == null
                  ? '${c.countedCount} of ${c.lineCount}'
                  : formatMoney(c.varianceValue),
              secondary: c.varianceValue == null
                  ? null
                  : '${c.countedCount} of ${c.lineCount} counted',
            ),
          ),
        ),
      ],
    );
  }
}

/// Starts a count: a location, then every item or a chosen few.
class _NewCountDialog extends ConsumerStatefulWidget {
  const _NewCountDialog();

  @override
  ConsumerState<_NewCountDialog> createState() => _NewCountDialogState();
}

class _NewCountDialogState extends ConsumerState<_NewCountDialog> {
  String? _locationId;
  bool _selected = false;
  final List<Item> _items = [];
  final _notes = TextEditingController();
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _addItem() async {
    final item = await pickItem(context, ref, stockOnly: true);
    if (item != null && !_items.any((i) => i.id == item.id)) {
      if (mounted) setState(() => _items.add(item));
    }
  }

  Future<void> _start() async {
    if (_busy) return;
    final location = _locationId;
    if (location == null) {
      setState(() => _error = 'Choose a location.');
      return;
    }
    if (_selected && _items.isEmpty) {
      setState(() => _error = 'Add at least one item, or count every item.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final count = await ref
          .read(stockCountsRepositoryProvider)
          .create(
            locationId: location,
            itemIds: _selected ? [for (final i in _items) i.id] : null,
            notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(count);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = _error;
    return AlertDialog(
      title: const Text('New stock count'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LocationField(
                value: _locationId,
                onChanged: (v) => setState(() => _locationId = v),
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Every item')),
                  ButtonSegment(value: true, label: Text('Chosen items')),
                ],
                selected: {_selected},
                onSelectionChanged: (s) => setState(() => _selected = s.first),
              ),
              if (_selected) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final i in _items)
                      InputChip(
                        label: Text(i.name),
                        onDeleted: () => setState(() => _items.remove(i)),
                      ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _addItem,
                    icon: const Icon(Icons.add),
                    label: const Text('Add item'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'The expected quantities are fixed at the moment you start. '
                'Stock that moves while you count is allowed for.',
                style: theme.textTheme.bodySmall,
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error is String
                        ? error
                        : (apiError(error)?.message ??
                              'Could not start the count.'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _start,
          child: const Text('Start count'),
        ),
      ],
    );
  }
}
