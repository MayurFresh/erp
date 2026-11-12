import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_profile.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, bigOutlinedButton, confirm, showSuccess;
import 'membership_dialogs.dart';
import 'memberships_home_screen.dart';
import 'memberships_models.dart';
import 'memberships_repository.dart';

/// `/memberships/members/:id`: one member or flat with plan history, bills and visits.
class MemberFileScreen extends ConsumerWidget {
  const MemberFileScreen({super.key, required this.memberId});

  final String memberId;

  Future<void> _renew(BuildContext context, WidgetRef ref, MemberFile f) async {
    final plans = await ref.read(memPlansProvider.future);
    if (!context.mounted) return;
    final out = await showFormDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => RenewDialog(
        member: f.brief,
        plans: plans,
        currentPlanId: f.current?.planId,
      ),
    );
    if (out == null) return;
    ref.bumpMemberships(money: true);
    if (context.mounted) showSuccess(context, 'Renewed');
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    MemberFile f,
    MemWords w,
  ) async {
    final out = await showFormDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => EditMemberDialog(file: f, words: w),
    );
    if (out == null) return;
    ref.bumpMemberships();
    if (context.mounted) showSuccess(context, 'Saved');
  }

  Future<void> _collect(
    BuildContext context,
    WidgetRef ref,
    MemberFile f,
  ) async {
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (_) => CollectDialog(
        memberId: f.brief.id,
        name: f.brief.name,
        due: f.dueAmount,
      ),
    );
    if (ok != true) return;
    ref.bumpMemberships(money: true);
    if (context.mounted) showSuccess(context, 'Receipt saved');
  }

  Future<void> _freeze(
    BuildContext context,
    WidgetRef ref,
    MemSubscription s,
  ) async {
    final repo = ref.read(membershipsRepositoryProvider);
    try {
      if (s.frozen) {
        final out = await repo.unfreeze(s.id);
        ref.bumpMemberships();
        if (context.mounted) {
          showSuccess(context, 'Unfrozen. Ends ${formatDate(out['endDate'])}');
        }
      } else {
        final yes = await confirm(
          context,
          title: 'Freeze this plan?',
          message:
              '${s.freezeLeft} freeze days are left. The end date moves out by the days frozen.',
          confirmLabel: 'Freeze',
        );
        if (!yes) return;
        await repo.freeze(s.id);
        ref.bumpMemberships();
      }
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final w = MemWords.of(ref.watch(businessProfileProvider));
    final manage = perms.can(Perm.membershipsManage);
    final file = ref.watch(memberFileProvider(memberId));
    return CGate(
      anyOf: const [Perm.membershipsView, Perm.membershipsManage],
      child: AsyncValueView<MemberFile>(
        value: file,
        onRetry: () => ref.invalidate(memberFileProvider(memberId)),
        data: (f) {
          final b = f.brief;
          final cur = f.current;
          final gutter = pageGutter(context);
          return ListView(
            padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      b.name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  MemStatusChip(b.status),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                [
                  b.memberNo,
                  if (w.society && b.flatLabel.isNotEmpty)
                    'Flat ${b.flatLabel}',
                  if (b.phone != null) b.phone!,
                ].join('  |  '),
              ),
              const SizedBox(height: 12),
              if (manage)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      style: bigButton,
                      onPressed: () => _renew(context, ref, f),
                      icon: const Icon(Icons.autorenew),
                      label: const Text('Renew'),
                    ),
                    OutlinedButton.icon(
                      style: bigOutlinedButton,
                      onPressed: () => _edit(context, ref, f, w),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit'),
                    ),
                    if (f.dueAmount > 0.004 && perms.can(Perm.paymentsCreate))
                      OutlinedButton.icon(
                        style: bigOutlinedButton,
                        onPressed: () => _collect(context, ref, f),
                        icon: const Icon(Icons.payments_outlined),
                        label: Text('Collect ${formatMoney(f.dueAmount)}'),
                      ),
                    if (!w.society &&
                        cur != null &&
                        (cur.frozen || cur.freezeLeft > 0))
                      OutlinedButton.icon(
                        style: bigOutlinedButton,
                        onPressed: () => _freeze(context, ref, cur),
                        icon: Icon(cur.frozen ? Icons.play_arrow : Icons.pause),
                        label: Text(cur.frozen ? 'Unfreeze' : 'Freeze'),
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'Details',
                child: Wrap(
                  spacing: 32,
                  runSpacing: 12,
                  children: [
                    LabeledValue('Plan', b.planName ?? ''),
                    LabeledValue(
                      'Valid till',
                      b.endDate == null ? 'Open' : formatDate(b.endDate),
                    ),
                    if (w.society)
                      LabeledValue(
                        'Area',
                        b.areaSqft == null
                            ? ''
                            : '${formatQty(b.areaSqft)} sq ft',
                      ),
                    if (w.society)
                      LabeledValue(
                        'Lives as',
                        f.occupancy == null
                            ? ''
                            : f.occupancy == 'owner'
                            ? 'Owner'
                            : 'Tenant',
                      ),
                    if (!w.society)
                      LabeledValue(
                        'Emergency contact',
                        [
                          f.emergencyName,
                          f.emergencyPhone,
                        ].whereType<String>().join(', '),
                      ),
                    LabeledValue('Dues', formatMoney(f.dueAmount)),
                  ],
                ),
              ),
              SectionCard(
                title: 'Plan history',
                child: f.subscriptions.isEmpty
                    ? const Text('No plan yet.')
                    : Column(
                        children: [
                          for (final s in f.subscriptions)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(s.planName),
                              subtitle: Text(
                                '${formatDate(s.startDate)} to ${s.endDate == null ? 'open' : formatDate(s.endDate)}'
                                '${s.frozen ? '  |  frozen since ${formatDate(s.frozenFrom)}' : ''}',
                              ),
                              trailing: Text(formatMoney(s.price)),
                            ),
                        ],
                      ),
              ),
              SectionCard(
                title: 'Bills',
                child: f.bills.isEmpty
                    ? const Text('No bills yet.')
                    : Column(
                        children: [
                          for (final x in f.bills)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(x.number),
                              subtitle: Text(
                                '${formatDate(x.date)}  |  ${x.period}',
                              ),
                              trailing: Text(
                                x.due > 0.004
                                    ? '${formatMoney(x.total)}  due ${formatMoney(x.due)}'
                                    : '${formatMoney(x.total)}  paid',
                              ),
                            ),
                        ],
                      ),
              ),
              if (!w.society)
                SectionCard(
                  title: 'Recent visits',
                  child: f.visits.isEmpty
                      ? const Text('No visits yet.')
                      : Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final d in f.visits) Pill(formatDate(d)),
                          ],
                        ),
                ),
            ],
          );
        },
      ),
    );
  }
}
