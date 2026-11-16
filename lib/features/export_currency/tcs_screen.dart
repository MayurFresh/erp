import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'export_models.dart';
import 'export_repository.dart';

/// TCS on sales: the switch, the rates and the collection report for the
/// TCS return.
class TcsScreen extends ConsumerStatefulWidget {
  const TcsScreen({super.key});

  @override
  ConsumerState<TcsScreen> createState() => _TcsScreenState();
}

class _TcsScreenState extends ConsumerState<TcsScreen> {
  late DateTime _from = DateTime(DateTime.now().year, DateTime.now().month >= 4 ? 4 : 4 - 12, 1);
  DateTime _to = DateUtils.dateOnly(DateTime.now());
  Future<TcsReport>? _report;

  void _load() {
    final f = ref.read(exportRepositoryProvider).tcsReport(apiDate(_from), apiDate(_to));
    setState(() {
      _report = f;
    });
  }

  Future<void> _date(bool from) async {
    final p = await showDatePicker(
      context: context,
      initialDate: from ? _from : _to,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (p == null) return;
    setState(() => from ? _from = p : _to = p);
    _load();
  }

  Future<void> _editRate(TcsNature n) async {
    final c = TextEditingController(text: formatPlain(n.rate));
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(n.label),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Rate, percent'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).maybePop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(d).pop(true), child: const Text('Save rate')),
        ],
      ),
    );
    final r = parseNumber(c.text);
    if (ok != true || r == null || !mounted) return;
    try {
      await ref.read(exportRepositoryProvider).saveNature(n.id, rate: r);
      ref.read(exportRevisionProvider.notifier).bump();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(Perm.tcsManage);
    final theme = Theme.of(context);
    final gutter = pageGutter(context);
    return ListView(
      padding: EdgeInsets.only(bottom: 24, left: gutter, right: gutter),
      children: [
        const PageHeader(title: 'TCS on sales', subtitle: 'Tax collected at source on the goods that still attract it'),
        AsyncValueView(
          value: ref.watch(exportSettingsProvider),
          onRetry: () => ref.invalidate(exportSettingsProvider),
          data: (s) => SectionCard(
            title: 'Settings',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: s.tcsEnabled,
                  title: const Text('Collect TCS on sales invoices'),
                  subtitle: const Text(
                    'Off by default. Section 206C(1H), on sales above 50 lakh, no '
                    'longer applies from 1 April 2025 and is not offered. Rates '
                    'below are the 206C(1) rates; check them with your CA.',
                  ),
                  onChanged: manage
                      ? (v) async {
                          await ref.read(exportRepositoryProvider).saveSettings(tcsEnabled: v);
                          ref.read(exportRevisionProvider.notifier).bump();
                        }
                      : null,
                ),
                DropdownButtonFormField<String>(
                  initialValue: s.tcsBase,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'TCS is worked out on'),
                  items: const [
                    DropdownMenuItem(value: 'taxable', child: Text('Value before GST')),
                    DropdownMenuItem(value: 'total', child: Text('Value including GST')),
                  ],
                  onChanged: manage
                      ? (v) async {
                          await ref.read(exportRepositoryProvider).saveSettings(tcsBase: v);
                          ref.read(exportRevisionProvider.notifier).bump();
                        }
                      : null,
                ),
              ],
            ),
          ),
        ),
        AsyncValueView(
          value: ref.watch(tcsNaturesProvider),
          onRetry: () => ref.invalidate(tcsNaturesProvider),
          data: (list) => SectionCard(
            title: 'Natures and rates',
            child: Column(
              children: [
                for (final n in list)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(n.label),
                    subtitle: Text('${n.sectionOld}${n.sectionNew == null ? '' : ' (new Act ${n.sectionNew})'}'
                        '${n.threshold > 0 ? ' · above ${formatMoney(n.threshold)}' : ''}'),
                    trailing: Text('${formatPlain(n.rate)}%'),
                    onTap: manage ? () => _editRate(n) : null,
                  ),
                const SizedBox(height: 8),
                Text(
                  'Set the nature on an item or a customer from the Items and Parties screens through the API, or choose it per invoice.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        SectionCard(
          title: 'Collection report',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FormRow(
                children: [
                  PickerField(label: 'From', value: formatDate(_from), icon: Icons.calendar_today_outlined, onTap: () => _date(true)),
                  PickerField(label: 'To', value: formatDate(_to), icon: Icons.calendar_today_outlined, onTap: () => _date(false)),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(onPressed: _load, child: const Text('Show report')),
              ),
              if (_report != null)
                FutureBuilder<TcsReport>(
                  future: _report,
                  builder: (context, snap) {
                    if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _load);
                    final r = snap.data;
                    if (r == null) return const Padding(padding: EdgeInsets.all(16), child: LoadingView());
                    if (r.rows.isEmpty) return const Padding(padding: EdgeInsets.only(top: 12), child: Text('No TCS collected in this period.'));
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 12),
                        Text('Total collected ${formatMoney(r.total)}', style: theme.textTheme.titleSmall),
                        if (r.missingPan > 0)
                          Text('${r.missingPan} invoice${r.missingPan == 1 ? '' : 's'} to buyers without a PAN. The return needs the PAN.'),
                        for (final row in r.rows)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('${row.number}  ${row.partyName}'),
                            subtitle: Text('${formatDate(row.date)} · ${row.section} · ${formatPlain(row.rate)}% of ${formatMoney(row.base)} · PAN ${row.pan ?? 'missing'}'),
                            trailing: Text(formatMoney(row.tcs)),
                          ),
                      ],
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}
