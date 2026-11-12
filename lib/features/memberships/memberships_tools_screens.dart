import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/business_profile.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, bigOutlinedButton, showSuccess;
import 'membership_dialogs.dart';
import 'memberships_models.dart';
import 'memberships_repository.dart';

/// `/memberships/plans`.
class MemPlansScreen extends ConsumerWidget {
  const MemPlansScreen({super.key});

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    MemWords w, [
    MemPlan? p,
  ]) async {
    final saved = await showFormDialog<MemPlan>(
      context: context,
      builder: (_) => PlanDialog(plan: p, words: w),
    );
    if (saved == null) return;
    ref.bumpMemberships();
    if (context.mounted) showSuccess(context, '${saved.name} saved');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = MemWords.of(ref.watch(businessProfileProvider));
    final manage = ref.watch(permissionsProvider).can(Perm.membershipsManage);
    final plans = ref.watch(memPlansProvider);
    return CGate(
      anyOf: const [Perm.membershipsView, Perm.membershipsManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: w.plans,
            actions: [
              if (manage)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => _edit(context, ref, w),
                  icon: const Icon(Icons.add),
                  label: Text('Add ${w.plan.toLowerCase()}'),
                ),
            ],
          ),
          Expanded(
            child: AsyncValueView<List<MemPlan>>(
              value: plans,
              onRetry: () => ref.invalidate(memPlansProvider),
              data: (list) => list.isEmpty
                  ? EmptyView(
                      icon: Icons.tune,
                      message:
                          'No ${w.plans.toLowerCase()} yet. Add the first one.',
                    )
                  : ListView(
                      padding: EdgeInsets.fromLTRB(
                        pageGutter(context),
                        0,
                        pageGutter(context),
                        24,
                      ),
                      children: [
                        for (final p in list)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Card(
                              margin: EdgeInsets.zero,
                              child: ListTile(
                                key: ValueKey('plan-${p.id}'),
                                onTap: manage
                                    ? () => _edit(context, ref, w, p)
                                    : null,
                                title: Text(p.name),
                                subtitle: Text(
                                  [
                                    p.term,
                                    if (p.joiningFee > 0)
                                      'Joining ${formatMoney(p.joiningFee)}',
                                    if (p.freezeDays > 0)
                                      'Freeze up to ${p.freezeDays} days',
                                    'GST ${formatPercent(p.gstRate)}',
                                  ].join('  |  '),
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      p.perSqft
                                          ? '${formatMoney(p.price)} / sq ft'
                                          : formatMoney(p.price),
                                    ),
                                    if (!p.isActive) const Pill('Not in use'),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `/memberships/dues`: who owes what, with a reminder to copy.
class MemDuesScreen extends ConsumerWidget {
  const MemDuesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final w = MemWords.of(ref.watch(businessProfileProvider));
    final dues = ref.watch(memDuesProvider);
    return CGate(
      anyOf: const [Perm.membershipsView, Perm.membershipsManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Dues'),
          Expanded(
            child: AsyncValueView<List<DueRow>>(
              value: dues,
              onRetry: () => ref.invalidate(memDuesProvider),
              data: (list) => list.isEmpty
                  ? const EmptyView(
                      icon: Icons.check_circle_outline,
                      message: 'Nothing is due.',
                    )
                  : ListView(
                      padding: EdgeInsets.fromLTRB(
                        pageGutter(context),
                        0,
                        pageGutter(context),
                        24,
                      ),
                      children: [
                        for (final d in list)
                          Card(
                            margin: const EdgeInsets.only(bottom: 6),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: InkWell(
                                          onTap: () => context.go(
                                            '/memberships/members/${d.memberId}',
                                          ),
                                          child: Text(
                                            w.society && d.flatNo != null
                                                ? '${d.name}  (${[d.wing, d.flatNo].whereType<String>().join(' ')})'
                                                : d.name,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleSmall,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        formatMoney(d.due),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleSmall,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${d.memberNo}  |  ${d.bills} open bill${d.bills == 1 ? '' : 's'}${d.phone == null ? '' : '  |  ${d.phone}'}',
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      OutlinedButton.icon(
                                        onPressed: () async {
                                          await Clipboard.setData(
                                            ClipboardData(text: d.reminder),
                                          );
                                          if (context.mounted) {
                                            showSuccess(
                                              context,
                                              'Reminder copied',
                                            );
                                          }
                                        },
                                        icon: const Icon(Icons.copy_outlined),
                                        label: const Text('Copy reminder'),
                                      ),
                                      if (perms.can(Perm.membershipsManage) &&
                                          perms.can(Perm.paymentsCreate))
                                        FilledButton.icon(
                                          onPressed: () async {
                                            final ok =
                                                await showFormDialog<bool>(
                                                  context: context,
                                                  builder: (_) => CollectDialog(
                                                    memberId: d.memberId,
                                                    name: d.name,
                                                    due: d.due,
                                                  ),
                                                );
                                            if (ok == true) {
                                              ref.bumpMemberships(money: true);
                                              if (context.mounted) {
                                                showSuccess(
                                                  context,
                                                  'Receipt saved',
                                                );
                                              }
                                            }
                                          },
                                          icon: const Icon(
                                            Icons.payments_outlined,
                                          ),
                                          label: const Text('Collect'),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `/memberships/check-in`: mark a visit by phone or member number.
class CheckinScreen extends ConsumerStatefulWidget {
  const CheckinScreen({super.key});

  @override
  ConsumerState<CheckinScreen> createState() => _CheckinScreenState();
}

class _CheckinScreenState extends ConsumerState<CheckinScreen> {
  final _input = TextEditingController();
  bool _busy = false;
  CheckinResult? _ok;
  String? _refused;
  String? _refusedName;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    final digits = RegExp(r'^[0-9+() -]{7,}$').hasMatch(text);
    setState(() {
      _busy = true;
      _ok = null;
      _refused = null;
    });
    try {
      final r = await ref
          .read(membershipsRepositoryProvider)
          .checkin(memberNo: digits ? null : text, phone: digits ? text : null);
      if (!mounted) return;
      setState(() => _ok = r);
      _input.clear();
      ref.bumpMemberships();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _refused = e.message;
        _refusedName = asString(e.details['name']);
      });
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CGate(
      anyOf: const [Perm.membershipsCheckin, Perm.membershipsManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Check-in'),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                pageGutter(context),
                0,
                pageGutter(context),
                24,
              ),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _input,
                          autofocus: true,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _go(),
                          decoration: const InputDecoration(
                            labelText: 'Phone or member number',
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          style: bigButton,
                          onPressed: _busy ? null : _go,
                          icon: const Icon(Icons.login),
                          label: const Text('Mark visit'),
                        ),
                        const SizedBox(height: 20),
                        if (_ok != null)
                          Card(
                            color: Theme.of(
                              context,
                            ).colorScheme.primaryContainer,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Welcome, ${_ok!.name}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    [
                                      _ok!.memberNo,
                                      if (_ok!.endDate != null)
                                        'Valid till ${formatDate(_ok!.endDate)}',
                                      if (_ok!.expiringSoon)
                                        '${_ok!.daysLeft} days left. Ask them to renew.',
                                      if (_ok!.repeatToday)
                                        'Already checked in today.',
                                    ].join('\n'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (_refused != null)
                          Card(
                            color: scheme.errorContainer,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _refusedName == null ||
                                            _refusedName!.isEmpty
                                        ? 'Not allowed in'
                                        : '$_refusedName: not allowed in',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          color: scheme.onErrorContainer,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _refused!,
                                    style: TextStyle(
                                      color: scheme.onErrorContainer,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `/memberships/bills`: generate recurring bills for a period, with a preview count.
class MemBillsScreen extends ConsumerStatefulWidget {
  const MemBillsScreen({super.key});

  @override
  ConsumerState<MemBillsScreen> createState() => _MemBillsScreenState();
}

class _MemBillsScreenState extends ConsumerState<MemBillsScreen> {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  RunPreview? _preview;
  bool _loading = false;
  bool _busy = false;
  Object? _error;

  String get _period =>
      '${_month.year}-${_month.month.toString().padLeft(2, '0')}';

  String _kind(MemWords w) => w.society ? 'maintenance' : 'renewals';

  Future<void> _load(MemWords w) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await ref
          .read(membershipsRepositoryProvider)
          .preview(_kind(w), _period);
      if (mounted) setState(() => _preview = p);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(MemWords w) async {
    setState(() => _busy = true);
    try {
      final out = await ref
          .read(membershipsRepositoryProvider)
          .generate(_kind(w), _period);
      ref.bumpMemberships(money: true);
      if (mounted) {
        showSuccess(
          context,
          '${asInt(out['created'])} bills made, ${formatMoney(asDouble(out['total']))}',
        );
      }
      await _load(w);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(MemWords.of(ref.read(businessProfileProvider)));
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = MemWords.of(ref.watch(businessProfileProvider));
    final p = _preview;
    return CGate(
      anyOf: const [Perm.membershipsManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(title: w.bills),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                pageGutter(context),
                0,
                pageGutter(context),
                24,
              ),
              children: [
                if (w.society)
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Previous month',
                        onPressed: () {
                          setState(
                            () => _month = DateTime(
                              _month.year,
                              _month.month - 1,
                            ),
                          );
                          _load(w);
                        },
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text(
                        _period,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      IconButton(
                        tooltip: 'Next month',
                        onPressed: () {
                          setState(
                            () => _month = DateTime(
                              _month.year,
                              _month.month + 1,
                            ),
                          );
                          _load(w);
                        },
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  )
                else
                  const Text(
                    'Renews every member whose plan ends within 7 days or has ended, and bills the new term.',
                  ),
                const SizedBox(height: 12),
                if (_loading) const LinearProgressIndicator(),
                if (_error != null) Text(errorMessage(_error!)),
                if (p != null && !_loading)
                  SectionCard(
                    title: 'Preview',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.count == 0
                              ? 'Nothing to bill${w.society ? ' for $_period' : ''}.'
                              : '${p.count} ${p.count == 1 ? 'bill' : 'bills'} will be made.',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (p.alreadyBilled > 0)
                          Text(
                            '${p.alreadyBilled} already billed for this period.',
                          ),
                        for (final s in p.skipped) Text('Skipped $s'),
                      ],
                    ),
                  ),
                FilledButton.icon(
                  style: bigButton,
                  onPressed: _busy || p == null || p.count == 0
                      ? null
                      : () => _run(w),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: Text(_busy ? 'Working' : w.billsRun),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    style: bigOutlinedButton,
                    onPressed: () => _load(w),
                    child: const Text('Check again'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
