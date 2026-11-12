import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_profile.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, bigOutlinedButton;
import 'inline_async.dart';
import 'membership_dialogs.dart';
import 'memberships_models.dart';
import 'memberships_repository.dart';

StatusTone memTone(String s) => switch (s) {
  'active' => StatusTone.success,
  'expiring' => StatusTone.warning,
  'expired' => StatusTone.danger,
  'frozen' => StatusTone.info,
  _ => StatusTone.neutral,
};

class MemStatusChip extends StatelessWidget {
  const MemStatusChip(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) =>
      StatusChip(status, label: memStatusLabel(status), tone: memTone(status));
}

/// `/memberships`: counts, dues and the member list.
class MembershipsHomeScreen extends ConsumerStatefulWidget {
  const MembershipsHomeScreen({super.key});

  @override
  ConsumerState<MembershipsHomeScreen> createState() =>
      _MembershipsHomeScreenState();
}

class _MembershipsHomeScreenState extends ConsumerState<MembershipsHomeScreen> {
  String _q = '';
  String? _status;

  Future<void> _add(MemWords w) async {
    final plans = await ref.read(memPlansProvider.future);
    if (!mounted) return;
    final out = await showFormDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => NewMemberDialog(words: w, plans: plans),
    );
    if (out == null || !mounted) return;
    ref.bumpMemberships(money: true);
    announceEnrolment(context, out);
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final profile = ref.watch(businessProfileProvider);
    final w = MemWords.of(profile);
    final manage = perms.can(Perm.membershipsManage);
    final summary = ref.watch(memSummaryProvider);
    final members = ref.watch(memMembersProvider((q: _q, status: _status)));
    return CGate(
      anyOf: const [Perm.membershipsView, Perm.membershipsManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: w.title,
            actions: [
              if (!w.society &&
                  perms.canAny(const [
                    Perm.membershipsCheckin,
                    Perm.membershipsManage,
                  ]))
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: () => context.go('/memberships/check-in'),
                  icon: const Icon(Icons.login),
                  label: const Text('Check-in'),
                ),
              OutlinedButton.icon(
                style: bigOutlinedButton,
                onPressed: () => context.go('/memberships/dues'),
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Dues'),
              ),
              if (manage)
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: () => context.go('/memberships/bills'),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: Text(w.bills),
                ),
              if (manage)
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: () => context.go('/memberships/plans'),
                  icon: const Icon(Icons.tune),
                  label: Text(w.plans),
                ),
              if (manage)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => _add(w),
                  icon: const Icon(Icons.person_add_alt_outlined),
                  label: Text(w.newMember),
                ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                pageGutter(context),
                0,
                pageGutter(context),
                24,
              ),
              children: [
                InlineAsync<MemSummary>(
                  value: summary,
                  onRetry: () => ref.invalidate(memSummaryProvider),
                  data: (s) => _Tiles(
                    words: w,
                    summary: s,
                    onFilter: (v) => setState(() => _status = v),
                  ),
                ),
                const SizedBox(height: 12),
                SearchField(
                  hintText: 'Search ${w.membersLower} by name, phone or number',
                  onChanged: (v) => setState(() => _q = v),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final (key, label) in <(String?, String)>[
                      (null, 'All'),
                      ('active', 'Active'),
                      ('expiring', 'Expiring'),
                      ('expired', 'Expired'),
                      ('frozen', 'Frozen'),
                    ])
                      ChoiceChip(
                        label: Text(label),
                        selected: _status == key,
                        onSelected: (_) => setState(() => _status = key),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                InlineAsync<List<MemberBrief>>(
                  value: members,
                  onRetry: () => ref.invalidate(memMembersProvider),
                  data: (list) => list.isEmpty
                      ? EmptyView(
                          icon: Icons.groups_outlined,
                          message: 'No ${w.membersLower} found.',
                        )
                      : Column(
                          children: [
                            for (final m in list)
                              _MemberCard(
                                key: ValueKey('member-${m.id}'),
                                member: m,
                                words: w,
                              ),
                          ],
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

class _Tiles extends StatelessWidget {
  const _Tiles({
    required this.words,
    required this.summary,
    required this.onFilter,
  });

  final MemWords words;
  final MemSummary summary;
  final ValueChanged<String?> onFilter;

  @override
  Widget build(BuildContext context) {
    Widget tile(
      String label,
      String value, {
      VoidCallback? onTap,
      Color? color,
    }) => Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.headlineSmall?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
    final scheme = Theme.of(context).colorScheme;
    final tiles = [
      tile(
        words.society ? 'Billed ${words.membersLower}' : 'Active',
        '${summary.active}',
        onTap: () => onFilter('active'),
      ),
      if (!words.society)
        tile(
          'Expiring this week',
          '${summary.expiring}',
          onTap: () => onFilter('expiring'),
        ),
      if (!words.society)
        tile(
          'Expired',
          '${summary.expired}',
          onTap: () => onFilter('expired'),
          color: summary.expired > 0 ? scheme.error : null,
        ),
      tile(
        'Dues',
        formatMoney(summary.duesAmount),
        onTap: () => context.go('/memberships/dues'),
        color: summary.duesAmount > 0 ? scheme.error : null,
      ),
      if (!words.society) tile('Visits today', '${summary.visitsToday}'),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 900 ? tiles.length.clamp(1, 5) : 2;
        const gap = 8.0;
        final width = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final t in tiles) SizedBox(width: width, child: t)],
        );
      },
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({super.key, required this.member, required this.words});

  final MemberBrief member;
  final MemWords words;

  @override
  Widget build(BuildContext context) {
    final m = member;
    final line = [
      m.memberNo,
      if (words.society && m.flatLabel.isNotEmpty) 'Flat ${m.flatLabel}',
      if (!words.society && m.phone != null) m.phone!,
      if (m.planName != null) m.planName!,
      if (m.endDate != null) 'till ${formatDate(m.endDate)}',
    ].join('  |  ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          onTap: () => context.go('/memberships/members/${m.id}'),
          title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(line, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: MemStatusChip(m.status),
        ),
      ),
    );
  }
}
