import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/form_support.dart';
import '../auth/session.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'controls_models.dart';
import 'controls_repository.dart';

/// `/cost-centres` (accounts.manage).
class CostCentresScreen extends ConsumerWidget {
  const CostCentresScreen({super.key});

  void _refresh(WidgetRef ref) {
    ref.invalidate(costCentresProvider(true));
    ref.invalidate(costCentresProvider(false));
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    List<CostCentre> all, [
    CostCentre? centre,
  ]) async {
    final saved = await showFormDialog<bool>(
      context: context,
      builder: (_) => _CostCentreDialog(centre: centre, all: all),
    );
    if (saved == true) _refresh(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(costCentresProvider(true));
    final all = value.value ?? const <CostCentre>[];
    final names = {for (final c in all) c.id: c.name};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Cost centres',
          subtitle: 'Tag income and expenses to branches and projects',
          actions: [
            FilledButton.icon(
              onPressed: () => _edit(context, ref, all),
              icon: const Icon(Icons.add),
              label: const Text('Add cost centre'),
            ),
          ],
        ),
        const _RequiredTile(),
        Expanded(
          child: AsyncValueView(
            value: value,
            onRetry: () => _refresh(ref),
            data: (rows) => rows.isEmpty
                ? const EmptyView(
                    icon: Icons.account_tree_outlined,
                    message: 'No cost centres yet.',
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                    children: [
                      for (final c in rows)
                        Card(
                          child: ListTile(
                            onTap: () => _edit(context, ref, rows, c),
                            title: Text(c.label),
                            subtitle: Text(
                              [
                                if (c.parentId != null)
                                  'Under ${names[c.parentId] ?? '—'}',
                                if (!c.isActive) 'Inactive',
                              ].join(' · '),
                            ),
                            trailing: const Icon(Icons.edit_outlined),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// "Cost centre required" switch for the company (`company.manage`).
class _RequiredTile extends ConsumerWidget {
  const _RequiredTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(permissionsProvider).can('company.manage')) {
      return const SizedBox.shrink();
    }
    final on = ref.watch(costCentreRequiredProvider).value;
    if (on == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SwitchListTile(
        key: const Key('company.costCentreRequired'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Cost centre required'),
        subtitle: const Text(
          'Invoices, bills, expenses, credit notes and income or expense '
          'journal lines must carry a cost centre.',
        ),
        value: on,
        onChanged: (v) async {
          try {
            await ref.read(controlsRepositoryProvider).setCostCentreRequired(v);
            ref.invalidate(costCentreRequiredProvider);
          } catch (e) {
            if (context.mounted) showErrorSnackBar(context, e);
          }
        },
      ),
    );
  }
}

class _CostCentreDialog extends ConsumerStatefulWidget {
  const _CostCentreDialog({required this.all, this.centre});

  final CostCentre? centre;
  final List<CostCentre> all;

  @override
  ConsumerState<_CostCentreDialog> createState() => _CostCentreDialogState();
}

class _CostCentreDialogState extends ConsumerState<_CostCentreDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _code = TextEditingController(text: widget.centre?.code);
  late final _name = TextEditingController(text: widget.centre?.name);
  late String? _parentId = widget.centre?.parentId;
  late bool _active = widget.centre?.isActive ?? true;
  bool _saving = false;

  bool get _editing => widget.centre != null;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      final repo = ref.read(controlsRepositoryProvider);
      if (_editing) {
        final stamp = widget.centre!.updatedAt;
        await repo.updateCostCentre(widget.centre!.id, {
          'name': _name.text.trim(),
          'parentId': _parentId,
          'isActive': _active,
          if (stamp != null)
            'expectedUpdatedAt': stamp.toUtc().toIso8601String(),
        });
      } else {
        await repo.createCostCentre({
          'code': _code.text.trim(),
          'name': _name.text.trim(),
          'parentId': ?_parentId,
        });
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final parents = widget.all
        .where(
          (c) => c.id != widget.centre?.id && (c.isActive || c.id == _parentId),
        )
        .toList();
    return AlertDialog(
      title: Text(_editing ? 'Edit cost centre' : 'Add cost centre'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _code,
                  enabled: !_editing,
                  maxLength: 20,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Code'),
                  forceErrorText: serverError('code'),
                  validator: (v) => requiredField(v, 'Code'),
                ),
                TextFormField(
                  controller: _name,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Name'),
                  forceErrorText: serverError('name'),
                  validator: (v) => requiredField(v, 'Name'),
                ),
                DropdownButtonFormField<String?>(
                  initialValue: parents.any((c) => c.id == _parentId)
                      ? _parentId
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Parent',
                    errorText: serverError('parentId'),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('None'),
                    ),
                    for (final c in parents)
                      DropdownMenuItem<String?>(
                        value: c.id,
                        child: Text(c.label, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _parentId = v),
                ),
                if (_editing)
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
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        BusyButton(busy: _saving, onPressed: _save, label: 'Save'),
      ],
    );
  }
}
