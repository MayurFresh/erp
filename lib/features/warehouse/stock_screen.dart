import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../construction/common/c_widgets.dart' show CGate;
import '../items/item_picker.dart';
import '../manufacturing/mfg_widgets.dart' show MfgCard, MfgKv;
import 'stock_dialogs.dart';
import 'wh_models.dart';
import 'wh_perms.dart';
import 'wh_repository.dart';
import 'wh_widgets.dart';

String _qty(WhStockRow r) => '${formatQty(r.qty)} ${r.unit}'.trim();
String _expiry(WhStockRow r) =>
    r.expiryDate == null ? '' : 'exp ${formatDate(r.expiryDate)}';

/// `/warehouse`: stock by bin and batch, with receipt and put-away.
class WarehouseStockScreen extends ConsumerStatefulWidget {
  const WarehouseStockScreen({super.key});

  @override
  ConsumerState<WarehouseStockScreen> createState() =>
      _WarehouseStockScreenState();
}

class _WarehouseStockScreenState extends ConsumerState<WarehouseStockScreen> {
  String? _itemId;
  String? _itemName;

  Future<void> _dialog(
    String loc,
    Widget Function(List<WhBin> bins) build,
  ) async {
    final bins = await ref.read(whBinsProvider(loc).future);
    if (!mounted) return;
    final done = await showFormDialog<bool>(
      context: context,
      builder: (_) => build(bins),
    );
    if (done == true) ref.bumpWh();
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(whLocationIdProvider);
    final canPick = ref.whCan(WhPerm.pick);
    return CGate(
      anyOf: const [WhPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Warehouse stock',
            subtitle: 'What sits in each bin and batch',
            actions: [
              if (canPick && loc != null) ...[
                OutlinedButton(
                  onPressed: () => _dialog(
                    loc,
                    (b) => ReceiveDialog(locationId: loc, bins: b),
                  ),
                  child: const Text('Receive'),
                ),
                FilledButton(
                  onPressed: () => _dialog(
                    loc,
                    (b) => PutawayDialog(locationId: loc, bins: b),
                  ),
                  child: const Text('Put away'),
                ),
              ],
            ],
          ),
          FilterBar(
            children: [
              Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const WhLocationBar(),
                  if (_itemId == null)
                    OutlinedButton.icon(
                      onPressed: () async {
                        final item = await pickItem(
                          context,
                          ref,
                          stockOnly: true,
                        );
                        if (item != null) {
                          setState(() {
                            _itemId = item.id;
                            _itemName = item.name;
                          });
                        }
                      },
                      icon: const Icon(Icons.search),
                      label: const Text('Filter by item'),
                    )
                  else
                    InputChip(
                      label: Text(_itemName ?? 'Item'),
                      onDeleted: () => setState(() => _itemId = null),
                    ),
                ],
              ),
            ],
          ),
          Expanded(
            child: loc == null
                ? const EmptyView(
                    icon: Icons.warehouse_outlined,
                    message: 'Add a location first.',
                  )
                : AsyncValueView(
                    value: ref.watch(whStockProvider('$loc|${_itemId ?? ''}')),
                    onRetry: () => ref.invalidate(
                      whStockProvider('$loc|${_itemId ?? ''}'),
                    ),
                    data: (s) => _body(loc, s, canPick),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _body(String loc, WhStock s, bool canPick) {
    final sum = s.summary;
    final table = s.rows.isEmpty
        ? const EmptyView(
            icon: Icons.inventory_2_outlined,
            message: 'Nothing is kept in bins here yet.',
          )
        : WhTable<WhStockRow>(
            rows: s.rows,
            onTap: canPick
                ? (r) => _dialog(
                    loc,
                    (b) => PutawayDialog(locationId: loc, bins: b, row: r),
                  )
                : null,
            columns: [
              WhCol('Item', (r) => r.itemName, flex: 3),
              WhCol('Bin', (r) => r.binCode ?? 'No bin'),
              WhCol('Batch', (r) => r.batchNo ?? ''),
              WhCol(
                'Expiry',
                (r) => r.expiryDate == null
                    ? ''
                    : '${formatDate(r.expiryDate)}${r.expired ? ' (expired)' : ''}',
              ),
              WhCol('Quantity', _qty, end: true),
            ],
            card: (context, r) => whCardBody(
              context,
              r.itemName,
              [
                'Bin ${r.binCode ?? 'none'}${r.batchNo != null ? ' · batch ${r.batchNo}' : ''}',
                _expiry(r),
                _qty(r),
              ],
              trailing: r.expired
                  ? const StatusChip('expired', tone: StatusTone.danger)
                  : null,
            ),
          );
    if (sum == null) return table;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            pageGutter(context),
            0,
            pageGutter(context),
            Space.sm,
          ),
          child: MfgCard(
            title: _itemName ?? 'Item',
            child: Column(
              children: [
                MfgKv('On hand at this location', formatQty(sum.onHand)),
                MfgKv('In bins', formatQty(sum.tagged)),
                MfgKv(
                  'Not yet put away',
                  formatQty(sum.unassigned),
                  bold: true,
                ),
              ],
            ),
          ),
        ),
        Expanded(child: table),
      ],
    );
  }
}
