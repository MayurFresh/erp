import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'mfg_models.dart';
import 'mfg_perms.dart';
import 'mfg_repository.dart';
import 'mfg_widgets.dart';

/// `/manufacturing/setup`: work centres and the overhead percentage.
class MfgSetupScreen extends ConsumerWidget {
  const MfgSetupScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, WorkCentre? c, bool showCost) async {
    final saved = await showFormDialog<bool>(
      context: context,
      builder: (_) => _CentreDialog(centre: c, showCost: showCost),
    );
    if (saved == true) ref.bumpMfg();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canBom = ref.mfgCan(MfgPerm.bom);
    return CGate(
      anyOf: const [MfgPerm.bom, MfgPerm.manage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Production setup',
            actions: [
              if (canBom)
                FilledButton.icon(
                  onPressed: () => _edit(context, ref, null, true),
                  icon: const Icon(Icons.add),
                  label: const Text('Work centre'),
                ),
            ],
          ),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(mfgWorkCentresProvider),
              onRetry: () => ref.invalidate(mfgWorkCentresProvider),
              data: (centres) => mfgBody(context, [
                if (ref.mfgCan(MfgPerm.manage)) const _OverheadCard(),
                MfgCard(
                  title: 'Work centres',
                  child: centres.isEmpty
                      ? const Text('No work centres yet. Add one for each machine or work area.')
                      : Column(
                          children: [
                            for (final c in centres)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(c.name),
                                subtitle: Text(c.hourlyCost == null ? '' : '${formatMoney(c.hourlyCost)} per hour'),
                                trailing: c.isActive ? null : const StatusChip('inactive'),
                                onTap: canBom ? () => _edit(context, ref, c, c.hourlyCost != null) : null,
                              ),
                          ],
                        ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverheadCard extends ConsumerStatefulWidget {
  const _OverheadCard();

  @override
  ConsumerState<_OverheadCard> createState() => _OverheadCardState();
}

class _OverheadCardState extends ConsumerState<_OverheadCard> {
  final _c = TextEditingController();
  final _key = GlobalKey<FormState>();
  bool _loaded = false, _busy = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_key.currentState!.validate()) return;
    setState(() => _busy = true);
    final ok = await mfgGuarded(
      context,
      () => ref.read(mfgRepositoryProvider).saveOverheadPct(parseNumber(_c.text)!),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.bumpMfg();
      mfgToast(context, 'Overhead saved. New orders use it.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pct = ref.watch(mfgOverheadProvider);
    if (!_loaded && pct.hasValue) {
      _c.text = formatPlain(pct.value);
      _loaded = true;
    }
    return MfgCard(
      title: 'Overhead',
      child: Form(
        key: _key,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('A percent of material plus work centre cost, added to the cost of output. An order keeps the percent it was created with.'),
            const SizedBox(height: Space.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 160,
                  child: mfgNumberField(controller: _c, label: 'Overhead', allowZero: true, max: 500, suffix: '%'),
                ),
                const SizedBox(width: Space.md),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CentreDialog extends ConsumerStatefulWidget {
  const _CentreDialog({this.centre, required this.showCost});

  final WorkCentre? centre;
  final bool showCost;

  @override
  ConsumerState<_CentreDialog> createState() => _CentreDialogState();
}

class _CentreDialogState extends ConsumerState<_CentreDialog> {
  final _key = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.centre?.name);
  late final _cost = TextEditingController(text: formatPlain(widget.centre?.hourlyCost));
  late bool _active = widget.centre?.isActive ?? true;
  bool _busy = false;

  Future<void> _save() async {
    if (!_key.currentState!.validate()) return;
    setState(() => _busy = true);
    final body = <String, dynamic>{
      'name': _name.text.trim(),
      if (widget.showCost) 'hourlyCost': parseNumber(_cost.text) ?? 0,
      if (widget.centre != null) 'isActive': _active,
      if (widget.centre?.updatedAt != null) 'expectedUpdatedAt': widget.centre!.updatedAt,
    };
    final ok = await mfgGuarded(
      context,
      () => ref.read(mfgRepositoryProvider).saveWorkCentre(id: widget.centre?.id, body: body),
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
    title: Text(widget.centre == null ? 'New work centre' : 'Edit work centre'),
    content: SizedBox(
      width: 380,
      child: Form(
        key: _key,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (v) => requiredField(v, 'Name'),
            ),
            if (widget.showCost) ...[
              const SizedBox(height: Space.md),
              mfgNumberField(controller: _cost, label: 'Cost per hour', allowZero: true),
            ],
            if (widget.centre != null)
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
    actions: [
      TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
    ],
  );
}
