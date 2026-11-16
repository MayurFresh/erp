import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../widgets/busy.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../compliance/tax_perms.dart';
import 'tds_forms_repository.dart';
import 'tds_forms_widgets.dart';

String _today() => DateTime.now().toIso8601String().substring(0, 10);

/// `/tds-map`: old section to 2025 Act reference, shown for a chosen date.
class SectionMapScreen extends ConsumerStatefulWidget {
  const SectionMapScreen({super.key});

  @override
  ConsumerState<SectionMapScreen> createState() => _SectionMapScreenState();
}

class _SectionMapScreenState extends ConsumerState<SectionMapScreen> {
  String _date = _today();

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_date) ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (d != null) setState(() => _date = d.toIso8601String().substring(0, 10));
  }

  Future<void> _edit(Json row) async {
    final section = TextEditingController(text: asString(row['newSection']));
    var confirmed = row['confirmed'] == true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('Section ${asString(row['oldCode'])}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: section,
                  decoration: const InputDecoration(
                    labelText: 'Reference under the 2025 Act',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Checked against the official text'),
                  value: confirmed,
                  onChanged: (v) => set(() => confirmed = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await runBlocking(
        context,
        () => ref.read(tdsFormsRepositoryProvider).updateMapRow(
          asString(row['id']),
          {'newSection': section.text.trim(), 'confirmed': confirmed},
        ),
      );
      ref.invalidate(sectionMapProvider(_date));
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(TaxPerm.tdsManage);
    final data = ref.watch(sectionMapProvider(_date));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'TDS section map',
          subtitle: 'Old section and the 2025 Act reference, by date',
          actions: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _pickDate,
              icon: const Icon(Icons.event_outlined),
              label: Text('As on $_date'),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView(
            value: data,
            onRetry: () => ref.invalidate(sectionMapProvider(_date)),
            data: (d) {
              final rows = asJsonList(d['data']);
              final forms = asJson(d['forms']);
              return ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          forms['act'] == '2025'
                              ? 'Income-tax Act 2025: salary return ${forms['salaryReturn']}, '
                                    'other returns ${forms['nonSalaryReturn']}, certificates '
                                    '${forms['salaryCertificate']} and ${forms['nonSalaryCertificate']}.'
                              : 'Income-tax Act 1961: returns ${forms['salaryReturn']} and '
                                    '${forms['nonSalaryReturn']}, certificates '
                                    '${forms['salaryCertificate']} and ${forms['nonSalaryCertificate']}.',
                        ),
                        if (forms['unconfirmed'] == true)
                          const UnconfirmedBadge(),
                      ],
                    ),
                  ),
                  for (final r in rows)
                    ListTile(
                      minVerticalPadding: 8,
                      title: Text(
                        '${asString(r['oldCode'])}  ${asString(r['nature'])}',
                      ),
                      subtitle: Text(
                        [
                          'Shown as ${asString(r['reference'])}',
                          'Old ${asString(r['oldSection'])}, new ${asString(r['newSection'])}',
                          if (r['rateText'] != null) asString(r['rateText']),
                          if (r['thresholdText'] != null)
                            'Threshold ${asString(r['thresholdText'])}',
                        ].join('\n'),
                      ),
                      isThreeLine: true,
                      trailing: Wrap(
                        spacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (r['confirmed'] != true)
                            const UnconfirmedBadge(),
                          if (manage)
                            IconButton(
                              tooltip: 'Edit',
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _edit(r),
                            ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
