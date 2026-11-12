import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/busy.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/search_picker.dart';
import '../../widgets/states.dart';
import '../sales_orders/o2c_repository.dart';
import '../sales_orders/sales_order_models.dart';

/// Raises a return against a dispatched order. `orderId` pre-selects it.
class ReturnCreateScreen extends ConsumerStatefulWidget {
  const ReturnCreateScreen({super.key, this.orderId});

  final String? orderId;

  @override
  ConsumerState<ReturnCreateScreen> createState() => _ReturnCreateScreenState();
}

class _ReturnCreateScreenState extends ConsumerState<ReturnCreateScreen>
    with DirtyTracking, ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();
  final Map<String, TextEditingController> _qty = {};
  SalesOrder? _order;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.orderId != null) _load(widget.orderId!);
  }

  @override
  void dispose() {
    _reason.dispose();
    for (final c in _qty.values) {
      c.dispose();
    }
    super.dispose();
  }

  double _returnable(SalesOrderLine l) => l.qtyDispatched - l.qtyReturned;

  Future<void> _load(String id) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final o = await ref.read(o2cRepositoryProvider).order(id);
      if (!mounted) return;
      for (final c in _qty.values) {
        c.dispose();
      }
      _qty.clear();
      for (final l in o.lines) {
        _qty[l.id] = TextEditingController();
      }
      setState(() {
        _order = o;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = errorMessage(e);
      });
    }
  }

  Future<void> _pickOrder() async {
    final repo = ref.read(o2cRepositoryProvider);
    final o = await showSearchPicker<SalesOrder>(
      context: context,
      title: 'Choose an order',
      hintText: 'Search order number or customer',
      search: (q) async => (await repo.orders(q: q, limit: 30)).data
          .where((o) => o.status != 'draft' && o.status != 'cancelled')
          .toList(),
      titleBuilder: (_, o) => Text(o.number),
      subtitleBuilder: (_, o) =>
          Text('${o.partyName} · ${statusLabel(o.status)}'),
    );
    if (o == null || !mounted) return;
    await _load(o.id);
    markDirty();
  }

  Future<void> _save() async {
    if (!validateAndReveal(_formKey)) return;
    final lines = <Map<String, dynamic>>[];
    for (final l in _order!.lines) {
      final q = parseNumber(_qty[l.id]!.text) ?? 0;
      if (q > 0) lines.add({'orderLineId': l.id, 'qty': q});
    }
    if (lines.isEmpty) {
      showInfoSnackBar(context, 'Enter a quantity for at least one item');
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await ref
          .read(o2cRepositoryProvider)
          .createReturn(
            orderId: _order!.id,
            reason: _reason.text.trim(),
            lines: lines,
          );
      markSaved();
      ref.read(o2cRevisionProvider.notifier).bump();
      if (!mounted) return;
      showInfoSnackBar(context, 'Return ${r.number} raised');
      context.go('/sales-returns/${r.id}');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final order = _order;
    return track(
      Form(
        key: _formKey,
        onChanged: markDirty,
        child: FormPage(
          bottomBar: FormActionBar(
            children: [
              TextButton(
                onPressed: _saving ? null : () => leave('/sales-returns'),
                child: const Text('Cancel'),
              ),
              BusyButton(
                busy: _saving,
                onPressed: order == null ? null : _save,
                label: 'Raise return',
                icon: Icons.check,
              ),
            ],
          ),
          children: [
            Text('New sales return', style: theme.textTheme.headlineSmall),
            SectionCard(
              title: 'Order',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PickerField(
                    label: 'Sales order',
                    value: order == null
                        ? null
                        : '${order.number} · ${order.partyName}',
                    errorText: _error,
                    onTap: _pickOrder,
                    validator: () => order == null ? 'Choose an order' : null,
                  ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(),
                    ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _reason,
                    maxLength: 300,
                    decoration: InputDecoration(
                      labelText: 'Reason',
                      errorText: serverError('reason'),
                    ),
                    validator: (v) => requiredField(v, 'Reason'),
                  ),
                ],
              ),
            ),
            if (order != null)
              SectionCard(
                title: 'Items coming back',
                child: Column(
                  children: [
                    for (final l in order.lines.where(
                      (l) => _returnable(l) > 0,
                    ))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: FormRow(
                          breakpoint: 480,
                          children: [
                            Text(
                              '${l.itemName}\n'
                              'Dispatched ${formatQty(_returnable(l))} ${l.unit}',
                            ),
                            TextFormField(
                              controller: _qty[l.id],
                              keyboardType: decimalKeyboard,
                              inputFormatters: <TextInputFormatter>[
                                decimalInput(decimals: 3),
                              ],
                              decoration: const InputDecoration(
                                labelText: 'Quantity returned',
                              ),
                              validator: (v) {
                                final n = parseNumber(v ?? '');
                                if (n != null && n > _returnable(l)) {
                                  return 'At most ${formatQty(_returnable(l))}';
                                }
                                return null;
                              },
                            ),
                          ],
                        ),
                      ),
                    if (!order.lines.any((l) => _returnable(l) > 0))
                      const Text('Nothing on this order can be returned.'),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
