import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart' show CGate;
import '../manufacturing/mfg_widgets.dart' show MfgCard, mfgBody;
import 'wh_models.dart';
import 'wh_perms.dart';
import 'wh_repository.dart';
import 'wh_widgets.dart';

/// `/warehouse/settings`: pick order, expired stock and the warning window.
class WhSettingsScreen extends ConsumerWidget {
  const WhSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CGate(
      anyOf: const [WhPerm.manage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Warehouse settings',
            subtitle: 'Rules for picking and expiry',
          ),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(whSettingsProvider),
              onRetry: () => ref.invalidate(whSettingsProvider),
              data: (s) => mfgBody(context, [
                _Form(
                  key: ValueKey(
                    '${s.fefo}${s.blockExpired}${s.expiryWarnDays}',
                  ),
                  settings: s,
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _Form extends ConsumerStatefulWidget {
  const _Form({super.key, required this.settings});

  final WhSettings settings;

  @override
  ConsumerState<_Form> createState() => _FormState();
}

class _FormState extends ConsumerState<_Form> {
  final _key = GlobalKey<FormState>();
  late bool _fefo = widget.settings.fefo;
  late bool _block = widget.settings.blockExpired;
  late final _days = TextEditingController(
    text: '${widget.settings.expiryWarnDays}',
  );
  bool _busy = false;

  Future<void> _save() async {
    if (!_key.currentState!.validate()) return;
    setState(() => _busy = true);
    final ok = await whGuarded(
      context,
      () => ref.read(whRepositoryProvider).saveSettings({
        'fefo': _fefo,
        'blockExpired': _block,
        'expiryWarnDays': int.parse(_days.text.trim()),
      }),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.bumpWh();
      mfgToast(context, 'Settings saved.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.whCan(WhPerm.manage);
    return MfgCard(
      title: 'Rules',
      child: Form(
        key: _key,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Oldest expiry first'),
              subtitle: const Text('Off picks the oldest batch first.'),
              value: _fefo,
              onChanged: (v) => setState(() => _fefo = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Block expired stock'),
              subtitle: const Text('Picks skip expired batches.'),
              value: _block,
              onChanged: (v) => setState(() => _block = v),
            ),
            const SizedBox(height: Space.sm),
            TextFormField(
              controller: _days,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Warn before expiry (days)',
              ),
              validator: (v) {
                final n = int.tryParse(v?.trim() ?? '');
                return n == null || n < 0 || n > 3650
                    ? 'Enter 0 to 3650'
                    : null;
              },
            ),
            const SizedBox(height: Space.md),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: _busy || !canEdit ? null : _save,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
