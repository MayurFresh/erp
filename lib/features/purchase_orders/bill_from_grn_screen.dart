import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import '../documents/line_editor.dart';
import 'po_models.dart';
import 'po_repository.dart';

class _BillLine {
  _BillLine(this.grn)
    : qty = TextEditingController(text: formatPlain(grn.billableQty)),
      rate = TextEditingController(text: formatPlain(grn.poRate)),
      discount = TextEditingController(
        text: grn.discountPct > 0 ? formatPlain(grn.discountPct) : '',
      );

  final GrnLine grn;
  final TextEditingController qty;
  final TextEditingController rate;
  final TextEditingController discount;
  bool include = true;

  double get qtyValue => parseNumber(qty.text) ?? 0;
  double get billRate => parseNumber(rate.text) ?? 0;
  double get billDiscount => parseNumber(discount.text) ?? 0;
  double get billNet => billRate * (1 - billDiscount / 100);
  double get poNet => grn.poRate * (1 - grn.discountPct / 100);
  double get variancePct => poNet == 0 ? 0 : (billNet - poNet) / poNet * 100;
  double get varianceValue => (billNet - poNet) * qtyValue;
  bool get hasVariance => (billNet - poNet).abs() > 0.0001;
  bool get valid =>
      qtyValue > 0 && qtyValue <= grn.billableQty && billRate >= 0;

  void dispose() {
    qty.dispose();
    rate.dispose();
    discount.dispose();
  }
}

/// Create a purchase bill from the lines of a goods receipt (three-way match).
/// Shows the price difference against the purchase order for each line.
class BillFromGrnScreen extends ConsumerStatefulWidget {
  const BillFromGrnScreen({super.key, required this.grnId});

  final String grnId;

  @override
  ConsumerState<BillFromGrnScreen> createState() => _BillFromGrnState();
}

class _BillFromGrnState extends ConsumerState<BillFromGrnScreen>
    with DirtyTracking<BillFromGrnScreen> {
  final _supplierNo = TextEditingController();
  final _notes = TextEditingController();
  DateTime _billDate = DateUtils.dateOnly(DateTime.now());
  DateTime? _supplierDate;

  GoodsReceipt? _grn;
  List<_BillLine> _lines = [];
  Object? _loadError;
  bool _saving = false;
  Object? _saveError;
  bool _varianceBlocked = false;
  bool _acceptVariance = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final grn = await ref.read(poRepositoryProvider).receipt(widget.grnId);
      if (!mounted) return;
      setState(() {
        _grn = grn;
        _lines = [
          for (final l in grn.lines)
            if (l.billableQty > 0) _BillLine(l),
        ];
        _loadError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  @override
  void dispose() {
    _supplierNo.dispose();
    _notes.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  List<_BillLine> get _chosen => _lines.where((l) => l.include).toList();

  double get _taxable => _chosen.fold(0, (s, l) => s + l.qtyValue * l.billNet);

  double get _variance => _chosen.fold(0, (s, l) => s + l.varianceValue);

  Future<void> _pickBillDate() async {
    final picked = await pickDocDate(context, _billDate);
    if (picked != null) {
      if (mounted) setState(() => _billDate = picked);
      markDirty();
    }
  }

  Future<void> _pickSupplierDate() async {
    final picked = await pickDocDate(context, _supplierDate ?? _billDate);
    if (picked != null) {
      if (mounted) setState(() => _supplierDate = picked);
      markDirty();
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final grn = _grn!;
    final chosen = _chosen;
    if (chosen.isEmpty || chosen.any((l) => !l.valid)) {
      showInfoSnackBar(
        context,
        'Choose at least one line and check the quantities.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final supplierDate = _supplierDate;
      final bill = await ref
          .read(poRepositoryProvider)
          .createBillFromGrn(
            withoutNulls({
              'locationId': grn.locationId,
              'partyId': grn.partyId,
              'billDate': apiDate(_billDate),
              'supplierInvoiceNo': trimmedOrNull(_supplierNo.text),
              'supplierInvoiceDate': supplierDate == null
                  ? null
                  : apiDate(supplierDate),
              'notes': trimmedOrNull(_notes.text),
              if (_acceptVariance) 'acceptVariance': true,
              'lines': [
                for (final l in chosen)
                  {
                    'itemId': l.grn.itemId,
                    'grnLineId': l.grn.id,
                    'qty': l.qtyValue,
                    'rate': l.billRate,
                    'discountPct': l.billDiscount,
                  },
              ],
            }),
          );
      ref.bump(const [DataKind.purchases, DataKind.stock, DataKind.parties]);
      markSaved();
      if (!mounted) return;
      showInfoSnackBar(context, 'Bill ${bill.number ?? ''} saved');
      context.go('/purchases/${bill.id}');
    } catch (e) {
      if (!mounted) return;
      if (handleApprovalPending(
        context,
        e,
        listPath: '/purchases',
        onSaved: markSaved,
      )) {
        return;
      }
      setState(() {
        _saveError = e;
        _varianceBlocked = apiError(e)?.code == 'PRICE_VARIANCE';
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
    final grn = _grn;
    if (grn == null) return const LoadingView();
    return track(_body(context, grn));
  }

  Widget _body(BuildContext context, GoodsReceipt grn) {
    final theme = Theme.of(context);
    final canOverride = ref
        .watch(permissionsProvider)
        .can(Perm.purchasesOverride);
    return FormPage(
      bottomBar: FormActionBar(
        children: [
          TextButton(
            onPressed: _saving
                ? null
                : () => leave('/purchase-orders/${grn.purchaseOrderId}'),
            child: const Text('Cancel'),
          ),
          BusyButton(
            busy: _saving,
            onPressed: _lines.isEmpty ? null : _save,
            label: 'Save bill',
            icon: Icons.receipt_long_outlined,
          ),
        ],
      ),
      maxWidth: 1000,
      children: [
        PageHeader(
          title: 'Create bill from receipt',
          subtitle:
              '${grn.number} · ${grn.partyName} · PO ${grn.purchaseOrderNumber}',
        ),
        if (_lines.isEmpty)
          const SectionCard(
            child: Text('Every line of this receipt is already billed.'),
          ),
        SectionCard(
          title: 'Bill details',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FormRow(
                children: [
                  PickerField(
                    label: 'Bill date',
                    value: formatDate(_billDate),
                    icon: Icons.calendar_today_outlined,
                    onTap: _pickBillDate,
                  ),
                  TextFormField(
                    controller: _supplierNo,
                    onChanged: (_) => markDirty(),
                    decoration: const InputDecoration(
                      labelText: 'Supplier invoice no. (optional)',
                    ),
                  ),
                  PickerField(
                    label: 'Supplier invoice date (optional)',
                    value: _supplierDate == null
                        ? null
                        : formatDate(_supplierDate),
                    icon: Icons.event_outlined,
                    onTap: _pickSupplierDate,
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
        if (_lines.isNotEmpty)
          SectionCard(
            title: 'Lines to bill',
            child: Column(
              children: [
                for (final (i, l) in _lines.indexed) ...[
                  if (i > 0) const Divider(height: 24),
                  _BillLineEditor(
                    line: l,
                    enabled: !_saving,
                    onChanged: () {
                      setState(() => _varianceBlocked = false);
                      markDirty();
                    },
                  ),
                ],
              ],
            ),
          ),
        if (_lines.isNotEmpty)
          SectionCard(
            title: 'Match summary',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LabeledValue(
                  'Taxable value (before GST)',
                  formatMoney(_taxable),
                ),
                const SizedBox(height: 8),
                LabeledValue(
                  'Price difference against the order',
                  _variance == 0
                      ? 'None'
                      : '${_variance > 0 ? 'Over' : 'Under'} by '
                            '${formatMoney(_variance.abs())}',
                ),
                const SizedBox(height: 4),
                Text(
                  'GST, TDS and the total are worked out when you save.',
                  style: theme.textTheme.bodySmall,
                ),
                if (_varianceBlocked)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _acceptVariance,
                    onChanged: canOverride
                        ? (v) => setState(() => _acceptVariance = v ?? false)
                        : null,
                    title: const Text('Accept the price difference'),
                    subtitle: Text(
                      canOverride
                          ? 'The difference is posted to purchase price variance.'
                          : 'Only a user with override rights can accept it. '
                                'Correct the price or ask for approval.',
                    ),
                  ),
              ],
            ),
          ),
        if (_saveError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ApiErrorBox(error: _saveError!, subject: 'the bill'),
          ),
      ],
    );
  }
}

class _BillLineEditor extends StatelessWidget {
  const _BillLineEditor({
    required this.line,
    required this.enabled,
    required this.onChanged,
  });

  final _BillLine line;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final g = line.grn;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: line.include,
          onChanged: enabled
              ? (v) {
                  line.include = v ?? false;
                  onChanged();
                }
              : null,
          title: Text(g.itemName),
          subtitle: Text(
            'Received ${formatQty(g.acceptedQty)} ${g.unit} · billed '
            '${formatQty(g.billedQty)} · order price ${formatMoney(g.poRate)}'
            '${g.discountPct > 0 ? ' less ${formatPercent(g.discountPct)}' : ''}',
          ),
        ),
        if (line.include) ...[
          FormRow(
            children: [
              TextFormField(
                controller: line.qty,
                enabled: enabled,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: const [
                  NumberInputFormatter(decimals: 3, max: kMaxQty),
                ],
                decoration: InputDecoration(
                  labelText: 'Quantity (${g.unit})',
                  errorText: line.valid
                      ? null
                      : 'Up to ${formatQty(g.billableQty)}',
                ),
                onChanged: (_) => onChanged(),
              ),
              TextFormField(
                controller: line.rate,
                enabled: enabled,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: const [NumberInputFormatter()],
                decoration: const InputDecoration(labelText: 'Bill price'),
                onChanged: (_) => onChanged(),
              ),
              TextFormField(
                controller: line.discount,
                enabled: enabled,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: const [NumberInputFormatter(max: kMaxPercent)],
                decoration: const InputDecoration(labelText: 'Discount %'),
                onChanged: (_) => onChanged(),
              ),
            ],
          ),
          if (line.hasVariance)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_outlined,
                    size: 18,
                    color: scheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Differs from the order by ${formatPercent(line.variancePct.abs())} '
                      '(${formatMoney(line.varianceValue.abs())} '
                      '${line.varianceValue > 0 ? 'over' : 'under'})',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
