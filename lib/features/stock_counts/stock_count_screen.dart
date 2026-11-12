import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import 'count_models.dart';
import 'count_repository.dart';
import 'stock_counts_screen.dart';

enum _Filter {
  all('All'),
  uncounted('Not counted'),
  counted('Counted'),
  variance('With variance');

  const _Filter(this.label);
  final String label;
}

/// A count in progress: scan or key in quantities, review variances, post.
///
/// The scan field keeps focus after every scan, so a keyboard-wedge scanner
/// (which types the code and presses Enter) can be used without touching the
/// screen. Scans are sent one at a time, in order; the field never waits.
class StockCountScreen extends ConsumerStatefulWidget {
  const StockCountScreen({super.key, required this.countId});

  final String countId;

  @override
  ConsumerState<StockCountScreen> createState() => _StockCountState();
}

class _StockCountState extends ConsumerState<StockCountScreen> {
  final _scan = TextEditingController();
  final _scanFocus = FocusNode();
  StockCount? _count;
  List<CountLine> _lines = [];
  Object? _loadError;
  _Filter _filter = _Filter.all;
  String _query = '';
  int _pending = 0;
  int _seq = 0;
  Future<void> _queue = Future.value();
  String? _feedback;
  bool _feedbackIsError = false;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scan.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final count = await ref
          .read(stockCountsRepositoryProvider)
          .get(widget.countId);
      if (!mounted) return;
      setState(() {
        _count = count;
        _lines = count.lines;
        _loadError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _refocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _count?.isOpen == true) _scanFocus.requestFocus();
    });
  }

  void _apply(CountLine line) {
    final i = _lines.indexWhere((l) => l.itemId == line.itemId);
    _lines = [..._lines];
    if (i >= 0) {
      _lines[i] = line;
    } else {
      _lines.add(line);
    }
  }

  /// Sends one scan or manual entry; entries run in the order they were made.
  void _enqueue({
    String? code,
    String? itemId,
    double qty = 1,
    String mode = 'add',
  }) {
    final scanId = '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';
    setState(() => _pending++);
    _queue = _queue.then((_) async {
      try {
        final result = await ref
            .read(stockCountsRepositoryProvider)
            .scan(
              widget.countId,
              scanId: scanId,
              code: code,
              itemId: itemId,
              qty: qty,
              mode: mode,
            );
        if (!mounted) return;
        final l = result.line;
        setState(() {
          _apply(l);
          _feedbackIsError = false;
          _feedback =
              '${l.itemName}: counted ${formatQty(l.countedQty)} ${l.unit}';
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _feedbackIsError = true;
          _feedback = code == null
              ? (apiError(e)?.message ?? 'Could not save that count.')
              : '"$code": ${apiError(e)?.message ?? 'could not be counted.'}';
        });
      } finally {
        if (mounted) setState(() => _pending--);
      }
    });
  }

  void _onScan(String raw) {
    final code = raw.trim();
    _scan.clear();
    if (code.isNotEmpty) _enqueue(code: code);
    _refocus();
  }

  Future<void> _setQty(CountLine line) async {
    final controller = TextEditingController(
      text: formatPlain(line.countedQty),
    );
    final qty = await showFormDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(line.itemName),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: const [
            NumberInputFormatter(decimals: 3, max: kMaxQty),
          ],
          decoration: InputDecoration(
            labelText: 'Counted quantity (${line.unit})',
            helperText: 'Replaces the quantity counted so far.',
          ),
          onSubmitted: (v) {
            final n = parseNumber(v);
            if (n != null) Navigator.of(context).pop(n);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final n = parseNumber(controller.text);
              if (n != null && n >= 0) Navigator.of(context).pop(n);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (qty != null) _enqueue(itemId: line.itemId, qty: qty, mode: 'set');
    _refocus();
  }

  Future<void> _post() async {
    if (_posting) return;
    final count = _count!;
    final uncounted = _lines.where((l) => !l.counted).length;
    var zero = false;
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('Post ${count.number}?'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Stock at the location is corrected to the counted '
                'quantities and the difference is booked to the accounts. '
                'This cannot be undone.',
              ),
              if (uncounted > 0)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: zero,
                  onChanged: (v) => setLocal(() => zero = v ?? false),
                  title: Text('Count $uncounted uncounted items as zero'),
                  subtitle: const Text('Otherwise they are left as they are.'),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep counting'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Post count'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _posting = true);
    try {
      await _queue;
      await ref
          .read(stockCountsRepositoryProvider)
          .post(widget.countId, zeroUncounted: zero);
      ref.bump(const [DataKind.stock]);
      await _load();
      if (mounted) showInfoSnackBar(context, 'Count ${count.number} posted');
    } catch (e) {
      if (!mounted) return;
      final api = apiError(e);
      if (api?.code == 'COUNT_APPROVAL_REQUIRED') {
        setState(() => _posting = false);
        await showFormDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Approval needed'),
            content: Text(
              'The variance of ${formatMoney(asDouble(api!.details['varianceValue']))} '
              'is above the limit of ${formatMoney(asDouble(api.details['thresholdValue']))}. '
              'Ask a user with count approval rights to post this count.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      } else {
        showErrorSnackBar(context, e);
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _cancel() async {
    final count = _count!;
    final reason = await showFormDialog<String>(
      context: context,
      builder: (_) => CancelReasonDialog(
        title: 'Cancel ${count.number}?',
        message: 'Nothing is posted. The counts entered so far are discarded.',
        confirmLabel: 'Cancel count',
        keepLabel: 'Keep count',
      ),
    );
    if (reason == null || !mounted) return;
    try {
      await ref
          .read(stockCountsRepositoryProvider)
          .cancel(widget.countId, reason);
      ref.bump(const [DataKind.stock]);
      if (!mounted) return;
      showInfoSnackBar(context, 'Count ${count.number} cancelled');
      context.go('/stock-counts');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  List<CountLine> get _visible {
    final q = _query.trim().toLowerCase();
    return [
      for (final l in _lines)
        if (switch (_filter) {
              _Filter.all => true,
              _Filter.uncounted => !l.counted,
              _Filter.counted => l.counted,
              _Filter.variance => l.hasVariance,
            } &&
            (q.isEmpty ||
                l.itemName.toLowerCase().contains(q) ||
                (l.sku ?? '').toLowerCase().contains(q) ||
                (l.barcode ?? '').toLowerCase().contains(q)))
          l,
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      return ErrorView(error: _loadError!, onRetry: _load);
    }
    final count = _count;
    if (count == null) return const LoadingView();
    final perms = ref.watch(permissionsProvider);
    final canManage = perms.can(Perm.stockCountsManage);
    final editable = count.isOpen && canManage;
    final theme = Theme.of(context);
    final counted = _lines.where((l) => l.counted).length;
    final withVariance = _lines.where((l) => l.hasVariance).length;
    final hasValues = _lines.any((l) => l.varianceValue != null);
    final net = _lines.fold<double>(0, (s, l) => s + (l.varianceValue ?? 0));
    final gross = _lines.fold<double>(
      0,
      (s, l) => s + (l.varianceValue ?? 0).abs(),
    );
    final threshold = count.thresholdValue;
    final overLimit =
        hasValues &&
        threshold != null &&
        gross > threshold &&
        !perms.can(Perm.stockCountsApprove);
    final visible = _visible;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: count.number,
          subtitle:
              '${count.locationName} · started ${formatDateTime(count.snapshotAt)}'
              '${count.scope == 'selected' ? ' · chosen items' : ''}',
          actions: [
            StockCountStatusChip(count.status),
            if (editable) ...[
              OutlinedButton(
                onPressed: _posting ? null : _cancel,
                child: const Text('Cancel count'),
              ),
              FilledButton.icon(
                onPressed: _posting || counted == 0 ? null : _post,
                icon: _posting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: const Text('Post count'),
              ),
            ],
          ],
        ),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.5,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (editable)
                    TextField(
                      controller: _scan,
                      focusNode: _scanFocus,
                      autofocus: true,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: 'Scan barcode or SKU',
                        prefixIcon: const Icon(Icons.qr_code_scanner),
                        helperText: _pending > 0
                            ? 'Saving $_pending scan${_pending == 1 ? '' : 's'}…'
                            : 'Each scan adds one. Press Enter after typing a code.',
                      ),
                      onSubmitted: _onScan,
                    ),
                  if (_feedback != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _feedback!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _feedbackIsError
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 24,
                    runSpacing: 8,
                    children: [
                      LabeledValue('Counted', '$counted of ${_lines.length}'),
                      LabeledValue('Not counted', '${_lines.length - counted}'),
                      LabeledValue('With variance', '$withVariance'),
                      if (hasValues)
                        LabeledValue('Net variance', formatMoney(net)),
                    ],
                  ),
                  if (overLimit && editable)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'The variance is above the approval limit of '
                        '${formatMoney(threshold)}. A user with count approval '
                        'rights must post this count.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final f in _Filter.values)
                        ChoiceChip(
                          label: Text(f.label),
                          selected: _filter == f,
                          onSelected: (_) {
                            setState(() => _filter = f);
                            _refocus();
                          },
                        ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 280),
                        child: SearchField(
                          hintText: 'Find an item',
                          onChanged: (q) => setState(() => _query = q),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? const EmptyView(message: 'No items match.')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _CountLineTile(
                    line: visible[i],
                    onTap: editable ? () => _setQty(visible[i]) : null,
                  ),
                ),
        ),
      ],
    );
  }
}

class _CountLineTile extends StatelessWidget {
  const _CountLineTile({required this.line, this.onTap});

  final CountLine line;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final v = line.varianceQty;
    final varianceColor = v == null || !line.hasVariance
        ? scheme.onSurfaceVariant
        : (v < 0 ? scheme.error : scheme.primary);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(line.itemName, style: theme.textTheme.titleSmall),
                    if (line.sku != null)
                      Text(line.sku!, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 2),
                    Text(
                      'Expected ${formatQty(line.expectedNow)} ${line.unit}'
                      '${line.movedSince != 0 ? ' (moved ${line.movedSince > 0 ? '+' : ''}${formatQty(line.movedSince)} since start)' : ''}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    line.counted
                        ? '${formatQty(line.countedQty)} ${line.unit}'
                        : 'Not counted',
                    style: theme.textTheme.titleSmall,
                  ),
                  if (line.counted)
                    Text(
                      line.hasVariance
                          ? '${v! > 0 ? '+' : ''}${formatQty(v)}'
                                '${line.varianceValue == null ? '' : ' · ${formatMoney(line.varianceValue)}'}'
                          : 'Matches',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: varianceColor,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
