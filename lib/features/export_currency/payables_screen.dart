import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/search_picker.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'export_repository.dart';

final foreignPayablesProvider = FutureProvider.autoDispose<List<Json>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(exportRevisionProvider);
  return ref.watch(exportRepositoryProvider).payables();
});

/// `/fx-payables`: purchase bills in a foreign currency, what is still owed in
/// that currency, and period-end revaluation of the open amounts.
class ForeignPayablesScreen extends ConsumerStatefulWidget {
  const ForeignPayablesScreen({super.key});

  @override
  ConsumerState<ForeignPayablesScreen> createState() => _PayablesState();
}

class _PayablesState extends ConsumerState<ForeignPayablesScreen> {
  String? _asOf;
  final _rates = <String, TextEditingController>{};
  Json? _result;
  bool _posted = false;

  @override
  void dispose() {
    for (final c in _rates.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _tag() async {
    final repo = ref.read(exportRepositoryProvider);
    final api = ref.read(apiClientProvider);
    final bill = await showSearchPicker<Json>(
      context: context,
      title: 'Choose a purchase bill',
      hintText: 'Search bill number or vendor',
      emptyMessage: 'No bill found.',
      search: (q) async => asJsonList(
        (await api.getJson('/purchases', query: {'q': q, 'limit': 30, 'status': 'posted'}))['data'],
      ),
      titleBuilder: (_, d) => Text(asString(d['number'])),
      subtitleBuilder: (_, d) => Text(
        '${asString(d['partyName'])} · ${formatMoney(asDouble(d['total']))}',
      ),
    );
    if (bill == null || !mounted) return;
    final currencies = (await ref.read(currenciesProvider.future)).where((c) => c.isActive).toList();
    if (!mounted) return;
    var code = currencies.isEmpty ? 'USD' : currencies.first.code;
    final rate = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: Text('Bill ${asString(bill['number'])} in a foreign currency'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: code,
                decoration: const InputDecoration(labelText: 'Currency'),
                items: [
                  for (final c in currencies) DropdownMenuItem(value: c.code, child: Text('${c.code} ${c.name}')),
                ],
                onChanged: (v) => set(() => code = v ?? code),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: rate,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Rate the bill was booked at', helperText: 'Rupees per unit'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(d, (parseNumber(rate.text) ?? 0) > 0),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    final value = parseNumber(rate.text);
    rate.dispose();
    if (ok != true || value == null || !mounted) return;
    try {
      await repo.tagPayable(asString(bill['id']), code, value);
      ref.invalidate(foreignPayablesProvider);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _revalue(bool post, Set<String> codes) async {
    final asOf = _asOf ?? apiDate(DateTime.now());
    final rates = <String, double>{
      for (final c in codes)
        if (parseNumber(_rates[c]?.text ?? '') != null) c: parseNumber(_rates[c]!.text)!,
    };
    try {
      final r = await ref.read(exportRepositoryProvider).revaluePayables(
        asOf,
        post: post,
        rates: rates.isEmpty ? null : rates,
      );
      if (!mounted) return;
      setState(() {
        _result = r;
        _posted = post;
      });
      if (post) {
        ref.invalidate(foreignPayablesProvider);
        showInfoSnackBar(context, 'Revaluation posted. It reverses the next day.');
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(Perm.fxManage);
    final theme = Theme.of(context);
    return FormPage(
      children: [
        PageHeader(
          title: 'Foreign currency payables',
          subtitle: 'Bills from overseas vendors, and their revaluation at period end',
          actions: [
            if (manage)
              FilledButton.icon(
                onPressed: _tag,
                icon: const Icon(Icons.add),
                label: const Text('Tag a bill'),
              ),
          ],
        ),
        AsyncValueView(
          value: ref.watch(foreignPayablesProvider),
          onRetry: () => ref.invalidate(foreignPayablesProvider),
          data: (rows) {
            final codes = {for (final r in rows) asString(r['currency'])};
            for (final c in codes) {
              _rates.putIfAbsent(c, () => TextEditingController());
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionCard(
                  title: 'Open foreign bills',
                  child: rows.isEmpty
                      ? const Text('No foreign currency bill is open. Use Tag a bill to mark one.')
                      : Column(
                          children: [
                            for (final r in rows)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text('${asString(r['number'])} · ${formatDate(r['date'])}'),
                                subtitle: Text(
                                  '${asString(r['currency'])} ${formatQty(asDouble(r['fcOutstanding']))} owed, '
                                  'booked at ${formatQty(asDouble(r['rate']))}',
                                ),
                                trailing: Text(formatMoney(asDouble(r['inrOutstanding']))),
                              ),
                          ],
                        ),
                ),
                SectionCard(
                  title: 'Period-end revaluation',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Restates open foreign bills at the closing rate. A higher rate is a loss. '
                        'The journal is reversed the next day. Leave a rate empty to use the latest saved rate.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      PickerField(
                        label: 'As of',
                        value: formatDate(_asOf ?? apiDate(DateTime.now())),
                        icon: Icons.calendar_today_outlined,
                        onTap: () async {
                          final p = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now(),
                          );
                          if (p != null) setState(() => _asOf = apiDate(p));
                        },
                      ),
                      for (final c in codes.toList()..sort())
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: TextField(
                            controller: _rates[c],
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: InputDecoration(labelText: 'Closing rate for $c'),
                          ),
                        ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: rows.isEmpty ? null : () => _revalue(false, codes),
                            child: const Text('Preview'),
                          ),
                          FilledButton(
                            onPressed: manage && rows.isNotEmpty ? () => _revalue(true, codes) : null,
                            child: const Text('Post revaluation'),
                          ),
                        ],
                      ),
                      if (_result != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            '${_posted ? 'Posted' : 'Preview'}: '
                            '${asDouble(_result!['total'] ?? _result!['totalAdjustment']) >= 0 ? 'loss' : 'gain'} of '
                            '${formatMoney(asDouble(_result!['total'] ?? _result!['totalAdjustment']).abs())}',
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
