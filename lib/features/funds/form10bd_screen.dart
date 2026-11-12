import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../compliance/compliance_widgets.dart' show shareText;
import '../construction/common/c_widgets.dart'
    show CGate, DateField, bigButton, showSuccess;
import 'funds_models.dart';
import 'funds_repository.dart';
import 'funds_widgets.dart';

final _form10bdProvider = FutureProvider.autoDispose.family<Form10bd, String>((
  ref,
  fy,
) {
  ref.watch(fundsRevisionProvider);
  return ref.watch(fundsRepositoryProvider).form10bd(fy);
});

/// `/donations/10bd`: Form 10BD data for a year, and the 80G registration details.
class Form10bdScreen extends ConsumerStatefulWidget {
  const Form10bdScreen({super.key});

  @override
  ConsumerState<Form10bdScreen> createState() => _Form10bdScreenState();
}

class _Form10bdScreenState extends ConsumerState<Form10bdScreen> {
  late String _fy = currentFy();

  Future<void> _csv() async {
    try {
      final text = await ref.read(fundsRepositoryProvider).form10bdCsv(_fy);
      if (mounted) await shareText(context, text, 'Form 10BD CSV');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _settings() async {
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (_) => const Reg80gDialog(),
    );
    if (ok == true && mounted) {
      ref.bumpFunds();
      showSuccess(context, '80G details saved');
    }
  }

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(Perm.donationsManage);
    return CGate(
      anyOf: const [Perm.donationsManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Form 10BD',
            actions: [
              FySelector(value: _fy, onChanged: (v) => setState(() => _fy = v)),
              if (manage)
                OutlinedButton(
                  style: bigButton,
                  onPressed: _settings,
                  child: const Text('80G details'),
                ),
              FilledButton(
                key: const ValueKey('copy-csv'),
                style: bigButton,
                onPressed: _csv,
                child: const Text('Copy CSV'),
              ),
            ],
          ),
          Expanded(
            child: AsyncValueView<Form10bd>(
              value: ref.watch(_form10bdProvider(_fy)),
              onRetry: () => ref.invalidate(_form10bdProvider(_fy)),
              data: (f) => Gutter(
                children: [
                  SoftNote(f.note),
                  if (f.skipped.isNotEmpty)
                    SoftNote(
                      'Left out because the donor has no PAN or Aadhaar:\n${f.skipped.join('\n')}',
                      danger: true,
                    ),
                  SectionCard(
                    title:
                        '${f.rows.length} donation${f.rows.length == 1 ? '' : 's'}, ${formatAmount(f.total)}',
                    child: f.rows.isEmpty
                        ? const Text('No eligible 80G donations in this year.')
                        : SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: DataTable(
                              columnSpacing: 18,
                              columns: [
                                for (final h in f.header)
                                  DataColumn(label: Text(h)),
                              ],
                              rows: [
                                for (final r in f.rows)
                                  DataRow(
                                    cells: [
                                      for (final c in r) DataCell(Text(c)),
                                    ],
                                  ),
                              ],
                            ),
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

/// 80G registration number and validity, trust PAN and the receipt footer.
class Reg80gDialog extends ConsumerStatefulWidget {
  const Reg80gDialog({super.key});

  @override
  ConsumerState<Reg80gDialog> createState() => _Reg80gDialogState();
}

class _Reg80gDialogState extends ConsumerState<Reg80gDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _no = TextEditingController();
  final _pan = TextEditingController();
  final _footer = TextEditingController();
  DateTime? _from;
  DateTime? _to;
  bool _loaded = false;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_no, _pan, _footer]) {
      c.dispose();
    }
    super.dispose();
  }

  void _load(FundsSettings s) {
    if (_loaded) return;
    _loaded = true;
    _no.text = s.reg80gNo ?? '';
    _pan.text = s.trustPan ?? '';
    _footer.text = s.receiptFooter ?? '';
    _from = DateTime.tryParse(s.reg80gFrom ?? '');
    _to = DateTime.tryParse(s.reg80gTo ?? '');
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      await ref.read(fundsRepositoryProvider).saveSettings({
        'reg80gNo': _no.text.trim(),
        'reg80gFrom': _from == null ? '' : apiDate(_from!),
        'reg80gTo': _to == null ? '' : apiDate(_to!),
        'trustPan': _pan.text.trim().toUpperCase(),
        'receiptFooter': _footer.text.trim(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(fundsSettingsProvider);
    if (s.hasValue) _load(s.requireValue);
    return AlertDialog(
      title: const Text('80G details'),
      content: SizedBox(
        width: 520,
        child: !_loaded
            ? const SizedBox(height: 120, child: LoadingView())
            : SingleChildScrollView(
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _no,
                        decoration: InputDecoration(
                          labelText: '80G registration number',
                          errorText: serverError('reg80gNo'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FormRow(
                        minCellWidth: 180,
                        children: [
                          DateField(
                            label: 'Valid from',
                            value: _from,
                            onChanged: (d) => setState(() => _from = d),
                            onCleared: () => setState(() => _from = null),
                          ),
                          DateField(
                            label: 'Valid to',
                            value: _to,
                            errorText: serverError('reg80gTo'),
                            lastDate: DateTime(2100),
                            onChanged: (d) => setState(() => _to = d),
                            onCleared: () => setState(() => _to = null),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _pan,
                        textCapitalization: TextCapitalization.characters,
                        decoration: InputDecoration(
                          labelText: 'Trust PAN',
                          errorText: serverError('trustPan'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _footer,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'Receipt footer (optional)',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        BusyButton(
          busy: _saving,
          onPressed: _saving || !_loaded ? null : _save,
          label: 'Save',
        ),
      ],
    );
  }
}
