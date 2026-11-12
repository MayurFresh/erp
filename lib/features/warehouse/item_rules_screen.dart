import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart' show CGate;
import '../items/item_picker.dart';
import '../manufacturing/bom_screen.dart' show PickerFieldBox;
import 'wh_models.dart';
import 'wh_perms.dart';
import 'wh_repository.dart';
import 'wh_widgets.dart';

const _trackingLabels = {
  'none': 'Not tracked',
  'batch': 'Track by batch and expiry',
  'serial': 'Track by serial number',
};

/// `/warehouse/rules`: per item, whether it is tracked by batch or serial and
/// which bin receives purchased stock.
class ItemRulesScreen extends ConsumerStatefulWidget {
  const ItemRulesScreen({super.key});

  @override
  ConsumerState<ItemRulesScreen> createState() => _ItemRulesScreenState();
}

class _ItemRulesScreenState extends ConsumerState<ItemRulesScreen> {
  final _form = GlobalKey<FormState>();
  final _life = TextEditingController();
  String? _itemId, _itemName;
  String _tracking = 'none';
  String? _binId;
  bool _busy = false;

  Future<void> _choose() async {
    if (_busy) return;
    final item = await pickItem(context, ref, stockOnly: true);
    if (item == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await ref.read(whRepositoryProvider).itemRule(item.id);
      if (!mounted) return;
      setState(() {
        _itemId = item.id;
        _itemName = item.name;
        _tracking = r.tracking;
        _binId = r.defaultBinId;
        _life.text = r.shelfLifeDays?.toString() ?? '';
      });
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_itemId == null) return mfgToast(context, 'Choose an item.');
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final life = int.tryParse(_life.text.trim());
    final ok = await whGuarded(
      context,
      () => ref.read(whRepositoryProvider).saveItemRule(_itemId!, {
        'tracking': _tracking,
        'shelfLifeDays': life,
        'defaultBinId': _binId,
      }),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) mfgToast(context, 'Rule saved.');
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(whLocationIdProvider);
    final canManage = ref.whCan(WhPerm.manage);
    final bins = loc == null
        ? const <WhBin>[]
        : ref
              .watch(whBinsProvider(loc))
              .maybeWhen(
                data: (b) => b.where((x) => x.isActive).toList(),
                orElse: () => const <WhBin>[],
              );
    return CGate(
      anyOf: const [WhPerm.manage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Item rules',
            subtitle: 'Batch or serial tracking and the default bin',
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                pageGutter(context),
                0,
                pageGutter(context),
                Space.xxl,
              ),
              children: [
                Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: WhLocationBar(),
                          ),
                          const SizedBox(height: Space.md),
                          PickerFieldBox(
                            label: 'Item',
                            value: _itemName,
                            onTap: _choose,
                          ),
                          const SizedBox(height: Space.md),
                          DropdownButtonFormField<String>(
                            key: ValueKey('track-$_tracking'),
                            initialValue: _tracking,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Tracking',
                            ),
                            items: [
                              for (final e in _trackingLabels.entries)
                                DropdownMenuItem(
                                  value: e.key,
                                  child: Text(e.value),
                                ),
                            ],
                            onChanged: (v) =>
                                setState(() => _tracking = v ?? 'none'),
                          ),
                          const SizedBox(height: Space.md),
                          TextFormField(
                            controller: _life,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Shelf life in days (optional)',
                            ),
                            validator: (v) {
                              final t = v?.trim() ?? '';
                              if (t.isEmpty) return null;
                              final n = int.tryParse(t);
                              return n == null || n < 1 ? 'Whole days' : null;
                            },
                          ),
                          const SizedBox(height: Space.md),
                          DropdownButtonFormField<String?>(
                            key: ValueKey('bin-$_binId-${bins.length}'),
                            initialValue: bins.any((b) => b.id == _binId)
                                ? _binId
                                : null,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Default bin for received stock',
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: null,
                                child: Text('None'),
                              ),
                              for (final b in bins)
                                DropdownMenuItem(
                                  value: b.id,
                                  child: Text(
                                    b.label,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (v) => setState(() => _binId = v),
                          ),
                          const SizedBox(height: Space.lg),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FilledButton(
                              onPressed: _busy || !canManage ? null : _save,
                              child: const Text('Save rule'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
