import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'wh_models.dart';
import 'wh_perms.dart';
import 'wh_repository.dart';
import 'wh_widgets.dart';

/// `/warehouse/serials`: find a serial number and see where it is.
class SerialsScreen extends ConsumerStatefulWidget {
  const SerialsScreen({super.key});

  @override
  ConsumerState<SerialsScreen> createState() => _SerialsScreenState();
}

class _SerialsScreenState extends ConsumerState<SerialsScreen> {
  final _search = TextEditingController();
  String _q = '';
  String _status = '';

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(whLocationIdProvider);
    final bins = loc == null
        ? const <WhBin>[]
        : ref.watch(whBinsProvider(loc)).value ?? const <WhBin>[];
    String binOf(WhSerial s) =>
        bins.where((b) => b.id == s.binId).map((b) => b.code).firstOrNull ?? '';
    String where(WhSerial s) => s.status == 'issued'
        ? 'Issued${s.issuedRef != null ? ' (${s.issuedRef})' : ''}'
        : (binOf(s).isEmpty ? 'Not in a bin' : 'Bin ${binOf(s)}');
    String warranty(WhSerial s) => s.warrantyUntil == null
        ? ''
        : 'Warranty to ${formatDate(s.warrantyUntil)}';
    return CGate(
      anyOf: const [WhPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Serial numbers',
            subtitle: 'Where each unit is',
          ),
          FilterBar(
            children: [
              Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const WhLocationBar(),
                  SizedBox(
                    width: 260,
                    child: TextField(
                      controller: _search,
                      decoration: const InputDecoration(
                        labelText: 'Serial number',
                        prefixIcon: Icon(Icons.search),
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (v) => setState(() => _q = v.trim()),
                    ),
                  ),
                  for (final s in const [
                    ('', 'All'),
                    ('in_stock', 'In stock'),
                    ('issued', 'Issued'),
                  ])
                    ChoiceChip(
                      label: Text(s.$2),
                      selected: _status == s.$1,
                      onSelected: (_) => setState(() => _status = s.$1),
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
                    value: ref.watch(whSerialsProvider('$loc|$_status|$_q')),
                    onRetry: () =>
                        ref.invalidate(whSerialsProvider('$loc|$_status|$_q')),
                    data: (list) => list.isEmpty
                        ? const EmptyView(
                            icon: Icons.qr_code_2,
                            message: 'No serial numbers match.',
                          )
                        : WhTable<WhSerial>(
                            rows: list,
                            columns: [
                              WhCol('Serial', (s) => s.serialNo, flex: 2),
                              WhCol('Item', (s) => s.itemName, flex: 3),
                              WhCol('Where', where, flex: 2),
                              WhCol('Warranty', warranty, flex: 2),
                              WhCol(
                                'Status',
                                (s) => s.status == 'issued'
                                    ? 'Issued'
                                    : 'In stock',
                              ),
                            ],
                            card: (context, s) => whCardBody(
                              context,
                              s.serialNo,
                              [s.itemName, where(s), warranty(s)],
                              trailing: StatusChip(
                                s.status,
                                label: s.status == 'issued'
                                    ? 'Issued'
                                    : 'In stock',
                                tone: s.status == 'issued'
                                    ? StatusTone.neutral
                                    : StatusTone.success,
                              ),
                            ),
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}
