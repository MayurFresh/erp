import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'crm_models.dart';
import 'crm_repository.dart';
import 'crm_widgets.dart';

/// `/crm/settings`: stages, lost reasons, targets and the IndiaMART key.
class CrmSettingsScreen extends ConsumerWidget {
  const CrmSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gutter = pageGutter(context);
    return CrmGate(
      permission: Perm.crmSettings,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Sales settings',
            subtitle: 'Stages, lost reasons, targets and enquiry sources',
          ),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(crmSettingsProvider),
              onRetry: () => ref.invalidate(crmSettingsProvider),
              data: (s) => Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 860),
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xxl),
                    children: [
                      const _StagesCard(),
                      _ReasonsCard(settings: s),
                      const _TargetsCard(),
                      _IndiamartCard(settings: s),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Widget _save(String label, bool busy, VoidCallback? onTap) => Align(
  alignment: Alignment.centerLeft,
  child: FilledButton(
    style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
    onPressed: busy ? null : onTap,
    child: Text(busy ? 'Saving' : label),
  ),
);

class _Stage {
  _Stage(this.id, String name, int p, this.kind)
    : name = TextEditingController(text: name),
      prob = TextEditingController(text: '$p');

  final String? id;
  final TextEditingController name, prob;
  String kind;
}

class _StagesCard extends ConsumerStatefulWidget {
  const _StagesCard();

  @override
  ConsumerState<_StagesCard> createState() => _StagesCardState();
}

class _StagesCardState extends ConsumerState<_StagesCard> {
  List<_Stage>? _rows;
  bool _busy = false;
  String? _error;

  void _load(List<CrmStage> stages) {
    _rows ??= [
      for (final s in stages.where((s) => s.isActive))
        _Stage(s.id, s.name, s.probability, s.kind),
    ];
  }

  Future<void> _submit() async {
    final rows = _rows!;
    final opens = rows.where((r) => r.kind == 'open').length;
    final won = rows.where((r) => r.kind == 'won').length;
    final lost = rows.where((r) => r.kind == 'lost').length;
    if (rows.any((r) => r.name.text.trim().isEmpty)) {
      setState(() => _error = 'Every stage needs a name.');
      return;
    }
    if (opens < 1 || won != 1 || lost != 1) {
      setState(
        () => _error = 'Keep at least one open stage and exactly one Won and one Lost stage.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await crmGuarded(
      context,
      ref,
      () => ref.read(crmRepositoryProvider).saveStages([
        for (final r in rows)
          {
            'id': ?r.id,
            'name': r.name.text.trim(),
            'probability': (int.tryParse(r.prob.text.trim()) ?? 0).clamp(0, 100),
            'kind': r.kind,
          },
      ]),
      done: 'Stages saved.',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _rows = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final stages = ref.watch(crmStagesProvider);
    return SectionCard(
      title: 'Stages',
      icon: Icons.linear_scale,
      child: stages.when(
        loading: () => const Padding(padding: EdgeInsets.all(Space.md), child: LoadingView()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(crmStagesProvider)),
        data: (list) {
          _load(list);
          final rows = _rows!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: Space.sm),
                child: Text('Deals move through these in order. Probability weights the pipeline value.'),
              ),
              for (var i = 0; i < rows.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: rows[i].name,
                              decoration: InputDecoration(
                                labelText: 'Stage ${i + 1}',
                              ),
                            ),
                          ),
                          const SizedBox(width: Space.sm),
                          SizedBox(
                            width: 84,
                            child: TextField(
                              controller: rows[i].prob,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Chance',
                                suffixText: '%',
                              ),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButton<String>(
                              value: rows[i].kind,
                              isExpanded: true,
                              underline: const SizedBox.shrink(),
                              items: const [
                                DropdownMenuItem(value: 'open', child: Text('Open stage')),
                                DropdownMenuItem(value: 'won', child: Text('Won stage')),
                                DropdownMenuItem(value: 'lost', child: Text('Lost stage')),
                              ],
                              onChanged: (v) => setState(() => rows[i].kind = v ?? 'open'),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Move up',
                            onPressed: i == 0
                                ? null
                                : () => setState(() => rows.insert(i - 1, rows.removeAt(i))),
                            icon: const Icon(Icons.arrow_upward),
                          ),
                          IconButton(
                            tooltip: 'Move down',
                            onPressed: i == rows.length - 1
                                ? null
                                : () => setState(() => rows.insert(i + 1, rows.removeAt(i))),
                            icon: const Icon(Icons.arrow_downward),
                          ),
                          IconButton(
                            tooltip: 'Remove stage',
                            onPressed: rows.length <= 3
                                ? null
                                : () => setState(() => rows.removeAt(i)),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() {
                    final at = rows.indexWhere((r) => r.kind != 'open');
                    rows.insert(at < 0 ? rows.length : at, _Stage(null, '', 50, 'open'));
                  }),
                  icon: const Icon(Icons.add),
                  label: const Text('Add stage'),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.sm),
                  child: Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              _save('Save stages', _busy, _submit),
            ],
          );
        },
      ),
    );
  }
}

class _ReasonsCard extends ConsumerStatefulWidget {
  const _ReasonsCard({required this.settings});

  final CrmSettings settings;

  @override
  ConsumerState<_ReasonsCard> createState() => _ReasonsCardState();
}

class _ReasonsCardState extends ConsumerState<_ReasonsCard> {
  late final List<String> _reasons = [...widget.settings.lostReasons];
  late String? _owner = widget.settings.defaultOwnerId;
  final _add = TextEditingController();
  bool _busy = false;

  void _addOne() {
    final t = _add.text.trim();
    if (t.isEmpty || _reasons.contains(t) || _reasons.length >= 20) return;
    setState(() {
      _reasons.add(t.length > 60 ? t.substring(0, 60) : t);
      _add.clear();
    });
  }

  Future<void> _submit() async {
    _addOne();
    if (_reasons.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keep at least one lost reason.')),
      );
      return;
    }
    setState(() => _busy = true);
    await crmGuarded(
      context,
      ref,
      () => ref.read(crmRepositoryProvider).saveSettings({
        'lostReasons': _reasons,
        'defaultOwnerId': _owner,
      }),
      done: 'Settings saved.',
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final owners = ref.watch(crmOwnersProvider).value ?? const <CrmOwner>[];
    return SectionCard(
      title: 'Lost reasons and owner',
      icon: Icons.flag_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              for (final r in _reasons)
                InputChip(
                  label: Text(r),
                  onDeleted: () => setState(() => _reasons.remove(r)),
                ),
            ],
          ),
          const SizedBox(height: Space.md),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _add,
                  maxLength: 60,
                  decoration: const InputDecoration(
                    labelText: 'New reason',
                    counterText: '',
                  ),
                  onSubmitted: (_) => _addOne(),
                ),
              ),
              const SizedBox(width: Space.sm),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _addOne,
                child: const Text('Add'),
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          DropdownButtonFormField<String?>(
            initialValue: owners.any((o) => o.id == _owner) ? _owner : null,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Default owner for new leads',
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('The person who adds the lead'),
              ),
              for (final o in owners)
                DropdownMenuItem<String?>(value: o.id, child: Text(o.name)),
            ],
            onChanged: (v) => setState(() => _owner = v),
          ),
          const SizedBox(height: Space.md),
          _save('Save', _busy, _submit),
        ],
      ),
    );
  }
}

class _TargetsCard extends ConsumerStatefulWidget {
  const _TargetsCard();

  @override
  ConsumerState<_TargetsCard> createState() => _TargetsCardState();
}

class _TargetsCardState extends ConsumerState<_TargetsCard> {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  final Map<String, TextEditingController> _ctl = {};
  String? _loadedFor;
  bool _busy = false;

  String get _key => '${_month.year}-${_month.month.toString().padLeft(2, '0')}';

  void _shift(int by) => setState(() {
    _month = DateTime(_month.year, _month.month + by);
    _loadedFor = null;
  });

  Future<void> _submit(List<(String?, String)> rows) async {
    setState(() => _busy = true);
    await crmGuarded(
      context,
      ref,
      () => ref.read(crmRepositoryProvider).saveTargets(_key, [
        for (final (id, k) in rows)
          {'userId': id, 'amount': double.tryParse(_ctl[k]!.text.trim()) ?? 0},
      ]),
      done: 'Targets saved.',
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final owners = ref.watch(crmOwnersProvider).value ?? const <CrmOwner>[];
    final targets = ref.watch(crmTargetsProvider(_key));
    return SectionCard(
      title: 'Monthly targets',
      icon: Icons.track_changes_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Previous month',
                onPressed: () => _shift(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  formatDate('$_key-01').substring(3),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              IconButton(
                tooltip: 'Next month',
                onPressed: () => _shift(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          targets.when(
            loading: () => const Padding(padding: EdgeInsets.all(Space.md), child: LoadingView()),
            error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(crmTargetsProvider(_key))),
            data: (rows) {
              final entries = <(String?, String, String)>[
                (null, '_company', 'Whole company'),
                for (final o in owners) (o.id, o.id, o.name),
              ];
              if (_loadedFor != _key) {
                _loadedFor = _key;
                for (final (id, k, _) in entries) {
                  final r = rows.where((r) => r.userId == id).firstOrNull;
                  final c = _ctl.putIfAbsent(k, TextEditingController.new);
                  c.text = r == null || r.amount == 0 ? '' : formatPlain(r.amount);
                }
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (_, k, label) in entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.md),
                      child: TextField(
                        controller: _ctl[k],
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: label, prefixText: '₹ '),
                      ),
                    ),
                  _save('Save targets', _busy, () => _submit([for (final (id, k, _) in entries) (id, k)])),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _IndiamartCard extends ConsumerStatefulWidget {
  const _IndiamartCard({required this.settings});

  final CrmSettings settings;

  @override
  ConsumerState<_IndiamartCard> createState() => _IndiamartCardState();
}

class _IndiamartCardState extends ConsumerState<_IndiamartCard> {
  final _key = TextEditingController();
  bool _busy = false;
  bool _pulling = false;
  String? _result;
  bool _resultBad = false;

  Future<void> _saveKey(String? key) async {
    setState(() => _busy = true);
    final ok = await crmGuarded(
      context,
      ref,
      () => ref.read(crmRepositoryProvider).saveSettings({'indiamartKey': key}),
      done: key == null ? 'IndiaMART key removed.' : 'IndiaMART key saved.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) _key.clear();
  }

  Future<void> _pull() async {
    setState(() {
      _pulling = true;
      _result = null;
    });
    try {
      final r = await ref.read(crmRepositoryProvider).pullIndiamart();
      ref.bumpCrm();
      if (!mounted) return;
      setState(() {
        _resultBad = false;
        _result =
            'Added ${r.added} ${r.added == 1 ? 'enquiry' : 'enquiries'}, skipped ${r.skipped} already in the list.';
      });
    } catch (e) {
      if (!mounted) return;
      final api = apiError(e);
      setState(() {
        _resultBad = true;
        _result = switch (api?.code) {
          'TOO_SOON' => 'IndiaMART was checked less than 5 minutes ago. Try again in a few minutes.',
          'NO_INDIAMART_KEY' => 'Save your IndiaMART key first.',
          'INDIAMART_ERROR' => 'IndiaMART did not accept the request: ${api!.message}',
          _ => errorMessage(e),
        };
      });
    } finally {
      if (mounted) setState(() => _pulling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.settings;
    return SectionCard(
      title: 'IndiaMART enquiries',
      icon: Icons.cloud_download_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            s.hasIndiamartKey
                ? 'A key is saved. It cannot be shown again; enter a new one to replace it.'
                : 'Paste the CRM key from your IndiaMART Lead Manager to pull enquiries in as leads.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _key,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: s.hasIndiamartKey ? 'New key' : 'IndiaMART key',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Space.md),
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _busy || _key.text.trim().isEmpty
                    ? null
                    : () => _saveKey(_key.text.trim()),
                child: const Text('Save key'),
              ),
              if (s.hasIndiamartKey)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _busy ? null : () => _saveKey(null),
                  child: const Text('Remove key'),
                ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _pulling || !s.hasIndiamartKey ? null : _pull,
                child: Text(_pulling ? 'Fetching' : 'Fetch enquiries now'),
              ),
            ],
          ),
          if (_result != null) ...[
            const SizedBox(height: Space.md),
            Text(
              _result!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: _resultBad ? theme.colorScheme.error : null,
              ),
            ),
          ],
          const SizedBox(height: Space.md),
          Text(
            [
              s.indiamartLastPullAt == null
                  ? 'Not fetched yet.'
                  : 'Last fetched ${formatDateTime(s.indiamartLastPullAt)}.',
              if ((s.indiamartLastError ?? '').isNotEmpty)
                'Last error: ${s.indiamartLastError}',
            ].join(' '),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
