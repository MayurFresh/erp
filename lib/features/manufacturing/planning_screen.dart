import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart' show CGate;
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'bom_screen.dart' show PickerFieldBox;
import 'mfg_models.dart';
import 'mfg_perms.dart';
import 'mfg_repository.dart';
import 'mfg_widgets.dart';

/// `/manufacturing/planning`: raw material that open demand will run short of,
/// with a button to raise a purchase order for it.
class PlanningScreen extends ConsumerStatefulWidget {
  const PlanningScreen({super.key});

  @override
  ConsumerState<PlanningScreen> createState() => _PlanningScreenState();
}

class _PlanningScreenState extends ConsumerState<PlanningScreen> {
  final Set<String> _picked = {};

  Future<void> _raise(List<Shortage> all) async {
    final lines = all.where((s) => _picked.contains(s.itemId)).toList();
    if (lines.isEmpty) return;
    final made = await showFormDialog<String>(context: context, builder: (_) => _PoDialog(lines: lines));
    if (made != null && mounted) {
      setState(_picked.clear);
      ref.bumpMfg();
      mfgToast(context, 'Draft purchase order $made created. Find it under Purchases.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canPo = ref.mfgCan(MfgPerm.manage) && ref.mfgCan(Perm.purchaseOrdersManage);
    return CGate(
      anyOf: const [MfgPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Material planning',
            subtitle: 'Needed for open sales orders and production orders, less stock and open purchase orders',
          ),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(mfgShortagesProvider),
              onRetry: () => ref.invalidate(mfgShortagesProvider),
              data: (list) {
                if (list.isEmpty) {
                  return const EmptyView(
                    icon: Icons.check_circle_outline,
                    message: 'No shortages. Stock and open purchase orders cover the demand.',
                  );
                }
                return Column(
                  children: [
                    Expanded(
                      child: ListView.separated(
                        padding: EdgeInsets.all(pageGutter(context)),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final s = list[i];
                          return CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _picked.contains(s.itemId),
                            onChanged: canPo
                                ? (v) => setState(() => v == true ? _picked.add(s.itemId) : _picked.remove(s.itemId))
                                : null,
                            title: Text(s.name),
                            subtitle: Text(
                              'Need ${formatQty(s.required)} · in stock ${formatQty(s.onHand)} · on order ${formatQty(s.onOrder)}',
                            ),
                            secondary: Text(
                              'Short ${qtyUnit(s.shortage, s.unit)}',
                              style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.error),
                            ),
                          );
                        },
                      ),
                    ),
                    if (canPo)
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: EdgeInsets.all(pageGutter(context)),
                          child: Wrap(
                            spacing: Space.sm,
                            runSpacing: Space.sm,
                            alignment: WrapAlignment.spaceBetween,
                            children: [
                              TextButton(
                                onPressed: () => setState(() {
                                  _picked
                                    ..clear()
                                    ..addAll(list.map((s) => s.itemId));
                                }),
                                child: const Text('Select all'),
                              ),
                              FilledButton(
                                onPressed: _picked.isEmpty ? null : () => _raise(list),
                                child: Text('Create purchase order (${_picked.length})'),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PoDialog extends ConsumerStatefulWidget {
  const _PoDialog({required this.lines});

  final List<Shortage> lines;

  @override
  ConsumerState<_PoDialog> createState() => _PoDialogState();
}

class _PoDialogState extends ConsumerState<_PoDialog> {
  final _key = GlobalKey<FormState>();
  Party? _vendor;
  String? _locationId;
  late final _qty = [for (final s in widget.lines) TextEditingController(text: formatPlain(s.shortage))];
  bool _busy = false;

  Future<void> _save() async {
    if (!_key.currentState!.validate()) return;
    if (_vendor == null) {
      mfgError(context, 'Choose a vendor.');
      return;
    }
    setState(() => _busy = true);
    String? number;
    final ok = await mfgGuarded(context, () async {
      final Json r = await ref.read(mfgRepositoryProvider).createPurchaseOrder({
        'partyId': _vendor!.id,
        'locationId': _locationId,
        'lines': [
          for (var i = 0; i < widget.lines.length; i++) {'itemId': widget.lines[i].itemId, 'qty': parseNumber(_qty[i].text)},
        ],
      });
      number = asString(r['number'], 'created');
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(number);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Create purchase order'),
    content: SizedBox(
      width: 440,
      child: Form(
        key: _key,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PickerFieldBox(
                label: 'Vendor',
                value: _vendor?.name,
                onTap: () async {
                  final p = await pickParty(context, ref, type: PartyType.vendor);
                  if (p != null) setState(() => _vendor = p);
                },
              ),
              const SizedBox(height: Space.md),
              MfgLocationField(value: _locationId, onChanged: (v) => setState(() => _locationId = v), label: 'Deliver to'),
              const SizedBox(height: Space.md),
              for (var i = 0; i < widget.lines.length; i++) ...[
                mfgNumberField(controller: _qty[i], label: widget.lines[i].name, suffix: widget.lines[i].unit),
                const SizedBox(height: Space.md),
              ],
              const Text('The order is saved as a draft for you to review.'),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('Create')),
    ],
  );
}
