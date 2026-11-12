import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'wh_models.dart';
import 'wh_perms.dart';
import 'wh_repository.dart';
import 'wh_widgets.dart';

String _cap(WhBin b) => b.capacityQty == null
    ? '${formatQty(b.heldQty)} held'
    : '${formatQty(b.heldQty)} of ${formatQty(b.capacityQty)}';

/// `/warehouse/bins`: bins of one location, with capacity and quarantine.
class BinsScreen extends ConsumerWidget {
  const BinsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = ref.watch(whLocationIdProvider);
    final canManage = ref.whCan(WhPerm.manage);
    return CGate(
      anyOf: const [WhPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Bins',
            subtitle: 'Places inside a location where stock is kept',
            actions: [
              if (canManage && loc != null)
                FilledButton.icon(
                  onPressed: () => _edit(context, ref, null, loc),
                  icon: const Icon(Icons.add),
                  label: const Text('New bin'),
                ),
            ],
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              pageGutter(context),
              0,
              pageGutter(context),
              Space.sm,
            ),
            child: const Align(
              alignment: Alignment.centerLeft,
              child: WhLocationBar(),
            ),
          ),
          Expanded(
            child: loc == null
                ? const EmptyView(
                    icon: Icons.warehouse_outlined,
                    message: 'Add a location first.',
                  )
                : AsyncValueView(
                    value: ref.watch(whBinsProvider(loc)),
                    onRetry: () => ref.invalidate(whBinsProvider(loc)),
                    data: (bins) => bins.isEmpty
                        ? const EmptyView(
                            icon: Icons.warehouse_outlined,
                            message: 'No bins in this location yet.',
                          )
                        : WhTable<WhBin>(
                            rows: bins,
                            onTap: canManage
                                ? (b) => _edit(context, ref, b, loc)
                                : null,
                            columns: [
                              WhCol('Code', (b) => b.code),
                              WhCol('Name', (b) => b.name ?? ''),
                              WhCol('Zone', (b) => b.zone ?? ''),
                              WhCol('Kind', (b) => whKindLabel(b.kind)),
                              WhCol('Stock', _cap, end: true),
                              WhCol(
                                'Status',
                                (b) => b.isActive ? 'Active' : 'Off',
                              ),
                            ],
                            card: (context, b) => whCardBody(
                              context,
                              b.label,
                              [
                                [
                                  if (b.zone != null && b.zone!.isNotEmpty)
                                    'Zone ${b.zone}',
                                  whKindLabel(b.kind),
                                ].join(' · '),
                                _cap(b),
                              ],
                              trailing: b.isActive
                                  ? (b.isQuarantine
                                        ? const StatusChip(
                                            'quarantine',
                                            tone: StatusTone.warning,
                                          )
                                        : null)
                                  : const StatusChip('off'),
                            ),
                          ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    WhBin? bin,
    String locationId,
  ) async {
    final done = await showFormDialog<bool>(
      context: context,
      builder: (_) => BinDialog(bin: bin, locationId: locationId),
    );
    if (done == true) ref.bumpWh();
  }
}

class BinDialog extends ConsumerStatefulWidget {
  const BinDialog({super.key, this.bin, required this.locationId});

  final WhBin? bin;
  final String locationId;

  @override
  ConsumerState<BinDialog> createState() => _BinDialogState();
}

class _BinDialogState extends ConsumerState<BinDialog> {
  final _key = GlobalKey<FormState>();
  late final _code = TextEditingController(text: widget.bin?.code);
  late final _name = TextEditingController(text: widget.bin?.name);
  late final _zone = TextEditingController(text: widget.bin?.zone);
  late final _cap = TextEditingController(
    text: widget.bin?.capacityQty == null
        ? ''
        : formatQty(widget.bin!.capacityQty),
  );
  late String _kind = widget.bin?.kind ?? 'storage';
  late bool _active = widget.bin?.isActive ?? true;
  bool _busy = false;

  Future<void> _save() async {
    if (!_key.currentState!.validate()) return;
    setState(() => _busy = true);
    final cap = parseNumber(_cap.text.trim());
    final Json body = {
      'code': _code.text.trim(),
      'name': _name.text.trim().isEmpty ? null : _name.text.trim(),
      'zone': _zone.text.trim().isEmpty ? null : _zone.text.trim(),
      'kind': _kind,
      'capacityQty': cap,
    };
    if (widget.bin == null) {
      body['locationId'] = widget.locationId;
    } else {
      body['isActive'] = _active;
      body['expectedUpdatedAt'] = widget.bin!.updatedAt;
    }
    final ok = await whGuarded(
      context,
      () => ref
          .read(whRepositoryProvider)
          .saveBin(id: widget.bin?.id, body: body),
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.bin == null ? 'New bin' : 'Edit bin'),
    content: SizedBox(
      width: 440,
      child: Form(
        key: _key,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _code,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Code'),
                validator: (v) => requiredField(v, 'Code'),
              ),
              const SizedBox(height: Space.md),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name (optional)'),
              ),
              const SizedBox(height: Space.md),
              TextFormField(
                controller: _zone,
                decoration: const InputDecoration(labelText: 'Zone (optional)'),
              ),
              const SizedBox(height: Space.md),
              DropdownButtonFormField<String>(
                initialValue: _kind,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Kind'),
                items: [
                  for (final k in whBinKinds)
                    DropdownMenuItem(value: k.$1, child: Text(k.$2)),
                ],
                onChanged: (v) => setState(() => _kind = v ?? 'storage'),
              ),
              const SizedBox(height: Space.md),
              mfgNumberField(
                controller: _cap,
                label: 'Capacity (optional)',
                required: false,
              ),
              if (widget.bin != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
    ],
  );
}
