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
import 'tax_repository.dart';
import '../../widgets/busy.dart';

final _allGstRatesProvider = FutureProvider.autoDispose<List<GstRate>>((ref) {
  ref.watch(activeCompanyIdProvider);
  return ref
      .watch(taxRepositoryProvider)
      .gstRates(includeLegacy: true, date: null);
});

/// `/gst-rates`: the GST rate master, with an add dialog for `gst.manage`.
class GstRatesScreen extends ConsumerWidget {
  const GstRatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = ref.watch(permissionsProvider).can(TaxPerm.gstManage);
    final rates = ref.watch(_allGstRatesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'GST rates',
          subtitle: 'Rates valid today, plus legacy rows still in use',
          actions: [
            if (manage)
              FilledButton.icon(
                style: bigButton,
                onPressed: () async {
                  final saved = await showDialog<bool>(
                    context: context,
                    builder: (_) => const _GstRateDialog(),
                  );
                  if (saved == true) ref.invalidate(_allGstRatesProvider);
                },
                icon: const Icon(Icons.add),
                label: const Text('Add rate'),
              ),
          ],
        ),
        Expanded(
          child: AsyncValueView(
            value: rates,
            onRetry: () => ref.invalidate(_allGstRatesProvider),
            data: (rows) => rows.isEmpty
                ? const EmptyView(
                    icon: Icons.percent,
                    message: 'No GST rates found.',
                  )
                : _GstRateList(
                    rows: rows,
                    manage: manage,
                    onChanged: () => ref.invalidate(_allGstRatesProvider),
                  ),
          ),
        ),
      ],
    );
  }
}

class _GstRateList extends ConsumerWidget {
  const _GstRateList({
    required this.rows,
    required this.manage,
    required this.onChanged,
  });

  final List<GstRate> rows;
  final bool manage;
  final VoidCallback onChanged;

  String _period(GstRate r) =>
      '${formatDate(r.effectiveFrom)} – ${r.effectiveTo == null ? 'open' : formatDate(r.effectiveTo)}';

  Future<void> _end(BuildContext context, WidgetRef ref, GstRate r) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2017),
      lastDate: DateTime(2100),
      helpText: 'Last day this rate applies',
    );
    if (picked == null || !context.mounted) return;
    try {
      await runBlocking(
        context,
        () => ref.read(taxRepositoryProvider).updateGstRate(r.id, {
          'effectiveTo': apiDate(picked),
        }),
      );
      onChanged();
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Widget _badges(GstRate r) => Wrap(
    spacing: 6,
    children: [
      if (r.isLegacy) const Pill('legacy', color: Colors.orange),
      if (r.isSystem) const Pill('system', color: Colors.blueGrey),
    ],
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 720) {
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
                      columns: [
                        const DataColumn(label: Text('Rate'), numeric: true),
                        const DataColumn(label: Text('Applies to')),
                        const DataColumn(label: Text('Label')),
                        const DataColumn(label: Text('Valid')),
                        const DataColumn(label: Text('')),
                        if (manage) const DataColumn(label: Text('')),
                      ],
                      rows: [
                        for (final r in rows)
                          DataRow(
                            cells: [
                              DataCell(Text(formatPercent(r.rate))),
                              DataCell(Text(r.kind)),
                              DataCell(Text(r.label)),
                              DataCell(Text(_period(r))),
                              DataCell(_badges(r)),
                              if (manage)
                                DataCell(
                                  r.isSystem
                                      ? const SizedBox.shrink()
                                      : TextButton(
                                          onPressed: () =>
                                              _end(context, ref, r),
                                          child: const Text('End'),
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
            final r = rows[i];
            return Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                title: Text('${formatPercent(r.rate)} · ${r.kind}'),
                subtitle: Text(
                  [if (r.label.isNotEmpty) r.label, _period(r)].join('\n'),
                ),
                isThreeLine: r.label.isNotEmpty,
                trailing: Wrap(
                  spacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _badges(r),
                    if (manage && !r.isSystem)
                      TextButton(
                        onPressed: () => _end(context, ref, r),
                        child: const Text('End'),
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

class _GstRateDialog extends ConsumerStatefulWidget {
  const _GstRateDialog();

  @override
  ConsumerState<_GstRateDialog> createState() => _GstRateDialogState();
}

class _GstRateDialogState extends ConsumerState<_GstRateDialog>
    with ServerFieldErrors {
  final _form = GlobalKey<FormState>();
  final _rate = TextEditingController();
  final _label = TextEditingController();
  String _kind = 'any';
  DateTime _from = DateTime.now();
  DateTime? _to;
  bool _saving = false;

  @override
  void dispose() {
    _rate.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _pick(bool from) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (from ? _from : _to) ?? _from,
      firstDate: DateTime(2017),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => from ? _from = picked : _to = picked);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref.read(taxRepositoryProvider).createGstRate({
        'rate': parseNumber(_rate.text),
        'kind': _kind,
        'label': _label.text.trim(),
        'effectiveFrom': apiDate(_from),
        if (_to != null) 'effectiveTo': apiDate(_to!),
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
    title: const Text('Add GST rate'),
    content: SizedBox(
      width: 420,
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _rate,
                decoration: const InputDecoration(
                  labelText: 'Rate',
                  suffixText: '%',
                ),
                keyboardType: decimalKeyboard,
                inputFormatters: [decimalInput(decimals: 3, max: kMaxPercent)],
                forceErrorText: serverError('rate'),
                validator: (v) =>
                    requiredNumber(v, label: 'Rate', min: 0, max: kMaxPercent),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _kind,
                decoration: const InputDecoration(labelText: 'Applies to'),
                items: const [
                  DropdownMenuItem(
                    value: 'any',
                    child: Text('Goods and services'),
                  ),
                  DropdownMenuItem(value: 'goods', child: Text('Goods')),
                  DropdownMenuItem(value: 'services', child: Text('Services')),
                ],
                onChanged: (v) => setState(() => _kind = v ?? 'any'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _label,
                decoration: const InputDecoration(labelText: 'Label'),
                forceErrorText: serverError('label'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _pick(true),
                    icon: const Icon(Icons.event),
                    label: Text('From ${formatDate(_from)}'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _pick(false),
                    icon: const Icon(Icons.event_busy),
                    label: Text(
                      _to == null ? 'No end date' : 'To ${formatDate(_to)}',
                    ),
                  ),
                ],
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
