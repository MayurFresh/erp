import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../documents/document_widgets.dart';
import '../documents/line_editor.dart';
import '../items/items_repository.dart';
import 'po_models.dart';
import 'po_repository.dart';

class _RecvLine {
  _RecvLine(this.line)
    : accepted = TextEditingController(text: '0'),
      rejected = TextEditingController(),
      reason = TextEditingController();

  final PoLine line;
  final TextEditingController accepted;
  final TextEditingController rejected;
  final TextEditingController reason;

  double get acceptedQty => parseNumber(accepted.text) ?? 0;
  double get rejectedQty => parseNumber(rejected.text) ?? 0;
  bool get active => acceptedQty + rejectedQty > 0;

  void dispose() {
    accepted.dispose();
    rejected.dispose();
    reason.dispose();
  }
}

/// Receive goods against a purchase order, by scanning or typing quantities.
class ReceiveGoodsScreen extends ConsumerStatefulWidget {
  const ReceiveGoodsScreen({super.key, required this.poId});

  final String poId;

  @override
  ConsumerState<ReceiveGoodsScreen> createState() => _ReceiveGoodsState();
}

class _ReceiveGoodsState extends ConsumerState<ReceiveGoodsScreen>
    with DirtyTracking<ReceiveGoodsScreen> {
  final _scan = TextEditingController();
  final _scanFocus = FocusNode();
  final _challan = TextEditingController();
  final _vehicle = TextEditingController();
  final _notes = TextEditingController();
  DateTime _date = DateUtils.dateOnly(DateTime.now());

  PurchaseOrder? _po;
  List<_RecvLine> _lines = [];
  Object? _loadError;
  bool _saving = false;
  Object? _saveError;
  Map<String, String> _lineErrors = const {};
  String? _scanMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final po = await ref.read(poRepositoryProvider).get(widget.poId);
      if (!mounted) return;
      setState(() {
        _po = po;
        _lines = [
          for (final l in po.lines ?? const <PoLine>[])
            if (l.openQty > 0 || l.rejectedQty > 0) _RecvLine(l),
        ];
        _loadError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  @override
  void dispose() {
    _scan.dispose();
    _scanFocus.dispose();
    _challan.dispose();
    _vehicle.dispose();
    _notes.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  void _bumpAccepted(_RecvLine l, double by) {
    final next = l.acceptedQty + by;
    setState(() => l.accepted.text = formatPlain(next));
    markDirty();
  }

  Future<void> _onScan(String raw) async {
    final code = raw.trim();
    _scan.clear();
    _scanFocus.requestFocus();
    if (code.isEmpty) return;
    final lower = code.toLowerCase();
    _RecvLine? match;
    for (final l in _lines) {
      if ((l.line.sku ?? '').toLowerCase() == lower) match = l;
    }
    if (match == null) {
      try {
        final found = await ref
            .read(itemsRepositoryProvider)
            .list(q: code, limit: 10);
        for (final item in found.data) {
          final hit =
              (item.barcode ?? '').toLowerCase() == lower ||
              (item.sku ?? '').toLowerCase() == lower;
          if (!hit) continue;
          for (final l in _lines) {
            if (l.line.itemId == item.id) match = l;
          }
        }
      } catch (_) {
        // Falls through to "not on this order".
      }
    }
    if (!mounted) return;
    if (match == null) {
      setState(() => _scanMessage = '"$code" is not on this order.');
    } else {
      _bumpAccepted(match, 1);
      setState(
        () => _scanMessage =
            '${match!.line.itemName}: ${formatQty(match.acceptedQty)} '
            '${match.line.unit} accepted.',
      );
    }
    _scanFocus.requestFocus();
  }

  Future<void> _pickDate() async {
    final picked = await pickDocDate(context, _date);
    if (picked != null) {
      if (mounted) setState(() => _date = picked);
      markDirty();
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final active = _lines.where((l) => l.active).toList();
    if (active.isEmpty) {
      showInfoSnackBar(
        context,
        'Enter a received quantity for at least one item.',
      );
      return;
    }
    for (final l in active) {
      if (l.rejectedQty > 0 && l.reason.text.trim().isEmpty) {
        setState(
          () => _lineErrors = {l.line.id!: 'Give a reason for the rejection'},
        );
        return;
      }
    }
    setState(() {
      _saving = true;
      _saveError = null;
      _lineErrors = const {};
    });
    try {
      final grn = await ref
          .read(poRepositoryProvider)
          .receive(
            purchaseOrderId: widget.poId,
            receiptDate: apiDate(_date),
            challanNo: trimmedOrNull(_challan.text),
            vehicleNo: trimmedOrNull(_vehicle.text),
            notes: trimmedOrNull(_notes.text),
            lines: [
              for (final l in active)
                withoutNulls({
                  'poLineId': l.line.id,
                  'acceptedQty': l.acceptedQty,
                  if (l.rejectedQty > 0) 'rejectedQty': l.rejectedQty,
                  if (l.rejectedQty > 0) 'rejectReason': l.reason.text.trim(),
                }),
            ],
          );
      ref.bump(poKinds);
      markSaved();
      if (!mounted) return;
      showInfoSnackBar(context, 'Receipt ${grn.number} saved');
      context.go('/purchase-orders/${widget.poId}');
    } catch (e) {
      if (!mounted) return;
      final errors = <String, String>{};
      final details = apiError(e)?.details['lines'];
      if (details is List) {
        for (final d in asJsonList(details)) {
          final id = asString(d['poLineId']);
          if (id.isNotEmpty) {
            errors[id] =
                'Only ${formatQty(asDouble(d['allowed']))} can be received';
          }
        }
      }
      setState(() {
        _saveError = e;
        _lineErrors = errors;
      });
      showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      return ErrorView(error: _loadError!, onRetry: _load);
    }
    final po = _po;
    if (po == null) return const LoadingView();
    return track(_body(context, po));
  }

  Widget _body(BuildContext context, PurchaseOrder po) {
    final theme = Theme.of(context);
    return FormPage(
      bottomBar: FormActionBar(
        children: [
          TextButton(
            onPressed: _saving
                ? null
                : () => leave('/purchase-orders/${widget.poId}'),
            child: const Text('Cancel'),
          ),
          BusyButton(
            busy: _saving,
            onPressed: po.canReceive ? _save : null,
            label: 'Save receipt',
            icon: Icons.move_to_inbox_outlined,
          ),
        ],
      ),
      maxWidth: 1000,
      children: [
        PageHeader(
          title: 'Receive goods',
          subtitle: '${po.number ?? ''} · ${po.partyName} · ${po.locationName}',
        ),
        if (!po.canReceive)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text(
              'This order cannot receive goods in its current state.',
            ),
          ),
        SectionCard(
          title: 'Scan items',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _scan,
                focusNode: _scanFocus,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Barcode or SKU',
                  prefixIcon: Icon(Icons.qr_code_scanner),
                  helperText: 'Each scan adds one to the accepted quantity.',
                ),
                onSubmitted: _onScan,
              ),
              if (_scanMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_scanMessage!, style: theme.textTheme.bodySmall),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () {
                    setState(() {
                      for (final l in _lines) {
                        l.accepted.text = formatPlain(l.line.openQty);
                      }
                    });
                    markDirty();
                  },
                  child: const Text('Receive all open quantities'),
                ),
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Items',
          child: _lines.isEmpty
              ? const Text('Nothing is waiting to be received.')
              : Column(
                  children: [
                    for (final (i, l) in _lines.indexed) ...[
                      if (i > 0) const Divider(height: 24),
                      _RecvLineEditor(
                        line: l,
                        error: _lineErrors[l.line.id],
                        enabled: !_saving,
                        onChanged: () {
                          setState(() {});
                          markDirty();
                        },
                      ),
                    ],
                  ],
                ),
        ),
        SectionCard(
          title: 'Delivery details',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FormRow(
                children: [
                  PickerField(
                    label: 'Receipt date',
                    value: formatDate(_date),
                    icon: Icons.calendar_today_outlined,
                    onTap: _pickDate,
                  ),
                  TextFormField(
                    controller: _challan,
                    onChanged: (_) => markDirty(),
                    decoration: const InputDecoration(
                      labelText: 'Delivery challan no. (optional)',
                    ),
                  ),
                  TextFormField(
                    controller: _vehicle,
                    onChanged: (_) => markDirty(),
                    decoration: const InputDecoration(
                      labelText: 'Vehicle no. (optional)',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _notes,
                onChanged: (_) => markDirty(),
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                ),
              ),
            ],
          ),
        ),
        if (_saveError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ApiErrorBox(error: _saveError!, subject: 'the receipt'),
          ),
      ],
    );
  }
}

class _RecvLineEditor extends StatelessWidget {
  const _RecvLineEditor({
    required this.line,
    required this.error,
    required this.enabled,
    required this.onChanged,
  });

  final _RecvLine line;
  final String? error;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l = line.line;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.itemName, style: theme.textTheme.titleSmall),
        Text(
          'Ordered ${formatQty(l.qty)} ${l.unit} · received '
          '${formatQty(l.receivedQty)} · still to receive '
          '${formatQty(l.openQty)}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        FormRow(
          children: [
            TextFormField(
              controller: line.accepted,
              enabled: enabled,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: const [
                NumberInputFormatter(decimals: 3, max: kMaxQty),
              ],
              decoration: InputDecoration(
                labelText: 'Accepted (${l.unit})',
                errorText: error,
              ),
              onChanged: (_) => onChanged(),
            ),
            TextFormField(
              controller: line.rejected,
              enabled: enabled,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: const [
                NumberInputFormatter(decimals: 3, max: kMaxQty),
              ],
              decoration: InputDecoration(labelText: 'Rejected (${l.unit})'),
              onChanged: (_) => onChanged(),
            ),
            if (line.rejectedQty > 0)
              TextFormField(
                controller: line.reason,
                enabled: enabled,
                decoration: const InputDecoration(
                  labelText: 'Rejection reason',
                ),
              ),
          ],
        ),
      ],
    );
  }
}
