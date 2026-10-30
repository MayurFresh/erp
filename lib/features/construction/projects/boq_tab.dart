import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../widgets/form_support.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../models/boq_paste.dart';
import '../models/project_models.dart';

/// BOQ lines of a project: table on wide screens, cards on phones. With
/// `boq.manage`: add, edit, delete and bulk paste.
class BoqTab extends ConsumerWidget {
  const BoqTab({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final canManage = perms.can(CPerm.boqManage);
    final boq = ref.watch(boqProvider(projectId));

    Future<void> edit([BoqLine? line]) => showFormSheet<void>(
      context,
      title: line == null ? 'Add BOQ line' : 'Edit ${line.code}',
      builder: (_) => BoqLineForm(projectId: projectId, original: line),
    );

    Future<void> paste() => showFormSheet<void>(
      context,
      title: 'Paste BOQ from a spreadsheet',
      maxWidth: 900,
      builder: (_) => BoqPasteForm(projectId: projectId),
    );

    return AsyncValueView(
      value: boq,
      onRetry: () => ref.invalidate(boqProvider(projectId)),
      data: (lines) {
        final total = lines.fold(0.0, (sum, l) => sum + l.amount);
        final header = Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Text(
                '${lines.length} lines · ${formatMoney(total)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (canManage)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      style: bigButton,
                      onPressed: edit,
                      icon: const Icon(Icons.add),
                      label: const Text('Add line'),
                    ),
                    OutlinedButton.icon(
                      style: bigOutlinedButton,
                      onPressed: paste,
                      icon: const Icon(Icons.content_paste),
                      label: const Text('Paste from spreadsheet'),
                    ),
                  ],
                ),
            ],
          ),
        );
        if (lines.isEmpty) {
          return ListView(
            children: [
              header,
              const SizedBox(
                height: 240,
                child: EmptyView(
                  icon: Icons.list_alt_outlined,
                  message: 'No BOQ lines yet.',
                ),
              ),
            ],
          );
        }
        return RefreshIndicator(
          onRefresh: () => ref.refresh(boqProvider(projectId).future),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 720) {
                return ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    header,
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Card(
                        margin: EdgeInsets.zero,
                        clipBehavior: Clip.antiAlias,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minWidth: constraints.maxWidth - 32,
                            ),
                            child: _BoqTable(
                              lines: lines,
                              onTap: canManage ? edit : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }
              return ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
                itemCount: lines.length + 1,
                separatorBuilder: (_, i) => SizedBox(height: i == 0 ? 0 : 8),
                itemBuilder: (context, i) {
                  if (i == 0) return header;
                  final l = lines[i - 1];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: CListCard(
                      onTap: canManage ? () => edit(l) : null,
                      title: l.label,
                      trailing: formatMoney(l.amount),
                      subtitle:
                          '${formatQty(l.qty)} ${l.unit} × ${formatMoney(l.rate)}',
                      details: ['Done ${formatQty(l.executedQty)} ${l.unit}'],
                      progress: l.progressPct,
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}

class _BoqTable extends StatelessWidget {
  const _BoqTable({required this.lines, this.onTap});

  final List<BoqLine> lines;
  final void Function(BoqLine)? onTap;

  @override
  Widget build(BuildContext context) {
    final tap = onTap;
    return DataTable(
      showCheckboxColumn: false,
      columnSpacing: 20,
      horizontalMargin: 16,
      dataRowMinHeight: 52,
      dataRowMaxHeight: 64,
      columns: const [
        DataColumn(label: Text('Code')),
        DataColumn(label: Text('Description')),
        DataColumn(label: Text('Qty'), numeric: true),
        DataColumn(label: Text('Rate'), numeric: true),
        DataColumn(label: Text('Amount'), numeric: true),
        DataColumn(label: Text('Done'), numeric: true),
        DataColumn(label: Text('Progress')),
      ],
      rows: [
        for (final l in lines)
          DataRow(
            onSelectChanged: tap == null ? null : (_) => tap(l),
            cells: [
              DataCell(Text(l.code)),
              DataCell(
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: Tooltip(
                    message: l.description,
                    child: Text(
                      l.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              DataCell(Text('${formatQty(l.qty)} ${l.unit}')),
              DataCell(Text(formatMoney(l.rate))),
              DataCell(
                Text(
                  formatMoney(l.amount),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              DataCell(Text(formatQty(l.executedQty))),
              DataCell(SizedBox(width: 120, child: PctBar(l.progressPct))),
            ],
          ),
      ],
    );
  }
}

/// Add or edit one BOQ line (inside [showFormSheet]).
class BoqLineForm extends ConsumerStatefulWidget {
  const BoqLineForm({super.key, required this.projectId, this.original});

  final String projectId;
  final BoqLine? original;

  @override
  ConsumerState<BoqLineForm> createState() => _BoqLineFormState();
}

class _BoqLineFormState extends ConsumerState<BoqLineForm>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final BoqLine? _o = widget.original;
  late final _code = TextEditingController(text: _o?.code);
  late final _description = TextEditingController(text: _o?.description);
  late final _unit = TextEditingController(text: _o?.unit);
  late final _qty = TextEditingController(text: formatPlain(_o?.qty));
  late final _rate = TextEditingController(text: formatPlain(_o?.rate));
  late final _material = _budget(_o?.materialBudget);
  late final _labour = _budget(_o?.labourBudget);
  late final _other = _budget(_o?.otherBudget);
  bool _busy = false;

  static TextEditingController _budget(double? v) =>
      TextEditingController(text: v == null || v == 0 ? '' : formatPlain(v));

  @override
  void dispose() {
    for (final c in [
      _code,
      _description,
      _unit,
      _qty,
      _rate,
      _material,
      _labour,
      _other,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  BoqLineInput _input() => BoqLineInput(
    code: _code.text.trim(),
    description: _description.text.trim(),
    unit: _unit.text.trim(),
    qty: parseNumber(_qty.text) ?? 0,
    rate: parseNumber(_rate.text) ?? 0,
    materialBudget: parseNumber(_material.text) ?? (_o == null ? null : 0),
    labourBudget: parseNumber(_labour.text) ?? (_o == null ? null : 0),
    otherBudget: parseNumber(_other.text) ?? (_o == null ? null : 0),
  );

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final repo = ref.read(constructionRepositoryProvider);
    try {
      final o = _o;
      if (o == null) {
        await repo.addBoqLine(widget.projectId, _input());
      } else {
        await repo.updateBoqLine(o, _input());
      }
      ref.bumpC(const [CKind.boq]);
      if (!mounted) return;
      Navigator.of(context).pop();
      showSuccess(context, 'BOQ line ${_code.text.trim()} saved');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final o = _o!;
    final ok = await confirm(
      context,
      title: 'Delete ${o.code}?',
      message: 'The BOQ line "${o.description}" will be removed.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(constructionRepositoryProvider).deleteBoqLine(o.id);
      ref.bumpC(const [CKind.boq]);
      if (!mounted) return;
      Navigator.of(context).pop();
      showSuccess(context, 'BOQ line ${o.code} deleted');
    } catch (e) {
      if (!mounted) return;
      final inUse = apiError(e)?.code == 'IN_USE';
      if (inUse) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('This line is in use'),
            content: const Text(
              'A progress report, material issue or indent refers to this '
              'BOQ line, so it cannot be deleted. You can still edit it.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      } else {
        showErrorSnackBar(context, e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final input = _input();
    TextFormField money(
      TextEditingController c,
      String label,
      String field, {
      bool required = false,
    }) => TextFormField(
      controller: c,
      keyboardType: decimalKeyboard,
      inputFormatters: [decimalInput()],
      decoration: InputDecoration(
        labelText: label,
        prefixText: '₹ ',
        errorText: serverError(field),
      ),
      validator: required
          ? (v) => requiredNumber(v, label: label, min: 0)
          : (v) => optionalNumber(v, min: 0),
      onChanged: (_) => setState(() {}),
    );

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormRow(
                    children: [
                      TextFormField(
                        controller: _code,
                        decoration: InputDecoration(
                          labelText: 'Code',
                          hintText: 'e.g. 2.1.3',
                          errorText: serverError('code'),
                        ),
                        validator: (v) => requiredField(v, 'Code'),
                      ),
                      TextFormField(
                        controller: _unit,
                        decoration: InputDecoration(
                          labelText: 'Unit',
                          hintText: 'cum, sqm, kg, nos',
                          errorText: serverError('unit'),
                        ),
                        validator: (v) => requiredField(v, 'Unit'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _description,
                    decoration: InputDecoration(
                      labelText: 'Description',
                      errorText: serverError('description'),
                    ),
                    maxLines: 3,
                    minLines: 1,
                    validator: (v) => requiredField(v, 'Description'),
                  ),
                  const SizedBox(height: 16),
                  FormRow(
                    children: [
                      TextFormField(
                        controller: _qty,
                        keyboardType: decimalKeyboard,
                        inputFormatters: [decimalInput(decimals: 3)],
                        decoration: InputDecoration(
                          labelText: 'Qty',
                          errorText: serverError('qty'),
                        ),
                        validator: (v) =>
                            requiredNumber(v, label: 'Qty', min: 0.001),
                        onChanged: (_) => setState(() {}),
                      ),
                      money(_rate, 'Rate', 'rate', required: true),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Amount ${formatMoney(input.amount)}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Budgets (optional)',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  FormRow(
                    children: [
                      money(_material, 'Material', 'materialBudget'),
                      money(_labour, 'Labour', 'labourBudget'),
                      money(_other, 'Other', 'otherBudget'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_o != null)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                      minimumSize: const Size(48, 52),
                    ),
                    onPressed: _busy ? null : _delete,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                  ),
                BusyButton(
                  busy: _busy,
                  onPressed: _save,
                  label: _o == null ? 'Add line' : 'Save line',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Paste rows copied from Excel / Google Sheets (or CSV), preview them and
/// add them in one request.
class BoqPasteForm extends ConsumerStatefulWidget {
  const BoqPasteForm({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<BoqPasteForm> createState() => _BoqPasteFormState();
}

class _BoqPasteFormState extends ConsumerState<BoqPasteForm> {
  final _text = TextEditingController();
  BoqPasteResult _result = const BoqPasteResult();
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final added = await ref
          .read(constructionRepositoryProvider)
          .addBoqLines(widget.projectId, _result.lines);
      ref.bumpC(const [CKind.boq]);
      if (!mounted) return;
      Navigator.of(context).pop();
      showSuccess(context, '${added.length} BOQ lines added');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Copy the rows in your spreadsheet and paste them here. '
                'Columns: Code, Description, Unit, Qty, Rate, then optional '
                'Material, Labour and Other budgets. A header row is '
                'recognised and its columns can be in any order.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _text,
                minLines: 5,
                maxLines: 10,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Pasted rows',
                  hintText:
                      '1.1\tExcavation in ordinary soil\tcum\t120\t450\n'
                      '1.2\tPCC 1:4:8\tcum\t35\t5200',
                  alignLabelWithHint: true,
                ),
                onChanged: (t) => setState(() => _result = parseBoqPaste(t)),
              ),
              const SizedBox(height: 12),
              if (!r.isEmpty) ...[
                Text(
                  '${r.lines.length} lines ready · ${formatMoney(r.totalAmount)}'
                  '${r.hasHeader ? ' · header row used' : ''}'
                  '${r.skippedHeadings > 0 ? ' · ${r.skippedHeadings} section headings skipped' : ''}',
                  style: theme.textTheme.titleSmall,
                ),
                if (r.errors.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Fix these rows and paste again:',
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        for (final e in r.errors.take(20))
                          Text(
                            e.toString(),
                            style: TextStyle(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        if (r.errors.length > 20)
                          Text(
                            '…and ${r.errors.length - 20} more',
                            style: TextStyle(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                for (final l in r.lines.take(50))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${l.code} · ${l.description}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${formatQty(l.qty)} ${l.unit} × ${formatMoney(l.rate)}',
                    ),
                    trailing: Text(formatMoney(l.amount)),
                  ),
                if (r.lines.length > 50)
                  Text('…and ${r.lines.length - 50} more lines'),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Align(
            alignment: Alignment.centerRight,
            child: BusyButton(
              busy: _busy,
              onPressed: r.canImport ? _import : null,
              icon: Icons.playlist_add,
              label: r.lines.isEmpty
                  ? 'Add lines'
                  : 'Add ${r.lines.length} lines',
            ),
          ),
        ),
      ],
    );
  }
}
