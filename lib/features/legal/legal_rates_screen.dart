import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart' show CGate, showSuccess;
import 'legal_repository.dart';

final legalRatesProvider =
    FutureProvider.autoDispose<List<(String, String, double?)>>((ref) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(legalRevisionProvider);
      return ref.watch(legalRepositoryProvider).rates();
    });

/// `/legal/rates`: the hourly rate of each person. Time entries use it when
/// no rate is typed; without one the matter's own rate applies.
class LegalRatesScreen extends ConsumerWidget {
  const LegalRatesScreen({super.key});

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    (String, String, double?) row,
  ) async {
    final saved = await showFormDialog<double>(
      context: context,
      builder: (_) => _RateDialog(userId: row.$1, name: row.$2, rate: row.$3),
    );
    if (saved == null) return;
    ref.bumpLegal();
    if (context.mounted) showSuccess(context, 'Rate saved');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rates = ref.watch(legalRatesProvider);
    final gutter = pageGutter(context);
    return CGate(
      anyOf: const [Perm.legalManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Rate card'),
          Expanded(
            child: AsyncValueView<List<(String, String, double?)>>(
              value: rates,
              onRetry: () => ref.invalidate(legalRatesProvider),
              data: (list) => ListView(
                padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Hourly rate by person. It is used for time entries when no rate is typed. Without one, the matter rate applies.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  for (final r in list)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        key: ValueKey('rate-${r.$1}'),
                        title: Text(r.$2),
                        subtitle: Text(
                          r.$3 == null
                              ? 'No rate set'
                              : '${formatMoney(r.$3!)} per hour',
                        ),
                        trailing: const Icon(Icons.edit_outlined),
                        onTap: () => _edit(context, ref, r),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RateDialog extends ConsumerStatefulWidget {
  const _RateDialog({required this.userId, required this.name, this.rate});

  final String userId;
  final String name;
  final double? rate;

  @override
  ConsumerState<_RateDialog> createState() => _RateDialogState();
}

class _RateDialogState extends ConsumerState<_RateDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _rate = TextEditingController(
    text: widget.rate == null ? null : formatPlain(widget.rate),
  );
  bool _saving = false;

  @override
  void dispose() {
    _rate.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final v = parseNumber(_rate.text)!;
    setState(() => _saving = true);
    try {
      await ref.read(legalRepositoryProvider).setRate(widget.userId, v);
      if (mounted) Navigator.of(context).pop(v);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showErrorSnackBar(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.name),
    content: SizedBox(
      width: 360,
      child: Form(
        key: _formKey,
        child: TextFormField(
          controller: _rate,
          autofocus: true,
          keyboardType: decimalKeyboard,
          inputFormatters: [decimalInput()],
          decoration: InputDecoration(
            labelText: 'Hourly rate',
            prefixText: '$moneySymbol ',
          ),
          validator: (v) => requiredNumber(v, label: 'Rate', min: 0),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: const Text('Save'),
      ),
    ],
  );
}
