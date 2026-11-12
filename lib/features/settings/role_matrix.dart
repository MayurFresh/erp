import 'package:flutter/material.dart';

import 'settings_models.dart';

/// The five columns of the permission matrix.
const List<String> kMatrixColumns = [
  'View',
  'Create',
  'Edit',
  'Cancel / Approve',
  'Manage',
];

/// Which matrix column a permission key belongs to, from its last word.
/// Unknown actions fall under Manage, so every permission has a cell.
int matrixColumnOf(String key) {
  final action = key.contains('.') ? key.split('.').last : key;
  if (action == 'view' || action.startsWith('view_')) return 0;
  const create = {
    'create',
    'add',
    'mark',
    'journal',
    'import',
    'adjust',
    'receive',
    'reconcile',
  };
  if (create.contains(action)) return 1;
  if (action == 'edit' || action == 'update') return 2;
  const cancel = {'cancel', 'approve', 'void', 'delete', 'post', 'reverse'};
  if (cancel.contains(action)) return 3;
  return 4;
}

/// Permissions grouped by module, one checkbox per action column.
/// A cell with several permissions is tri-state.
class RoleMatrix extends StatelessWidget {
  const RoleMatrix({
    super.key,
    required this.modules,
    required this.selected,
    required this.enabled,
    required this.onToggle,
  });

  final Map<String, List<PermissionDef>> modules;
  final Set<String> selected;
  final bool enabled;
  final void Function(Iterable<String> keys, bool on) onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const cell = 64.0;
    Widget header(String text) => SizedBox(
      width: cell,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.labelSmall,
      ),
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const Expanded(child: Text('Module (tick to select all)')),
                  for (final c in kMatrixColumns) header(c),
                ],
              ),
            ),
            const Divider(),
            for (final MapEntry(key: module, value: defs) in modules.entries)
              _row(context, module, defs, cell),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String module,
    List<PermissionDef> defs,
    double cell,
  ) {
    final all = moduleSelection(defs, selected);
    final byColumn = List.generate(
      kMatrixColumns.length,
      (i) => [
        for (final d in defs)
          if (matrixColumnOf(d.key) == i) d,
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Checkbox(
                  key: Key('matrix-all-$module'),
                  tristate: true,
                  value: all,
                  onChanged: enabled
                      ? (_) => onToggle(defs.map((d) => d.key), all != true)
                      : null,
                ),
                Expanded(
                  child: Text(
                    module,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < byColumn.length; i++)
            SizedBox(
              width: cell,
              child: byColumn[i].isEmpty
                  ? const SizedBox.shrink()
                  : Tooltip(
                      message: byColumn[i].map((d) => d.label).join('\n'),
                      child: Checkbox(
                        key: Key('matrix-$module-$i'),
                        tristate: true,
                        value: moduleSelection(byColumn[i], selected),
                        onChanged: enabled
                            ? (_) => onToggle(
                                byColumn[i].map((d) => d.key),
                                moduleSelection(byColumn[i], selected) != true,
                              )
                            : null,
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}
