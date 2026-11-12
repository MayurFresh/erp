import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'education_models.dart';
import 'education_repository.dart';
import 'education_widgets.dart';

typedef _DueKey = ({String? classId, bool overdue, String q});

final _duesProvider = FutureProvider.autoDispose.family<DuesPage, _DueKey>((
  ref,
  key,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchEdu(const [EduKind.fees]);
  return ref
      .watch(eduRepositoryProvider)
      .dues(q: key.q, classId: key.classId, overdueOnly: key.overdue);
});

/// `/education/dues`: who owes what, with days overdue and a reminder text to
/// copy into WhatsApp or SMS.
class DuesScreen extends ConsumerStatefulWidget {
  const DuesScreen({super.key});

  @override
  ConsumerState<DuesScreen> createState() => _DuesScreenState();
}

class _DuesScreenState extends ConsumerState<DuesScreen> {
  String? _classId;
  bool _overdue = false;
  String _q = '';

  Future<void> _copy(DueRow r) async {
    await Clipboard.setData(ClipboardData(text: r.reminder));
    if (mounted) showSuccess(context, 'Reminder for ${r.student.name} copied');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = ref.watch(
      _duesProvider((classId: _classId, overdue: _overdue, q: _q)),
    );
    return CGate(
      anyOf: const [Perm.educationFees, Perm.educationManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Dues and defaulters'),
          FilterBar(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320, minWidth: 200),
                child: SearchField(
                  hintText: 'Name, admission no. or phone',
                  onChanged: (q) => setState(() => _q = q),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240, minWidth: 180),
                child: ClassDropdown(
                  value: _classId,
                  allowAll: true,
                  onChanged: (v) => setState(() => _classId = v),
                ),
              ),
              FilterChip(
                label: const Text('Overdue only'),
                selected: _overdue,
                onSelected: (v) => setState(() => _overdue = v),
              ),
            ],
          ),
          Expanded(
            child: AsyncValueView<DuesPage>(
              value: value,
              onRetry: () => ref.invalidate(_duesProvider),
              data: (page) => page.rows.isEmpty
                  ? const EmptyView(
                      icon: Icons.task_alt_outlined,
                      message: 'No dues. Everyone is paid up.',
                    )
                  : ListView(
                      padding: EdgeInsets.fromLTRB(
                        pageGutter(context),
                        0,
                        pageGutter(context),
                        24,
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Wrap(
                            spacing: 24,
                            runSpacing: 4,
                            children: [
                              Text('${page.total} students'),
                              Text('Due ${formatMoney(page.dueTotal)}'),
                              Text(
                                'Overdue ${formatMoney(page.overdueTotal)}',
                                style: TextStyle(
                                  color: page.overdueTotal > 0
                                      ? theme.colorScheme.error
                                      : null,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        for (final r in page.rows)
                          _DueCard(row: r, onCopy: () => _copy(r)),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DueCard extends StatelessWidget {
  const _DueCard({required this.row, required this.onCopy});

  final DueRow row;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = row.student;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => context.go('/education/students/${s.id}'),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.name, style: theme.textTheme.titleSmall),
                        Text(
                          '${s.line}\n${s.guardianName}  ${s.guardianPhone}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        formatMoney(row.due),
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        row.daysOverdue > 0
                            ? '${row.daysOverdue} days overdue'
                            : 'Not yet due',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: row.daysOverdue > 0
                              ? theme.colorScheme.error
                              : null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () =>
                      context.go('/education/collect?studentId=${s.id}'),
                  icon: const Icon(Icons.payments_outlined),
                  label: const Text('Collect'),
                ),
                OutlinedButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy reminder'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
