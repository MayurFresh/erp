import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../compliance/tax_perms.dart';
import '../construction/common/c_widgets.dart' show bigButton;
import 'tax_models.dart';
import 'tax_pickers.dart';
import 'tax_repository.dart';
import '../../widgets/busy.dart';

final _allTdsProvider = FutureProvider.autoDispose<List<TdsSection>>((ref) {
  ref.watch(activeCompanyIdProvider);
  return ref.watch(taxRepositoryProvider).tdsSections();
});

/// `/tds-sections`: the TDS section master, with add for `tds.manage`.
class TdsSectionsScreen extends ConsumerWidget {
  const TdsSectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = ref.watch(permissionsProvider).can(TaxPerm.tdsManage);
    final sections = ref.watch(_allTdsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'TDS sections',
          subtitle: 'Rates and thresholds used when deducting TDS',
          actions: [
            if (manage)
              FilledButton.icon(
                style: bigButton,
                onPressed: () async {
                  final saved = await showDialog<bool>(
                    context: context,
                    builder: (_) => const _TdsDialog(),
                  );
                  if (saved == true) ref.invalidate(_allTdsProvider);
                },
                icon: const Icon(Icons.add),
                label: const Text('Add section'),
              ),
          ],
        ),
        Expanded(
          child: AsyncValueView(
            value: sections,
            onRetry: () => ref.invalidate(_allTdsProvider),
            data: (rows) => rows.isEmpty
                ? const EmptyView(
                    icon: Icons.receipt_long_outlined,
                    message: 'No TDS sections found.',
                  )
                : _TdsList(
                    rows: rows,
                    manage: manage,
                    onChanged: () => ref.invalidate(_allTdsProvider),
                  ),
          ),
        ),
      ],
    );
  }
}

String _rates(TdsSection s) =>
    '${formatPercent(s.rateIndividual)} / ${formatPercent(s.rateOther)} / '
    '${formatPercent(s.rateNoPan)}';

String _threshold(TdsSection s) {
  final parts = [
    if (s.thresholdSingle != null) '${formatMoney(s.thresholdSingle)} single',
    if (s.thresholdAggregate != null)
      '${formatMoney(s.thresholdAggregate)} yearly'
          '${s.aggregateMode == 'excess' ? ' (excess)' : ''}',
  ];
  return parts.isEmpty ? 'None' : parts.join(' · ');
}

class _TdsList extends ConsumerWidget {
  const _TdsList({
    required this.rows,
    required this.manage,
    required this.onChanged,
  });

  final List<TdsSection> rows;
  final bool manage;
  final VoidCallback onChanged;

  Future<void> _toggle(
    BuildContext context,
    WidgetRef ref,
    TdsSection s,
  ) async {
    try {
      await runBlocking(
        context,
        () => ref.read(taxRepositoryProvider).updateTdsSection(s.id, {
          'isActive': !s.isActive,
        }),
      );
      onChanged();
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Widget _flags(TdsSection s) => Wrap(
    spacing: 6,
    children: [
      if (!s.verified) const UnverifiedBadge(),
      if (!s.isActive) const Pill('inactive', color: Colors.grey),
    ],
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 820) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              Card(
                margin: EdgeInsets.zero,
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: c.maxWidth - 32),
                    child: DataTable(
                      columnSpacing: 24,
                      columns: [
                        const DataColumn(label: Text('Section')),
                        const DataColumn(label: Text('Name')),
                        const DataColumn(
                          label: Text('Rate: indiv / other / no PAN'),
                        ),
                        const DataColumn(label: Text('Threshold')),
                        const DataColumn(label: Text('')),
                        if (manage && rows.any((r) => !r.isSystem))
                          const DataColumn(label: Text('')),
                      ],
                      rows: [
                        for (final s in rows)
                          DataRow(
                            cells: [
                              DataCell(Text(s.code)),
                              DataCell(
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 280,
                                  ),
                                  child: Text(
                                    s.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              DataCell(Text(_rates(s))),
                              DataCell(Text(_threshold(s))),
                              DataCell(_flags(s)),
                              if (manage && rows.any((r) => !r.isSystem))
                                DataCell(
                                  s.isSystem
                                      ? const SizedBox.shrink()
                                      : TextButton(
                                          onPressed: () =>
                                              _toggle(context, ref, s),
                                          child: Text(
                                            s.isActive
                                                ? 'Deactivate'
                                                : 'Activate',
                                          ),
                                        ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          itemCount: rows.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final s = rows[i];
            return Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            s.code,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        _flags(s),
                      ],
                    ),
                    Text(s.name),
                    const SizedBox(height: 4),
                    Text('Rate: ${_rates(s)}'),
                    Text('Threshold: ${_threshold(s)}'),
                    if (manage && !s.isSystem)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => _toggle(context, ref, s),
                          child: Text(s.isActive ? 'Deactivate' : 'Activate'),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _TdsDialog extends ConsumerStatefulWidget {
  const _TdsDialog();

  @override
  ConsumerState<_TdsDialog> createState() => _TdsDialogState();
}

class _TdsDialogState extends ConsumerState<_TdsDialog> with ServerFieldErrors {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _newRef = TextEditingController();
  final _name = TextEditingController();
  final _rateInd = TextEditingController();
  final _rateOther = TextEditingController();
  final _rateNoPan = TextEditingController();
  final _single = TextEditingController();
  final _aggregate = TextEditingController();
  String _mode = 'whole';
  DateTime _from = DateTime.now();
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [
      _code,
      _newRef,
      _name,
      _rateInd,
      _rateOther,
      _rateNoPan,
      _single,
      _aggregate,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _num(
    TextEditingController c,
    String label,
    String field, {
    bool required = false,
    String? suffix,
  }) {
    return TextFormField(
      controller: c,
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        prefixText: suffix == null ? '₹ ' : null,
      ),
      keyboardType: decimalKeyboard,
      inputFormatters: [decimalInput()],
      forceErrorText: serverError(field),
      onChanged: (_) => clearServerError(field),
      validator: (v) => required
          ? requiredNumber(v, label: label, min: 0)
          : optionalNumber(v, min: 0),
    );
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref.read(taxRepositoryProvider).createTdsSection({
        'code': _code.text.trim(),
        'newRef': trimmedOrNull(_newRef.text),
        'name': _name.text.trim(),
        'rateIndividual': parseNumber(_rateInd.text),
        'rateOther': parseNumber(_rateOther.text),
        'rateNoPan': parseNumber(_rateNoPan.text),
        'thresholdSingle': parseNumber(_single.text),
        'thresholdAggregate': parseNumber(_aggregate.text),
        'aggregateMode': _mode,
        'effectiveFrom': apiDate(_from),
        'effectiveTo': null,
        'verified': false,
        'isActive': true,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add TDS section'),
    content: SizedBox(
      width: 460,
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FormRow(
                children: [
                  TextFormField(
                    controller: _code,
                    decoration: const InputDecoration(
                      labelText: 'Code (e.g. 194C)',
                    ),
                    forceErrorText: serverError('code'),
                    validator: (v) => requiredField(v, 'Code'),
                  ),
                  TextFormField(
                    controller: _newRef,
                    decoration: const InputDecoration(labelText: 'New Act ref'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
                forceErrorText: serverError('name'),
                validator: (v) => requiredField(v, 'Name'),
              ),
              const SizedBox(height: 12),
              FormRow(
                children: [
                  _num(
                    _rateInd,
                    'Individual / HUF',
                    'rateIndividual',
                    required: true,
                    suffix: '%',
                  ),
                  _num(
                    _rateOther,
                    'Others',
                    'rateOther',
                    required: true,
                    suffix: '%',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _num(
                _rateNoPan,
                'No PAN',
                'rateNoPan',
                required: true,
                suffix: '%',
              ),
              const SizedBox(height: 12),
              FormRow(
                children: [
                  _num(_single, 'Single threshold', 'thresholdSingle'),
                  _num(_aggregate, 'Yearly threshold', 'thresholdAggregate'),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _mode,
                decoration: const InputDecoration(
                  labelText: 'Yearly threshold mode',
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'whole',
                    child: Text('Whole amount once crossed'),
                  ),
                  DropdownMenuItem(
                    value: 'excess',
                    child: Text('Only the excess'),
                  ),
                ],
                onChanged: (v) => setState(() => _mode = v ?? 'whole'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final p = await showDatePicker(
                    context: context,
                    initialDate: _from,
                    firstDate: DateTime(2017),
                    lastDate: DateTime(2100),
                  );
                  if (p != null) setState(() => _from = p);
                },
                icon: const Icon(Icons.event),
                label: Text('Effective from ${formatDate(_from)}'),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      BusyButton(busy: _saving, onPressed: _save, label: 'Add'),
    ],
  );
}
