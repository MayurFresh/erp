import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, bigOutlinedButton;
import 'job_models.dart';
import 'job_repository.dart';

const List<String> kLanes = [
  'received',
  'estimate_sent',
  'approved',
  'in_progress',
  'ready',
];

StatusTone jobTone(String s) => switch (s) {
  'received' => StatusTone.neutral,
  'estimate_sent' => StatusTone.warning,
  'approved' => StatusTone.info,
  'in_progress' => StatusTone.info,
  'ready' => StatusTone.success,
  'delivered' => StatusTone.success,
  _ => StatusTone.danger,
};

class JobStatusChip extends StatelessWidget {
  const JobStatusChip(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) =>
      StatusChip(status, label: jobStatusLabel(status), tone: jobTone(status));
}

/// `/job-cards` (every open job) and `/job-cards/mine` (a technician's jobs).
class JobBoardScreen extends ConsumerStatefulWidget {
  const JobBoardScreen({super.key, this.mine = false});

  final bool mine;

  @override
  ConsumerState<JobBoardScreen> createState() => _JobBoardScreenState();
}

class _JobBoardScreenState extends ConsumerState<JobBoardScreen> {
  String _q = '';
  String? _lane;

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final canCreate = perms.canAny(const [
      Perm.jobCardsCreate,
      Perm.jobCardsManage,
    ]);
    final seesAll = perms.canAny(const [
      Perm.jobCardsView,
      Perm.jobCardsCreate,
      Perm.jobCardsManage,
    ]);
    final mine = widget.mine || !seesAll;
    final board = ref.watch(jobBoardProvider((mine: mine, q: _q)));
    return CGate(
      anyOf: const [
        Perm.jobCardsView,
        Perm.jobCardsCreate,
        Perm.jobCardsWork,
        Perm.jobCardsManage,
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: mine ? 'My jobs' : 'Job cards',
            actions: [
              if (seesAll && !widget.mine && perms.can(Perm.jobCardsWork))
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: () => context.go('/job-cards/mine'),
                  icon: const Icon(Icons.engineering_outlined),
                  label: const Text('My jobs'),
                ),
              if (canCreate)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/job-cards/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New job card'),
                ),
            ],
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              pageGutter(context),
              0,
              pageGutter(context),
              8,
            ),
            child: SearchField(
              hintText: 'Search number, vehicle, serial, name or phone',
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: AsyncValueView<JobBoard>(
              value: board,
              onRetry: () => ref.invalidate(jobBoardProvider),
              data: (b) => LayoutBuilder(
                builder: (context, c) => c.maxWidth >= 900
                    ? _Lanes(board: b)
                    : _Chips(
                        board: b,
                        lane: _lane,
                        onLane: (l) => setState(() => _lane = l),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Lanes extends StatelessWidget {
  const _Lanes({required this.board});

  final JobBoard board;

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutter(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final lane in kLanes)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '${jobStatusLabel(lane)} (${board.counts[lane] ?? 0})',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        children: [
                          for (final j in board.jobs.where(
                            (j) => j.status == lane,
                          ))
                            JobCard(job: j, compact: true),
                        ],
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

class _Chips extends StatelessWidget {
  const _Chips({required this.board, required this.lane, required this.onLane});

  final JobBoard board;
  final String? lane;
  final ValueChanged<String?> onLane;

  @override
  Widget build(BuildContext context) {
    final jobs = lane == null
        ? board.jobs
        : board.jobs.where((j) => j.status == lane).toList();
    final open = kLanes.fold<int>(0, (s, l) => s + (board.counts[l] ?? 0));
    final gutter = pageGutter(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 24),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            ChoiceChip(
              label: Text('All open ($open)'),
              selected: lane == null,
              onSelected: (_) => onLane(null),
            ),
            for (final l in kLanes)
              ChoiceChip(
                label: Text('${jobStatusLabel(l)} (${board.counts[l] ?? 0})'),
                selected: lane == l,
                onSelected: (_) => onLane(l),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (jobs.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: EmptyView(
              icon: Icons.build_outlined,
              message: 'No jobs here.',
            ),
          )
        else
          for (final j in jobs) JobCard(job: j),
      ],
    );
  }
}

class JobCard extends StatelessWidget {
  const JobCard({super.key, required this.job, this.compact = false});

  final JobBrief job;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final j = job;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          key: ValueKey('job-${j.id}'),
          onTap: () => context.go('/job-cards/${j.id}'),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        j.asset,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    if (!compact) JobStatusChip(j.status),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${j.customerName}${j.customerPhone == null ? '' : '  |  ${j.customerPhone}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    j.number,
                    if (j.technicianName != null) j.technicianName!,
                    if (j.promisedDate != null)
                      'Due ${formatDate(j.promisedDate)}',
                    if (j.subtotal > 0) formatMoney(j.subtotal),
                  ].join('  |  '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: j.overdue ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
