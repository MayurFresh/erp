import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/number_input.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_fonts.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/search_picker.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import 'pos_cart.dart';
import 'pos_dialogs.dart';
import '../../core/device_settings.dart';
import 'pos_models.dart';
import 'pos_pay_sheet.dart';
import 'pos_receipt_pdf.dart';
import 'pos_repository.dart';
import 'pos_session_screens.dart';

/// Paper width of the receipt printer: false = 80 mm, true = 58 mm.
final posNarrowReceiptProvider = NotifierProvider<NarrowReceiptNotifier, bool>(
  NarrowReceiptNotifier.new,
);

class NarrowReceiptNotifier extends Notifier<bool> {
  static const _key = 'pos.narrowReceipt';

  @override
  bool build() {
    // Remembered on this device; the saved choice replaces the default once read.
    ref.read(deviceSettingsProvider).read(_key).then((v) {
      if (v != null && ref.mounted) state = v == '1';
    });
    return false;
  }

  void toggle() {
    state = !state;
    ref.read(deviceSettingsProvider).write(_key, state ? '1' : '0');
  }
}

/// The counter. Without an open session it asks to open one.
class PosScreen extends ConsumerWidget {
  const PosScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(currentPosSessionProvider);
    return AsyncValueView<PosSession?>(
      value: session,
      onRetry: () => ref.invalidate(currentPosSessionProvider),
      data: (s) =>
          s == null ? const OpenSessionView() : CounterView(session: s),
    );
  }
}

Future<Uint8List> posReceiptBytes(
  WidgetRef ref,
  PosSale sale, {
  required bool narrow,
}) async {
  Company? company;
  try {
    company = await ref.read(companyRepositoryProvider).get();
  } catch (_) {
    company = ref.read(sessionProvider).value?.company;
  }
  final co = company ?? Company(id: '', name: sale.companyName, stateCode: '');
  return buildPosReceiptPdf(
    sale,
    narrow: narrow,
    brand: await loadPdfBrand(ref.read(apiClientProvider), co),
    theme: await pdfTheme(),
  );
}

Future<void> printReceipt(
  BuildContext context,
  WidgetRef ref,
  PosSale sale,
) async {
  final narrow = ref.read(posNarrowReceiptProvider);
  try {
    final bytes = await posReceiptBytes(ref, sale, narrow: narrow);
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: posReceiptFileName(sale),
      format: thermalFormat(narrow: narrow),
    );
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
  }
}

class CounterView extends ConsumerStatefulWidget {
  const CounterView({super.key, required this.session});

  final PosSession session;

  @override
  ConsumerState<CounterView> createState() => _CounterViewState();
}

class _CounterViewState extends ConsumerState<CounterView> {
  final _search = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  int _generation = 0;
  List<PosItem> _results = const [];
  bool _searching = false;
  String? _notice;
  PosSale? _last;
  bool _paying = false;

  PosSession get _s => widget.session;

  @override
  void initState() {
    super.initState();
    ref.listenManual<AsyncValue<bool>>(posInclusiveProvider, (_, next) {
      final v = next.value;
      if (v != null) ref.read(cartProvider.notifier).setInclusive(v);
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _refocus() {
    if (mounted) _focus.requestFocus();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    final q = text.trim();
    if (q.length < 2) {
      setState(() => _results = const []);
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 250),
      () => _lookup(q, enter: false),
    );
  }

  /// Enter in the search box: a barcode scanner sends the code then Enter.
  Future<void> _lookup(String q, {required bool enter}) async {
    final gen = ++_generation;
    setState(() => _searching = true);
    try {
      final r = await ref.read(posRepositoryProvider).lookup(q, _s.locationId);
      if (!mounted || gen != _generation) return;
      if (enter && r.items.length == 1) {
        _add(r.items.first);
        return;
      }
      if (enter && r.items.isEmpty) {
        setState(() {
          _results = const [];
          _notice = 'No item for "$q".';
        });
        return;
      }
      setState(() {
        _results = r.items;
        _notice = null;
      });
    } catch (e) {
      if (mounted && gen == _generation) {
        setState(() => _notice = errorMessage(e));
      }
    } finally {
      if (mounted && gen == _generation) setState(() => _searching = false);
    }
  }

  void _add(PosItem item) {
    ref.read(cartProvider.notifier).add(item);
    _search.clear();
    setState(() {
      _results = const [];
      _notice = null;
    });
    _refocus();
  }

  void _submit(String text) {
    final q = text.trim();
    if (q.isEmpty) {
      _refocus();
      return;
    }
    _debounce?.cancel();
    _lookup(q, enter: true).then((_) => _refocus());
  }

  Future<void> _pay() async {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty || _paying) return;
    _paying = true;
    try {
      final totals = cart.totals;
      final outcome = await showPaySheet(
        context,
        total: totals.total,
        canCredit: cart.partyId != null,
        onSave: (payments, credit) => ref
            .read(posRepositoryProvider)
            .sell(
              sessionId: _s.id,
              lines: cart.lines,
              payments: payments,
              partyId: cart.partyId,
              discount: cart.discount,
              allowCredit: credit,
              expectedTotal: cart.inclusive ? totals.total : null,
            ),
      );
      if (outcome == null || !mounted) return;
      ref.read(cartProvider.notifier).clear();
      ref.read(posRevisionProvider(PosKind.sales).notifier).bump();
      for (final k in [
        DataKind.invoices,
        DataKind.stock,
        DataKind.payments,
        DataKind.parties,
        DataKind.accounts,
      ]) {
        ref.read(revisionProvider(k).notifier).bump();
      }
      setState(() => _last = outcome.sale);
      if (outcome.print) await printReceipt(context, ref, outcome.sale);
    } finally {
      _paying = false;
      _refocus();
    }
  }

  Future<void> _hold() async {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) return;
    final label = await _askLabel();
    if (label == null || !mounted) return;
    try {
      await ref
          .read(posRepositoryProvider)
          .hold(
            _s.id,
            {
              'lines': [
                for (final l in cart.lines)
                  {
                    'itemId': l.item.id,
                    'name': l.item.name,
                    'sku': l.item.sku,
                    'barcode': l.item.barcode,
                    'unit': l.item.unit,
                    'price': l.item.price,
                    'gstRate': l.item.gstRate,
                    'trackStock': l.item.trackStock,
                    'qty': l.qty,
                    'discountPct': l.discountPct,
                  },
              ],
              if (cart.discount != null) 'discount': cart.discount!.toApi(),
              'partyId': cart.partyId,
              'partyName': cart.partyName,
            },
            label: label,
            total: cart.totals.total,
          );
      ref.read(cartProvider.notifier).clear();
      ref.read(posRevisionProvider(PosKind.held).notifier).bump();
      if (mounted) showInfo(context, 'Bill held');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
    _refocus();
  }

  Future<String?> _askLabel() async {
    final ctl = TextEditingController();
    final out = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hold this bill'),
        content: TextField(
          key: const Key('hold-label'),
          controller: ctl,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(
            labelText: 'Name or note (optional)',
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ctl.text.trim()),
            child: const Text('Hold'),
          ),
        ],
      ),
    );
    ctl.dispose();
    return out;
  }

  Future<void> _resume() async {
    final h = await showHeldBills(context, _s.locationId);
    if (h == null || !mounted) return;
    if (!ref.read(cartProvider).isEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Replace the current bill?'),
          content: const Text('The bill on screen will be cleared.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep it'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    try {
      final bill = await ref.read(posRepositoryProvider).resume(h.id);
      ref.read(posRevisionProvider(PosKind.held).notifier).bump();
      final lines = <CartLine>[
        for (final j in asJsonList(bill.payload['lines']))
          CartLine(
            item: PosItem(
              id: asString(j['itemId']),
              name: asString(j['name']),
              sku: asStringOrNull(j['sku']),
              barcode: asStringOrNull(j['barcode']),
              unit: asString(j['unit'], 'nos'),
              price: asDouble(j['price']),
              gstRate: asDouble(j['gstRate']),
              trackStock: j['trackStock'] != false,
            ),
            qty: asDouble(j['qty'], 1),
            discountPct: asDouble(j['discountPct']),
          ),
      ];
      final d = asJsonOrNull(bill.payload['discount']);
      ref
          .read(cartProvider.notifier)
          .load(
            CartState(
              inclusive: ref.read(cartProvider).inclusive,
              lines: lines,
              discount: d == null
                  ? null
                  : (asString(d['type']) == 'pct'
                        ? BillDiscount.pct(asDouble(d['value']))
                        : BillDiscount.amount(asDouble(d['value']))),
              partyId: asStringOrNull(bill.payload['partyId']),
              partyName: asStringOrNull(bill.payload['partyName']),
            ),
          );
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
    _refocus();
  }

  Future<void> _pickCustomer() async {
    final api = ref.read(apiClientProvider);
    final picked = await showSearchPicker<Json>(
      context: context,
      title: 'Customer',
      hintText: 'Name or phone',
      search: (q) async {
        final j = await api.getJson('/parties', query: {'q': q, 'limit': 30});
        return asJsonList(
          j['data'],
        ).where((p) => asString(p['type']) != 'vendor').toList();
      },
      titleBuilder: (_, p) => Text(asString(p['name'])),
      subtitleBuilder: (_, p) => Text(asString(p['phone'])),
    );
    if (picked != null) {
      ref
          .read(cartProvider.notifier)
          .setParty(asString(picked['id']), asString(picked['name']));
    }
    _refocus();
  }

  Future<void> _return() async {
    final out = await showReturnDialog(context);
    if (out != null && mounted) {
      showInfo(context, 'Return saved. Refund recorded on this session.');
      for (final k in [
        DataKind.invoices,
        DataKind.stock,
        DataKind.creditNotes,
        DataKind.accounts,
      ]) {
        ref.read(revisionProvider(k).notifier).bump();
      }
    }
    _refocus();
  }

  Future<void> _menu(String action) async {
    switch (action) {
      case 'hold':
        await _hold();
      case 'held':
        await _resume();
      case 'return':
        await _return();
      case 'cash':
        await showCashMoveDialog(context, ref, _s.id);
      case 'x':
        if (mounted) context.go('/pos/sessions/${_s.id}');
      case 'close':
        if (mounted) context.go('/pos/sessions/${_s.id}/close');
      case 'clear':
        ref.read(cartProvider.notifier).clear();
      case 'width':
        ref.read(posNarrowReceiptProvider.notifier).toggle();
    }
    _refocus();
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);
    final perms = ref.watch(permissionsProvider);
    final held = ref.watch(posHeldProvider(_s.locationId)).value?.length ?? 0;
    final narrowPaper = ref.watch(posNarrowReceiptProvider);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f2): _refocus,
        const SingleActivator(LogicalKeyboardKey.f9): _pay,
      },
      child: Focus(
        autofocus: false,
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= Layout.wide;
            final header = _Header(
              session: _s,
              heldCount: held,
              narrowPaper: narrowPaper,
              canManage: perms.can(Perm.posManage),
              onMenu: _menu,
            );
            final searchBox = _SearchBox(
              controller: _search,
              focus: _focus,
              busy: _searching,
              onChanged: _onChanged,
              onSubmitted: _submit,
            );
            final cartPanel = _CartPanel(
              cart: cart,
              last: _last,
              onPay: _pay,
              onPickCustomer: _pickCustomer,
              onPrintLast: () => printReceipt(context, ref, _last!),
              onDismissLast: () => setState(() => _last = null),
              onRefocus: _refocus,
            );
            final picker = _ItemArea(
              locationId: _s.locationId,
              results: _results,
              notice: _notice,
              query: _search.text.trim(),
              onPick: _add,
              wide: wide,
            );
            if (wide) {
              return Column(
                children: [
                  header,
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 3,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(
                              Space.lg,
                              Space.sm,
                              Space.sm,
                              Space.lg,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                searchBox,
                                const SizedBox(height: Space.sm),
                                Expanded(child: picker),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 440,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(
                              Space.sm,
                              Space.sm,
                              Space.lg,
                              Space.lg,
                            ),
                            child: cartPanel,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }
            return Column(
              children: [
                header,
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.md),
                  child: searchBox,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(Space.md),
                    child:
                        (_results.isNotEmpty ||
                            _notice != null ||
                            _search.text.trim().length >= 2)
                        ? picker
                        : cartPanel,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

void showInfo(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.session,
    required this.heldCount,
    required this.narrowPaper,
    required this.canManage,
    required this.onMenu,
  });

  final PosSession session;
  final int heldCount;
  final bool narrowPaper;
  final bool canManage;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.sm, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${session.locationName}  |  ${session.userName}',
              style: theme.textTheme.titleSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton.icon(
            key: const Key('held-button'),
            onPressed: () => onMenu('held'),
            icon: const Icon(Icons.pause_circle_outline, size: 18),
            label: Text(heldCount > 0 ? 'Held ($heldCount)' : 'Held'),
          ),
          PopupMenuButton<String>(
            key: const Key('pos-menu'),
            tooltip: 'More',
            onSelected: onMenu,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'hold', child: Text('Hold this bill')),
              const PopupMenuItem(value: 'return', child: Text('Return goods')),
              const PopupMenuItem(value: 'cash', child: Text('Cash in or out')),
              const PopupMenuItem(value: 'x', child: Text('X report')),
              PopupMenuItem(
                value: 'width',
                child: Text(
                  narrowPaper ? 'Receipt paper: 58 mm' : 'Receipt paper: 80 mm',
                ),
              ),
              const PopupMenuItem(value: 'clear', child: Text('Clear bill')),
              const PopupMenuItem(value: 'close', child: Text('Close session')),
            ],
          ),
        ],
      ),
    );
  }
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({
    required this.controller,
    required this.focus,
    required this.busy,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool busy;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) => TextField(
    key: const Key('pos-search'),
    controller: controller,
    focusNode: focus,
    autofocus: true,
    textInputAction: TextInputAction.search,
    onChanged: onChanged,
    onSubmitted: onSubmitted,
    decoration: InputDecoration(
      hintText: 'Scan barcode or type item name (F2)',
      prefixIcon: const Icon(Icons.qr_code_scanner),
      suffixIcon: busy
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : null,
    ),
  );
}

class _ItemArea extends ConsumerWidget {
  const _ItemArea({
    required this.locationId,
    required this.results,
    required this.notice,
    required this.query,
    required this.onPick,
    required this.wide,
  });

  final String locationId;
  final List<PosItem> results;
  final String? notice;
  final String query;
  final ValueChanged<PosItem> onPick;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (results.isNotEmpty) {
      return Card(
        margin: EdgeInsets.zero,
        child: ListView.separated(
          itemCount: results.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final it = results[i];
            final out = it.trackStock && (it.stock ?? 0) <= 0;
            return ListTile(
              key: Key('result-${it.id}'),
              title: Text(it.name),
              subtitle: Text(
                [
                  if (it.sku != null) it.sku!,
                  if (it.trackStock) 'Stock ${formatQty(it.stock)}',
                ].join('  |  '),
              ),
              trailing: Text(formatMoney(it.price)),
              enabled: !out,
              onTap: () => onPick(it),
            );
          },
        ),
      );
    }
    if (notice != null || query.length >= 2) {
      return Center(child: Text(notice ?? 'No matching items.'));
    }
    final quick = ref.watch(posQuickItemsProvider(locationId));
    return AsyncValueView<List<PosItem>>(
      value: quick,
      onRetry: () => ref.invalidate(posQuickItemsProvider(locationId)),
      data: (items) => items.isEmpty
          ? const Center(child: Text('Scan an item or search by name.'))
          : GridView.builder(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: wide ? 170 : 150,
                mainAxisExtent: 76,
                crossAxisSpacing: Space.sm,
                mainAxisSpacing: Space.sm,
              ),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final it = items[i];
                final out = it.trackStock && (it.stock ?? 0) <= 0;
                return Material(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  shape: RoundedRectangleBorder(
                    borderRadius: Radii.mediumAll,
                    side: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                  child: InkWell(
                    key: Key('quick-${it.id}'),
                    borderRadius: Radii.mediumAll,
                    onTap: out ? null : () => onPick(it),
                    child: Padding(
                      padding: const EdgeInsets.all(Space.sm),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              it.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: out
                                    ? Theme.of(context).disabledColor
                                    : null,
                              ),
                            ),
                          ),
                          Text(
                            out ? 'Out of stock' : formatMoney(it.price),
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _CartPanel extends ConsumerWidget {
  const _CartPanel({
    required this.cart,
    required this.last,
    required this.onPay,
    required this.onPickCustomer,
    required this.onPrintLast,
    required this.onDismissLast,
    required this.onRefocus,
  });

  final CartState cart;
  final PosSale? last;
  final VoidCallback onPay;
  final VoidCallback onPickCustomer;
  final VoidCallback onPrintLast;
  final VoidCallback onDismissLast;
  final VoidCallback onRefocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final notifier = ref.read(cartProvider.notifier);
    final totals = cart.totals;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (last != null)
            Container(
              key: const Key('last-sale'),
              color: colors.successContainer,
              padding: const EdgeInsets.symmetric(
                horizontal: Space.md,
                vertical: Space.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${last!.number} saved'
                      '${last!.changeDue > 0 ? '. Change ${formatMoney(last!.changeDue)}' : ''}',
                      style: TextStyle(
                        color: colors.onSuccessContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onPrintLast,
                    child: const Text('Print'),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    onPressed: onDismissLast,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.person_outline),
            title: Text(
              cart.partyName ?? 'Walk-in customer',
              key: const Key('cart-customer'),
            ),
            trailing: cart.partyId == null
                ? TextButton(
                    onPressed: onPickCustomer,
                    child: const Text('Choose'),
                  )
                : IconButton(
                    tooltip: 'Back to walk-in',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => notifier.setParty(null, null),
                  ),
          ),
          const Divider(height: 1),
          Expanded(
            child: cart.isEmpty
                ? const Center(child: Text('The bill is empty.'))
                : ListView.separated(
                    key: const Key('cart-lines'),
                    itemCount: cart.lines.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _CartRow(
                      index: i,
                      line: cart.lines[i],
                      onRefocus: onRefocus,
                    ),
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(Space.md),
            child: Column(
              children: [
                _kv(context, 'Items', formatQty(totals.itemCount)),
                if (totals.discount > 0)
                  _kv(context, 'Discount', '-${formatAmount(totals.discount)}'),
                _kv(context, 'Tax', formatAmount(totals.tax)),
                if (totals.roundOff != 0)
                  _kv(context, 'Round off', formatAmount(totals.roundOff)),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('bill-discount'),
                    onPressed: cart.isEmpty
                        ? null
                        : () async {
                            final d = await askBillDiscount(
                              context,
                              cart.discount,
                            );
                            if (d != null) notifier.setDiscount(d);
                            onRefocus();
                          },
                    child: Text(
                      cart.discount == null
                          ? 'Add discount'
                          : 'Change discount',
                    ),
                  ),
                ),
                Row(
                  children: [
                    Text('Total', style: theme.textTheme.titleMedium),
                    const Spacer(),
                    Text(
                      formatMoney(totals.total),
                      key: const Key('cart-total'),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.sm),
                SizedBox(
                  width: double.infinity,
                  height: Layout.touchTarget,
                  child: FilledButton(
                    key: const Key('pay-button'),
                    onPressed: cart.isEmpty ? null : onPay,
                    child: const Text('Pay (F9)'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      children: [
        Expanded(child: Text(k, style: Theme.of(context).textTheme.bodySmall)),
        Text(v, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class _CartRow extends ConsumerWidget {
  const _CartRow({
    required this.index,
    required this.line,
    required this.onRefocus,
  });

  final int index;
  final CartLine line;
  final VoidCallback onRefocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(cartProvider.notifier);
    final theme = Theme.of(context);
    final overStock =
        line.item.trackStock &&
        line.item.stock != null &&
        line.qty > line.item.stock!;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  line.item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                formatAmount(line.taxable),
                style: theme.textTheme.titleSmall,
              ),
            ],
          ),
          Text(
            '${formatAmount(line.rate)} each  |  GST ${formatPlain(line.item.gstRate)}%',
            style: theme.textTheme.bodySmall,
          ),
          Row(
            children: [
              IconButton(
                key: Key('minus-$index'),
                tooltip: 'Less',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () {
                  n.setQty(index, line.qty - 1);
                  onRefocus();
                },
              ),
              InkWell(
                key: Key('qty-$index'),
                onTap: () async {
                  final q = await askNumber(
                    context,
                    title: 'Quantity',
                    label: line.item.unit,
                    initial: line.qty,
                    decimals: 3,
                    max: kMaxQty,
                  );
                  if (q != null) n.setQty(index, q);
                  onRefocus();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.sm,
                    vertical: Space.xs,
                  ),
                  child: Text(
                    formatQty(line.qty),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
              IconButton(
                key: Key('plus-$index'),
                tooltip: 'More',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () {
                  n.setQty(index, line.qty + 1);
                  onRefocus();
                },
              ),
              const Spacer(),
              TextButton(
                key: Key('line-discount-$index'),
                onPressed: () async {
                  final d = await askNumber(
                    context,
                    title: 'Line discount',
                    label: 'Discount %',
                    initial: line.discountPct == 0 ? null : line.discountPct,
                    max: 100,
                  );
                  if (d != null) n.setLineDiscount(index, d);
                  onRefocus();
                },
                child: Text(
                  line.discountPct > 0
                      ? '-${formatPlain(line.discountPct)}%'
                      : 'Disc',
                ),
              ),
              IconButton(
                key: Key('remove-$index'),
                tooltip: 'Remove',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  n.remove(index);
                  onRefocus();
                },
              ),
            ],
          ),
          if (overStock)
            Text(
              'Only ${formatQty(line.item.stock)} in stock',
              style: theme.textTheme.bodySmall?.copyWith(
                color: context.colors.danger,
              ),
            ),
        ],
      ),
    );
  }
}
