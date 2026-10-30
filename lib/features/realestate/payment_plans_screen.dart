import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 're_models.dart';
import 're_perms.dart';
import 're_repository.dart';
import 're_widgets.dart';

/// `/payment-plans`: stage-linked payment plans per project.
class PaymentPlansScreen extends ConsumerStatefulWidget {
  const PaymentPlansScreen({super.key});

  @override
  ConsumerState<PaymentPlansScreen> createState() => _PaymentPlansScreenState();
}

class _PaymentPlansScreenState extends ConsumerState<PaymentPlansScreen> {
  String? _projectId;
  late final PagedController<PaymentPlan> _paged = PagedController(
    (offset, limit) => ref
        .read(realEstateRepositoryProvider)
        .plans(projectId: _projectId, offset: offset, limit: limit),
  );

  @override
  void initState() {
    super.initState();
    _paged.refresh();
  }

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  String _stagesLabel(PaymentPlan p) =>
      '${p.stages.length} stage${p.stages.length == 1 ? '' : 's'}';

  @override
  Widget build(BuildContext context) {
    ref.listen(rRevisionProvider(RKind.plans), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final manage = ref.watch(permissionsProvider).can(RePerm.unitsManage);
    return CGate(
      anyOf: const [RePerm.unitsView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Payment plans',
            actions: [
              if (manage)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/payment-plans/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New plan'),
                ),
            ],
          ),
          FilterBar(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280, minWidth: 200),
                child: ProjectField(
                  required: false,
                  value: _projectId,
                  onChanged: (id) {
                    setState(() => _projectId = id);
                    _paged.refresh();
                  },
                ),
              ),
            ],
          ),
          Expanded(
            child: AdaptiveDataList<PaymentPlan>(
              controller: _paged,
              emptyMessage: 'No payment plans yet.',
              emptyIcon: Icons.account_tree_outlined,
              onTap: (p) => context.go('/payment-plans/${p.id}'),
              columns: [
                TableColumnSpec('Plan', (p) => Text(p.name)),
                TableColumnSpec('Stages', (p) => Text(_stagesLabel(p))),
                TableColumnSpec(
                  'Status',
                  (p) => Pill(
                    p.isActive ? 'Active' : 'Inactive',
                    color: p.isActive ? Colors.green.shade700 : Colors.grey,
                  ),
                ),
              ],
              cardBuilder: (context, p) => CListCard(
                onTap: () => context.go('/payment-plans/${p.id}'),
                title: p.name,
                subtitle: _stagesLabel(p),
                details: [p.stages.map((s) => s.name).join(' → ')],
                pills: Pill(
                  p.isActive ? 'Active' : 'Inactive',
                  color: p.isActive ? Colors.green.shade700 : Colors.grey,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Create (`planId == null`) or edit a plan.
class PlanFormScreen extends ConsumerWidget {
  const PlanFormScreen({super.key, this.planId});

  final String? planId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = planId;
    return CGate(
      anyOf: const [RePerm.unitsManage],
      child: id == null
          ? const PlanForm()
          : AsyncValueView(
              value: ref.watch(paymentPlanProvider(id)),
              onRetry: () => ref.invalidate(paymentPlanProvider(id)),
              data: (p) => PlanForm(key: ValueKey(p.id), original: p),
            ),
    );
  }
}

class _StageRow {
  _StageRow({String name = '', String pct = ''})
    : name = TextEditingController(text: name),
      pct = TextEditingController(text: pct);

  final TextEditingController name;
  final TextEditingController pct;
  final UniqueKey key = UniqueKey();

  void dispose() {
    name.dispose();
    pct.dispose();
  }
}

class PlanForm extends ConsumerStatefulWidget {
  const PlanForm({super.key, this.original});

  final PaymentPlan? original;

  @override
  ConsumerState<PlanForm> createState() => _PlanFormState();
}

class _PlanFormState extends ConsumerState<PlanForm> with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.original?.name);
  late String? _projectId = widget.original?.projectId;
  late bool _active = widget.original?.isActive ?? true;
  late final List<_StageRow> _rows = [
    for (final s in widget.original?.stages ?? const <PlanStage>[])
      _StageRow(name: s.name, pct: formatPlain(s.pct)),
  ];
  bool _saving = false;

  bool get _editing => widget.original != null;

  @override
  void initState() {
    super.initState();
    if (_rows.isEmpty) {
      _rows
        ..add(_StageRow(name: 'On booking', pct: '10'))
        ..add(_StageRow(name: 'On possession', pct: '90'));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  List<({String name, double? pct})> get _stages => [
    for (final r in _rows)
      (name: r.name.text.trim(), pct: parseNumber(r.pct.text)),
  ];

  double get _sum => stagePctSum(_stages.map((s) => s.pct ?? 0));

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!_formKey.currentState!.validate()) return;
    if (stagesError(_stages) != null) return;
    final stages = [
      for (final s in _stages) {'name': s.name, 'pct': s.pct},
    ];
    setState(() => _saving = true);
    try {
      final repo = ref.read(realEstateRepositoryProvider);
      final original = widget.original;
      if (original == null) {
        await repo.createPlan(
          projectId: _projectId!,
          name: _name.text.trim(),
          stages: stages,
        );
      } else {
        await repo.updatePlan(original.id, {
          'name': _name.text.trim(),
          'isActive': _active,
          'stages': stages,
        });
      }
      ref.bumpR(const [RKind.plans]);
      if (!mounted) return;
      showSuccess(context, 'Payment plan saved');
      context.go('/payment-plans');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = stagesError(_stages);
    final sum = _sum;
    final ok = error == null;
    return BottomBarLayout(
      maxWidth: 760,
      bar: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              style: bigButton,
              onPressed: _saving ? null : () => context.go('/payment-plans'),
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: BusyButton(
              busy: _saving,
              onPressed: ok ? _save : null,
              label: 'Save plan',
            ),
          ),
        ],
      ),
      child: Form(
        key: _formKey,
        child: FormPage(
          children: [
            Text(
              _editing ? 'Edit payment plan' : 'New payment plan',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Plan',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ProjectField(
                    value: _projectId,
                    enabled: !_editing,
                    onChanged: (id) => setState(() => _projectId = id),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Plan name'),
                    forceErrorText: serverError('name'),
                    onChanged: (_) => clearServerError('name'),
                    validator: (v) => requiredField(v, 'Name'),
                  ),
                  if (_editing)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Active'),
                      subtitle: const Text(
                        'Inactive plans cannot be chosen for new bookings.',
                      ),
                      value: _active,
                      onChanged: (v) => setState(() => _active = v),
                    ),
                ],
              ),
            ),
            SectionCard(
              title: 'Stages',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < _rows.length; i++)
                    Padding(
                      key: _rows[i].key,
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextFormField(
                              controller: _rows[i].name,
                              decoration: InputDecoration(
                                labelText: 'Stage ${i + 1}',
                              ),
                              onChanged: (_) => setState(() {}),
                              validator: (v) => requiredField(v, 'Name'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 96,
                            child: TextFormField(
                              controller: _rows[i].pct,
                              decoration: const InputDecoration(labelText: '%'),
                              keyboardType: decimalKeyboard,
                              inputFormatters: [percentInput()],
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Remove stage',
                            onPressed: _rows.length <= 1
                                ? null
                                : () => setState(
                                    () => _rows.removeAt(i).dispose(),
                                  ),
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                        ],
                      ),
                    ),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _rows.length >= 30
                            ? null
                            : () => setState(() => _rows.add(_StageRow())),
                        icon: const Icon(Icons.add),
                        label: const Text('Add stage'),
                      ),
                      Chip(
                        key: const Key('plan-sum'),
                        avatar: Icon(
                          ok ? Icons.check_circle : Icons.error_outline,
                          color: ok
                              ? Colors.green.shade700
                              : theme.colorScheme.error,
                        ),
                        label: Text('Σ ${formatPlain(sum)}% of 100%'),
                      ),
                    ],
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        error,
                        key: const Key('plan-error'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
