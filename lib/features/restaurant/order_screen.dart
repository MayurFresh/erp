import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, bigOutlinedButton, showReasonDialog, showSuccess;
import 'rest_models.dart';
import 'rest_perms.dart';
import 'rest_repository.dart';
import 'rest_widgets.dart';
import 'settle_dialog.dart';

/// `/restaurant/order/:id`: menu on one side, the order on the other.
class OrderScreen extends ConsumerStatefulWidget {
  const OrderScreen({super.key, required this.orderId});

  final String orderId;

  @override
  ConsumerState<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends ConsumerState<OrderScreen> {
  String _query = '';
  String? _categoryId;
  final _pending = <String>{};
  RestPoller? _poller;

  @override
  void initState() {
    super.initState();
    _poller = RestPoller(
      ref.read(restPollProvider),
      () => ref.invalidate(restOrderProvider(widget.orderId)),
    );
  }

  @override
  void dispose() {
    _poller?.dispose();
    super.dispose();
  }

  void _reload() => ref.invalidate(restOrderProvider(widget.orderId));

  RestaurantRepository get _repo => ref.read(restaurantRepositoryProvider);

  /// Adds one of [entry]; a second tap raises the quantity of the unsent line.
  Future<void> _add(RestOrder order, MenuEntry entry) async {
    if (!_pending.add(entry.itemId)) return;
    try {
      final existing = order.lines
          .where(
            (l) =>
                l.isDraft && l.itemId == entry.itemId && (l.note ?? '').isEmpty,
          )
          .firstOrNull;
      if (existing != null) {
        await _repo.editLine(order.id, existing.id, {'qty': existing.qty + 1});
      } else {
        await _repo.addItems(order.id, [
          (itemId: entry.itemId, qty: 1, note: null),
        ]);
      }
      _reload();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      _pending.remove(entry.itemId);
    }
  }

  Future<void> _setQty(RestOrder order, OrderLine line, double qty) async {
    if (!_pending.add(line.id)) return;
    try {
      if (qty <= 0) {
        await _repo.cancelLine(order.id, line.id);
      } else {
        await _repo.editLine(order.id, line.id, {'qty': qty});
      }
      _reload();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      _pending.remove(line.id);
    }
  }

  Future<void> _note(RestOrder order, OrderLine line) async {
    final note = await showFormDialog<String>(
      context: context,
      builder: (_) => _NoteDialog(initial: line.note ?? ''),
    );
    if (note == null || !mounted) return;
    final ok = await restGuarded(
      context,
      () => _repo.editLine(order.id, line.id, {'note': note}),
    );
    if (ok) _reload();
  }

  Future<void> _cancelSent(RestOrder order, OrderLine line) async {
    final reason = await showReasonDialog(
      context,
      title: 'Cancel ${line.name}?',
      message:
          'It already went to the kitchen. The cancel is recorded with your '
          'reason.',
      confirmLabel: 'Cancel item',
      cancelLabel: 'Keep',
    );
    if (reason == null || !mounted) return;
    final ok = await restGuarded(
      context,
      () => _repo.cancelLine(order.id, line.id, reason: reason),
    );
    if (ok) {
      ref.bumpRest();
    }
  }

  Future<void> _send(RestOrder order) async {
    try {
      final result = await _repo.sendKot(order.id);
      ref.bumpRest();
      if (!mounted) return;
      if (result.newKotIds.isEmpty) {
        showInfoSnackBar(context, 'Nothing new to send.');
        return;
      }
      final numbers = result.order.kots
          .where((k) => result.newKotIds.contains(k.id))
          .map((k) => k.kotNo)
          .toSet()
          .join(', ');
      final ids = result.newKotIds;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            // Lifted so it does not cover the action buttons.
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
            duration: const Duration(seconds: 3),
            content: Text('Sent to kitchen (KOT $numbers)'),
            action: SnackBarAction(
              label: 'Print',
              onPressed: () => printKots(context, ref, ids),
            ),
          ),
        );
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _printBill(RestOrder order) async {
    final perms = ref.read(permissionsProvider);
    RestOrder printed = order;
    if (order.isOpen) {
      double? discount;
      double? discountAmount;
      String? reason;
      var waive = false;
      if (perms.can(RestPerm.manage)) {
        final choice = await showFormDialog<_BillChoice>(
          context: context,
          builder: (_) => _PrintBillDialog(order: order),
        );
        if (choice == null || !mounted) return;
        discount = choice.discountPct;
        discountAmount = choice.discountAmount;
        reason = choice.reason;
        waive = choice.waiveServiceCharge;
      }
      try {
        printed = await _repo.printBill(
          order.id,
          discountPct: discount,
          discountAmount: discountAmount,
          discountReason: reason,
          waiveServiceCharge: waive,
        );
        ref.bumpRest();
      } catch (e) {
        if (mounted) showErrorSnackBar(context, e);
        return;
      }
    }
    if (mounted) await printBill(context, ref, printed);
  }

  Future<void> _settle(RestOrder order) async {
    if (order.draftCount > 0) {
      showInfoSnackBar(
        context,
        'Send the new items to the kitchen before settling.',
      );
      return;
    }
    final result = await showFormDialog<SettleResult>(
      context: context,
      builder: (_) => SettleDialog(order: order),
    );
    if (result == null || !mounted) return;
    ref.bumpRest();
    showSuccess(
      context,
      result.chargedToRoom
          ? 'Settled, ${result.invoiceNumber}. ${formatMoney(result.total)} before tax on the hotel folio.'
          : 'Settled. Bill ${result.invoiceNumber}, ${formatMoney(result.total)}',
    );
    context.go(order.isDineIn ? '/restaurant/floor' : '/restaurant/orders');
  }

  Future<void> _reopen(RestOrder order) async {
    final ok = await restGuarded(context, () => _repo.reopen(order.id));
    if (ok) ref.bumpRest();
  }

  Future<void> _move(RestOrder order) async {
    final tableId = await showFormDialog<String>(
      context: context,
      builder: (_) => _PickTableDialog(
        title: 'Move to another table',
        onlyFree: true,
        exclude: order.tableId,
      ),
    );
    if (tableId == null || !mounted) return;
    final ok = await restGuarded(context, () => _repo.move(order.id, tableId));
    if (ok) ref.bumpRest();
  }

  Future<void> _merge(RestOrder order) async {
    final fromId = await showFormDialog<String>(
      context: context,
      builder: (_) => _PickTableDialog(
        title: 'Merge another table into this one',
        onlyFree: false,
        exclude: order.tableId,
      ),
    );
    if (fromId == null || !mounted) return;
    final ok = await restGuarded(context, () => _repo.merge(order.id, fromId));
    if (ok) ref.bumpRest();
  }

  Future<void> _cancelOrder(RestOrder order) async {
    final reason = await showReasonDialog(
      context,
      title: 'Cancel this order?',
      message:
          'All items on ${order.title} are cancelled and the table is freed.',
      confirmLabel: 'Cancel order',
      cancelLabel: 'Keep',
    );
    if (reason == null || !mounted) return;
    final ok = await restGuarded(
      context,
      () => _repo.cancelOrder(order.id, reason),
    );
    if (ok && mounted) {
      ref.bumpRest();
      context.go(order.isDineIn ? '/restaurant/floor' : '/restaurant/orders');
    }
  }

  @override
  Widget build(BuildContext context) {
    return CGate(
      anyOf: const [RestPerm.orders, RestPerm.manage, RestPerm.settle],
      child: AsyncValueView(
        value: ref.watch(restOrderProvider(widget.orderId)),
        onRetry: _reload,
        data: _body,
      ),
    );
  }

  Widget _body(RestOrder order) {
    final perms = ref.watch(permissionsProvider);
    final canOrder = perms.can(RestPerm.orders) || perms.can(RestPerm.manage);
    final editable = order.isOpen && canOrder;
    final menu = _MenuPanel(
      order: order,
      enabled: editable,
      query: _query,
      categoryId: _categoryId,
      onQuery: (q) => setState(() => _query = q),
      onCategory: (c) => setState(() => _categoryId = c),
      onAdd: (e) => _add(order, e),
    );
    final cart = _CartPanel(
      order: order,
      editable: editable,
      canSettle: perms.can(RestPerm.settle) || perms.can(RestPerm.manage),
      canManage: perms.can(RestPerm.manage),
      canOrder: canOrder,
      onQty: (l, q) => _setQty(order, l, q),
      onNote: (l) => _note(order, l),
      onCancelSent: (l) => _cancelSent(order, l),
      onSend: () => _send(order),
      onPrint: () => _printBill(order),
      onSettle: () => _settle(order),
      onReopen: () => _reopen(order),
      onMove: () => _move(order),
      onMerge: () => _merge(order),
      onCancelOrder: () => _cancelOrder(order),
    );
    final header = _OrderHeader(order: order);
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= kWideLayout) {
          return Column(
            children: [
              header,
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: menu),
                    VerticalDivider(width: 1, color: context.colors.hairline),
                    SizedBox(
                      width: math.min(440, box.maxWidth * 0.36),
                      child: cart,
                    ),
                  ],
                ),
              ),
            ],
          );
        }
        final count = order.liveLines.length;
        return DefaultTabController(
          length: 2,
          child: Column(
            children: [
              header,
              TabBar(
                tabs: [
                  const Tab(text: 'Menu'),
                  Tab(text: count == 0 ? 'Order' : 'Order ($count)'),
                ],
              ),
              Expanded(child: TabBarView(children: [menu, cart])),
            ],
          ),
        );
      },
    );
  }
}

class _OrderHeader extends StatelessWidget {
  const _OrderHeader({required this.order});

  final RestOrder order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final (label, bg, fg) = switch (order.status) {
      'bill_printed' => (
        'Bill printed',
        colors.infoContainer,
        colors.onInfoContainer,
      ),
      'settled' => (
        'Settled',
        colors.successContainer,
        colors.onSuccessContainer,
      ),
      'cancelled' => (
        'Cancelled',
        colors.dangerContainer,
        colors.onDangerContainer,
      ),
      _ => ('Open', colors.warningContainer, colors.onWarningContainer),
    };
    return Padding(
      padding: EdgeInsets.fromLTRB(
        pageGutter(context) - 4,
        Space.sm,
        pageGutter(context),
        Space.xs,
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            onPressed: () => context.go(
              order.isDineIn ? '/restaurant/floor' : '/restaurant/orders',
            ),
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
                Text(
                  [
                    order.number,
                    if (order.covers != null) '${order.covers} guests',
                    if ((order.customerPhone ?? '').isNotEmpty)
                      order.customerPhone!,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          StatusTag(label, bg: bg, fg: fg),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------- menu

class _MenuPanel extends ConsumerWidget {
  const _MenuPanel({
    required this.order,
    required this.enabled,
    required this.query,
    required this.categoryId,
    required this.onQuery,
    required this.onCategory,
    required this.onAdd,
  });

  final RestOrder order;
  final bool enabled;
  final String query;
  final String? categoryId;
  final ValueChanged<String> onQuery;
  final ValueChanged<String?> onCategory;
  final ValueChanged<MenuEntry> onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(restCategoriesProvider).value ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            pageGutter(context),
            Space.xs,
            pageGutter(context),
            Space.xs,
          ),
          child: SearchField(onChanged: onQuery, hintText: 'Search the menu'),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: Space.sm),
                child: ChoiceChip(
                  label: const Text('All'),
                  selected: categoryId == null,
                  onSelected: (_) => onCategory(null),
                ),
              ),
              for (final c in categories.where((c) => c.isActive))
                Padding(
                  padding: const EdgeInsets.only(right: Space.sm),
                  child: ChoiceChip(
                    label: Text(c.name),
                    selected: categoryId == c.id,
                    onSelected: (_) => onCategory(c.id),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: AsyncValueView(
            value: ref.watch(restMenuProvider),
            onRetry: () => ref.invalidate(restMenuProvider),
            data: (all) {
              final q = query.trim().toLowerCase();
              final shown = [
                for (final e in all)
                  if ((categoryId == null || e.categoryId == categoryId) &&
                      (q.isEmpty ||
                          e.name.toLowerCase().contains(q) ||
                          (e.shortName ?? '').toLowerCase().contains(q)))
                    e,
              ];
              if (shown.isEmpty) {
                return const EmptyView(
                  icon: Icons.restaurant_menu,
                  message: 'Nothing on the menu matches.',
                );
              }
              final inCart = <String, double>{};
              for (final l in order.liveLines.where((l) => l.isDraft)) {
                inCart[l.itemId] = (inCart[l.itemId] ?? 0) + l.qty;
              }
              return LayoutBuilder(
                builder: (context, box) {
                  final gutter = pageGutter(context);
                  final cols = math.max(
                    1,
                    ((box.maxWidth - gutter * 2) / 260).floor(),
                  );
                  return GridView.builder(
                    padding: EdgeInsets.all(gutter),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisExtent: 64,
                      crossAxisSpacing: Space.sm,
                      mainAxisSpacing: Space.sm,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (_, i) => _MenuTile(
                      entry: shown[i],
                      inCart: inCart[shown[i].itemId] ?? 0,
                      enabled: enabled && shown[i].available,
                      onTap: () => onAdd(shown[i]),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.entry,
    required this.inCart,
    required this.enabled,
    required this.onTap,
  });

  final MenuEntry entry;
  final double inCart;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    return Opacity(
      opacity: entry.available ? 1 : 0.5,
      child: Material(
        color: inCart > 0
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
            : theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.mediumAll,
          side: BorderSide(color: colors.hairline),
        ),
        child: InkWell(
          borderRadius: Radii.mediumAll,
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: Row(
              children: [
                DietMark(entry.diet),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        entry.available
                            ? formatMoney(entry.price)
                            : 'Not available today',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (inCart > 0)
                  CircleAvatar(
                    radius: 13,
                    backgroundColor: theme.colorScheme.primary,
                    child: Text(
                      formatQty(inCart),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------- cart

class _CartPanel extends StatelessWidget {
  const _CartPanel({
    required this.order,
    required this.editable,
    required this.canSettle,
    required this.canManage,
    required this.canOrder,
    required this.onQty,
    required this.onNote,
    required this.onCancelSent,
    required this.onSend,
    required this.onPrint,
    required this.onSettle,
    required this.onReopen,
    required this.onMove,
    required this.onMerge,
    required this.onCancelOrder,
  });

  final RestOrder order;
  final bool editable, canSettle, canManage, canOrder;
  final void Function(OrderLine, double) onQty;
  final ValueChanged<OrderLine> onNote, onCancelSent;
  final Future<void> Function() onSend;
  final Future<void> Function() onPrint;
  final VoidCallback onSettle, onReopen, onMove, onMerge, onCancelOrder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = pageGutter(context);
    final drafts = order.lines.where((l) => l.isDraft).toList();
    final sent = order.lines.where((l) => l.isSent).toList();
    final cancelled = order.lines.where((l) => l.isCancelled).toList();
    final live = order.liveLines.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (order.isBillPrinted)
          Container(
            width: double.infinity,
            color: context.colors.infoContainer,
            padding: EdgeInsets.symmetric(
              horizontal: gutter,
              vertical: Space.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'The bill is printed. Items are locked.',
                    style: TextStyle(color: context.colors.onInfoContainer),
                  ),
                ),
                if (canManage)
                  TextButton(onPressed: onReopen, child: const Text('Reopen')),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.all(gutter),
            children: [
              if (order.lines.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.xxl),
                  child: Center(
                    child: Text(
                      'Tap items on the menu to add them.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              if (drafts.isNotEmpty) ...[
                _SectionLabel('Not sent yet (${drafts.length})'),
                for (final l in drafts)
                  _LineRow(
                    line: l,
                    editable: editable,
                    canManage: canManage,
                    onQty: onQty,
                    onNote: onNote,
                    onCancelSent: onCancelSent,
                  ),
              ],
              if (sent.isNotEmpty) ...[
                _SectionLabel('With the kitchen'),
                for (final l in sent)
                  _LineRow(
                    line: l,
                    editable: editable,
                    canManage: canManage,
                    onQty: onQty,
                    onNote: onNote,
                    onCancelSent: onCancelSent,
                  ),
              ],
              if (cancelled.isNotEmpty) ...[
                _SectionLabel('Cancelled'),
                for (final l in cancelled)
                  _LineRow(
                    line: l,
                    editable: false,
                    canManage: canManage,
                    onQty: onQty,
                    onNote: onNote,
                    onCancelSent: onCancelSent,
                  ),
              ],
              if (live) ...[
                const SizedBox(height: Space.md),
                _Totals(bill: order.bill),
              ],
            ],
          ),
        ),
        if (order.isActive && canOrder || order.isActive && canSettle)
          Material(
            elevation: 4,
            color: theme.colorScheme.surface,
            child: Padding(
              padding: EdgeInsets.fromLTRB(gutter, Space.sm, gutter, Space.sm),
              child: Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: Space.sm,
                      runSpacing: Space.sm,
                      children: [
                        if (editable)
                          BusyButton(
                            onPressed: order.draftCount == 0 ? null : onSend,
                            label: order.draftCount == 0
                                ? 'Send to kitchen'
                                : 'Send to kitchen (${order.draftCount})',
                            icon: Icons.send_outlined,
                          ),
                        if (canOrder)
                          OutlinedButton.icon(
                            style: bigOutlinedButton,
                            onPressed: live ? () => onPrint() : null,
                            icon: const Icon(Icons.receipt_long_outlined),
                            label: Text(
                              order.isBillPrinted
                                  ? 'Reprint bill'
                                  : 'Print bill',
                            ),
                          ),
                        if (canSettle)
                          FilledButton.icon(
                            style: bigButton,
                            onPressed: live ? onSettle : null,
                            icon: const Icon(Icons.payments_outlined),
                            label: const Text('Settle'),
                          ),
                      ],
                    ),
                  ),
                  if (canOrder)
                    PopupMenuButton<String>(
                      tooltip: 'More',
                      onSelected: (v) => switch (v) {
                        'move' => onMove(),
                        'merge' => onMerge(),
                        _ => onCancelOrder(),
                      },
                      itemBuilder: (_) => [
                        if (order.isDineIn && order.isOpen)
                          const PopupMenuItem(
                            value: 'move',
                            child: Text('Move to another table'),
                          ),
                        if (order.isDineIn && order.isOpen)
                          const PopupMenuItem(
                            value: 'merge',
                            child: Text('Merge another table'),
                          ),
                        const PopupMenuItem(
                          value: 'cancel',
                          child: Text('Cancel order'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.sm, bottom: Space.xs),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.line,
    required this.editable,
    required this.canManage,
    required this.onQty,
    required this.onNote,
    required this.onCancelSent,
  });

  final OrderLine line;
  final bool editable, canManage;
  final void Function(OrderLine, double) onQty;
  final ValueChanged<OrderLine> onNote, onCancelSent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final struck = line.isCancelled
        ? const TextStyle(decoration: TextDecoration.lineThrough)
        : null;
    final (statusBg, statusFg) = switch (line.kitchenStatus) {
      KitchenStatus.ready => (
        colors.successContainer,
        colors.onSuccessContainer,
      ),
      KitchenStatus.preparing => (
        colors.warningContainer,
        colors.onWarningContainer,
      ),
      KitchenStatus.served => (
        colors.neutralContainer,
        colors.onNeutralContainer,
      ),
      _ => (colors.infoContainer, colors.onInfoContainer),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: Space.xs),
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.hairline)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (line.isDraft && editable)
            _Stepper(qty: line.qty, onChanged: (q) => onQty(line, q))
          else
            SizedBox(
              width: 44,
              child: Text(
                '${formatQty(line.qty)} ×',
                style: theme.textTheme.titleSmall?.merge(struck),
              ),
            ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.name,
                  style: theme.textTheme.bodyLarge?.merge(struck),
                ),
                if ((line.note ?? '').isNotEmpty)
                  Text(
                    line.note!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (line.isCancelled && (line.cancelReason ?? '').isNotEmpty)
                  Text(
                    'Cancelled: ${line.cancelReason}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.danger,
                    ),
                  ),
                if (line.isSent)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: StatusTag(
                      line.kotNo == null
                          ? line.kitchenStatus.label
                          : 'KOT ${line.kotNo} · ${line.kitchenStatus.label}',
                      bg: statusBg,
                      fg: statusFg,
                    ),
                  ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatMoney(line.amount),
                style: theme.textTheme.bodyLarge?.merge(struck),
              ),
              if (editable && line.isDraft)
                IconButton(
                  tooltip: 'Add a note',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onNote(line),
                  icon: const Icon(Icons.edit_note, size: 20),
                ),
              if (editable && line.isSent && canManage)
                IconButton(
                  tooltip: 'Cancel item',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onCancelSent(line),
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.qty, required this.onChanged});

  final double qty;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _StepButton(
        icon: qty <= 1 ? Icons.delete_outline : Icons.remove,
        tooltip: qty <= 1 ? 'Remove' : 'One less',
        onTap: () => onChanged(qty - 1),
      ),
      SizedBox(
        width: 28,
        child: Text(
          formatQty(qty),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      _StepButton(
        icon: Icons.add,
        tooltip: 'One more',
        onTap: () => onChanged(qty + 1),
      ),
    ],
  );
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
    padding: EdgeInsets.zero,
    style: IconButton.styleFrom(
      side: BorderSide(color: context.colors.hairline),
    ),
    icon: Icon(icon, size: 18),
  );
}

class _Totals extends StatelessWidget {
  const _Totals({required this.bill});

  final Bill bill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(String l, String r, {bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            l,
            style: strong
                ? theme.textTheme.titleMedium
                : theme.textTheme.bodyMedium,
          ),
          Text(
            r,
            style: strong
                ? theme.textTheme.titleMedium
                : theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
    return Column(
      children: [
        row('Items', formatMoney(bill.gross)),
        if (bill.discount > 0)
          row(
            'Discount ${formatPlain(bill.discountPct)}%',
            '-${formatMoney(bill.discount)}',
          ),
        if (bill.serviceCharge > 0)
          row(
            'Service charge ${formatPlain(bill.serviceChargePct)}%',
            formatMoney(bill.serviceCharge),
          ),
        row('GST', formatMoney(bill.taxTotal)),
        if (bill.roundOff != 0) row('Round off', formatMoney(bill.roundOff)),
        const Divider(height: Space.md),
        row('Total', formatMoney(bill.total), strong: true),
      ],
    );
  }
}

// -------------------------------------------------------------------- dialogs

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.initial});

  final String initial;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final _note = TextEditingController(text: widget.initial);

  static const _quick = [
    'Less spicy',
    'Extra spicy',
    'No onion',
    'No garlic',
    'Jain',
    'Pack separately',
  ];

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Note for the kitchen'),
    scrollable: true,
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _note,
            autofocus: true,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Note'),
          ),
          Wrap(
            spacing: Space.sm,
            children: [
              for (final q in _quick)
                ActionChip(
                  label: Text(q),
                  onPressed: () => setState(() {
                    final t = _note.text.trim();
                    _note.text = t.isEmpty ? q : '$t, $q';
                  }),
                ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_note.text.trim()),
        child: const Text('Save note'),
      ),
    ],
  );
}

class _BillChoice {
  const _BillChoice({
    this.discountPct,
    this.discountAmount,
    this.reason,
    this.waiveServiceCharge = false,
  });

  final double? discountPct;
  final double? discountAmount;
  final String? reason;
  final bool waiveServiceCharge;
}

/// Managers can give a discount or waive the service charge before printing.
class _PrintBillDialog extends StatefulWidget {
  const _PrintBillDialog({required this.order});

  final RestOrder order;

  @override
  State<_PrintBillDialog> createState() => _PrintBillDialogState();
}

class _PrintBillDialogState extends State<_PrintBillDialog> {
  final _formKey = GlobalKey<FormState>();
  final _pct = TextEditingController();
  final _reason = TextEditingController();
  bool _waive = false;
  bool _byAmount = false;

  @override
  void dispose() {
    _pct.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final pct = parseNumber(_pct.text.trim());
    Navigator.of(context).pop(
      _BillChoice(
        discountPct: !_byAmount && pct != null && pct > 0 ? pct : null,
        discountAmount: _byAmount && pct != null && pct > 0 ? pct : null,
        reason: trimmedOrNull(_reason.text),
        waiveServiceCharge: _waive,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Print bill'),
    scrollable: true,
    content: SizedBox(
      width: 380,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Total ${formatMoney(widget.order.bill.total)}. After printing, the items are locked until a manager reopens the bill.',
            ),
            const SizedBox(height: Space.md),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Percent')),
                ButtonSegment(value: true, label: Text('Amount')),
              ],
              selected: {_byAmount},
              onSelectionChanged: (v) => setState(() => _byAmount = v.first),
            ),
            const SizedBox(height: Space.sm),
            TextFormField(
              controller: _pct,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: _byAmount
                    ? 'Discount amount (optional)'
                    : 'Discount % (optional)',
              ),
              validator: (v) => optionalNumber(
                v,
                min: 0,
                max: _byAmount ? widget.order.bill.gross : 100,
              ),
            ),
            const SizedBox(height: Space.sm),
            TextFormField(
              controller: _reason,
              decoration: const InputDecoration(
                labelText: 'Reason for the discount',
              ),
              validator: (v) {
                final pct = parseNumber(_pct.text.trim()) ?? 0;
                return pct > 0 && (v == null || v.trim().length < 3)
                    ? 'Give a reason'
                    : null;
              },
            ),
            if (widget.order.bill.serviceCharge > 0)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _waive,
                onChanged: (v) => setState(() => _waive = v ?? false),
                title: const Text('Waive service charge'),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton.icon(
        onPressed: _submit,
        icon: const Icon(Icons.print_outlined),
        label: const Text('Print bill'),
      ),
    ],
  );
}

/// Picks a table to move to (free ones) or to merge from (tables with orders).
class _PickTableDialog extends ConsumerWidget {
  const _PickTableDialog({
    required this.title,
    required this.onlyFree,
    this.exclude,
  });

  final String title;
  final bool onlyFree;
  final String? exclude;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final floor = ref.watch(restFloorProvider);
    return AlertDialog(
      title: Text(title),
      scrollable: true,
      content: SizedBox(
        width: 380,
        child: AsyncValueView(
          value: floor,
          onRetry: () => ref.invalidate(restFloorProvider),
          data: (areas) {
            final options = <Widget>[];
            for (final a in areas) {
              final tables = a.tables.where(
                (t) =>
                    t.isActive &&
                    t.id != exclude &&
                    (onlyFree ? t.order == null : t.order != null),
              );
              if (tables.isEmpty) continue;
              options.add(
                Padding(
                  padding: const EdgeInsets.only(
                    top: Space.sm,
                    bottom: Space.xs,
                  ),
                  child: Text(
                    a.name,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              );
              options.add(
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  children: [
                    for (final t in tables)
                      OutlinedButton(
                        onPressed: () => Navigator.of(
                          context,
                        ).pop(onlyFree ? t.id : t.order!.id),
                        child: Text(
                          onlyFree
                              ? t.name
                              : '${t.name} · ${formatMoney(t.order!.amount)}',
                        ),
                      ),
                  ],
                ),
              );
            }
            if (options.isEmpty) {
              return Text(
                onlyFree ? 'No free table.' : 'No other table has an order.',
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: options,
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
