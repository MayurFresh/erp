import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/busy.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../locations/location_filter.dart';
import '../users/users_repository.dart';
import 'controls_models.dart';
import 'controls_repository.dart';

final _rulesProvider = FutureProvider.autoDispose
    .family<List<ApprovalRule>, String?>((ref, docType) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(controlsRepositoryProvider).rules(docType: docType);
    });

final _approverUsersProvider = FutureProvider.autoDispose((ref) async {
  ref.watch(activeCompanyIdProvider);
  return (await ref.watch(usersRepositoryProvider).users(limit: 200)).data;
});

/// `/approval-rules` (approvals.manage).
class ApprovalRulesScreen extends ConsumerStatefulWidget {
  const ApprovalRulesScreen({super.key});

  @override
  ConsumerState<ApprovalRulesScreen> createState() =>
      _ApprovalRulesScreenState();
}

class _ApprovalRulesScreenState extends ConsumerState<ApprovalRulesScreen> {
  String? _docType;

  Future<void> _edit([ApprovalRule? rule]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => RuleEditorDialog(rule: rule),
    );
    if (saved == true) ref.invalidate(_rulesProvider);
  }

  Future<void> _deactivate(ApprovalRule rule) async {
    try {
      await runBlocking(
        context,
        () => ref.read(controlsRepositoryProvider).deactivateRule(rule.id),
      );
      ref.invalidate(_rulesProvider);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = ref.watch(_rulesProvider(_docType));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Approval rules',
          subtitle: 'Who must approve a document before it is posted',
          actions: [
            FilledButton.icon(
              onPressed: _edit,
              icon: const Icon(Icons.add),
              label: const Text('Add rule'),
            ),
          ],
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Document',
              value: _docType,
              anyLabel: 'All documents',
              options: approvalDocTypes,
              onChanged: (v) => setState(() => _docType = v),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView(
            value: rules,
            onRetry: () => ref.invalidate(_rulesProvider),
            data: (rows) => rows.isEmpty
                ? const EmptyView(
                    icon: Icons.rule,
                    message: 'No approval rules. Documents post immediately.',
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                    children: [
                      for (final r in rows)
                        Card(
                          child: ListTile(
                            onTap: () => _edit(r),
                            title: Text(
                              '${r.name}${r.isActive ? '' : ' (inactive)'}',
                            ),
                            subtitle: Text(
                              '${approvalDocLabel(r.docType)} · from ${formatMoney(r.minAmount)}'
                              '${r.locationName == null ? '' : ' · ${r.locationName}'}\n'
                              '${r.levels.map((l) => 'L${l.level}: ${l.label}').join('  →  ')}',
                            ),
                            isThreeLine: true,
                            trailing: r.isActive
                                ? IconButton(
                                    tooltip: 'Deactivate',
                                    icon: const Icon(Icons.block),
                                    onPressed: () => _deactivate(r),
                                  )
                                : null,
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

class _LevelDraft {
  _LevelDraft({this.roleId, this.userId});

  String? roleId;
  String? userId;

  bool get isUser => userId != null;
}

/// Create or edit a rule with 1–5 levels, each a role or a user.
class RuleEditorDialog extends ConsumerStatefulWidget {
  const RuleEditorDialog({super.key, this.rule});

  final ApprovalRule? rule;

  @override
  ConsumerState<RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends ConsumerState<RuleEditorDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.rule?.name);
  late final _min = TextEditingController(
    text: widget.rule == null ? '0' : formatPlain(widget.rule!.minAmount),
  );
  late String _docType = widget.rule?.docType ?? 'purchase';
  late String? _locationId = widget.rule?.locationId;
  late bool _active = widget.rule?.isActive ?? true;
  late final List<_LevelDraft> _levels = [
    for (final l in widget.rule?.levels ?? const <ApprovalLevel>[])
      _LevelDraft(roleId: l.approverRoleId, userId: l.approverUserId),
    if (widget.rule == null) _LevelDraft(),
  ];
  bool _saving = false;
  String? _levelError;

  @override
  void dispose() {
    _name.dispose();
    _min.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      serverErrors = const {};
      _levelError = null;
    });
    final valid = validateAndReveal(_formKey);
    if (_levels.isEmpty || _levels.any((l) => (l.roleId ?? l.userId) == null)) {
      setState(() => _levelError = 'Choose an approver for every level');
      return;
    }
    if (!valid) return;
    final body = <String, dynamic>{
      'name': _name.text.trim(),
      'minAmount': parseNumber(_min.text) ?? 0,
      'locationId': _locationId,
      'levels': [
        for (final l in _levels)
          l.isUser
              ? {'approverUserId': l.userId}
              : {'approverRoleId': l.roleId},
      ],
      if (widget.rule != null) 'isActive': _active,
      if (widget.rule == null) 'docType': _docType,
    };
    if (widget.rule == null) body.removeWhere((k, v) => v == null);
    setState(() => _saving = true);
    try {
      final repo = ref.read(controlsRepositoryProvider);
      if (widget.rule == null) {
        await repo.createRule(body);
      } else {
        await repo.updateRule(widget.rule!.id, body);
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
    final roles = ref.watch(rolesProvider).value ?? const [];
    final users = ref.watch(_approverUsersProvider).value ?? const [];
    final locked = widget.rule != null;
    return AlertDialog(
      title: Text(widget.rule == null ? 'Add approval rule' : 'Edit rule'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Rule name'),
                  forceErrorText: serverError('name'),
                  validator: (v) => requiredField(v, 'Name'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: _docType,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Document'),
                  items: [
                    for (final e in approvalDocTypes.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: locked ? null : (v) => _docType = v ?? _docType,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _min,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  decoration: InputDecoration(
                    labelText: 'Applies from amount',
                    prefixText: '$moneySymbol ',
                  ),
                  forceErrorText: serverError('minAmount'),
                  validator: (v) => requiredNumber(v, label: 'Amount', min: 0),
                ),
                const SizedBox(height: 12),
                LocationFilter(
                  value: _locationId,
                  onChanged: (v) => setState(() => _locationId = v),
                ),
                const SizedBox(height: 16),
                Text(
                  'Approval levels',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                for (final (i, level) in _levels.indexed)
                  _levelRow(i, level, roles, users),
                if (_levelError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _levelError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (serverError('levels') != null)
                  Text(
                    serverError('levels')!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _levels.length >= 5
                        ? null
                        : () => setState(() => _levels.add(_LevelDraft())),
                    icon: const Icon(Icons.add),
                    label: const Text('Add level'),
                  ),
                ),
                if (widget.rule != null)
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
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        BusyButton(busy: _saving, onPressed: _save, label: 'Save'),
      ],
    );
  }

  Widget _levelRow(int i, _LevelDraft level, List roles, List users) {
    final value = level.isUser
        ? 'u:${level.userId}'
        : (level.roleId == null ? null : 'r:${level.roleId}');
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey('level-$i-$value'),
              initialValue: value,
              isExpanded: true,
              decoration: InputDecoration(labelText: 'Level ${i + 1} approver'),
              items: [
                for (final r in roles)
                  DropdownMenuItem(
                    value: 'r:${r.id}',
                    child: Text(
                      'Role · ${r.name}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                for (final u in users)
                  DropdownMenuItem(
                    value: 'u:${u.id}',
                    child: Text(
                      'User · ${u.name}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  level.roleId = v.startsWith('r:') ? v.substring(2) : null;
                  level.userId = v.startsWith('u:') ? v.substring(2) : null;
                });
              },
            ),
          ),
          IconButton(
            tooltip: 'Remove level',
            onPressed: _levels.length <= 1
                ? null
                : () => setState(() => _levels.removeAt(i)),
            icon: const Icon(Icons.remove_circle_outline),
          ),
        ],
      ),
    );
  }
}
