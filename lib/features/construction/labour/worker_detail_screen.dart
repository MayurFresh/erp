import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../common/c_perms.dart';
import '../common/c_widgets.dart';
import '../common/photo_widgets.dart';
import '../data/construction_repository.dart';
import '../models/labour_models.dart';

/// Worker profile and employment details.
class WorkerDetailScreen extends ConsumerWidget {
  const WorkerDetailScreen({super.key, required this.workerId});

  final String workerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return CGate(
      anyOf: const [CPerm.labourView],
      child: AsyncValueView(
        value: ref.watch(workerProvider(workerId)),
        onRetry: () => ref.invalidate(workerProvider(workerId)),
        data: (worker) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: worker.name,
              subtitle: tradeLabel(worker.trade.api),
              actions: [
                if (perms.can(CPerm.wagesView))
                  OutlinedButton.icon(
                    style: bigOutlinedButton,
                    onPressed: () =>
                        context.go('/labour-advances?workerId=${worker.id}'),
                    icon: const Icon(Icons.account_balance_wallet_outlined),
                    label: const Text('Advances'),
                  ),
                if (perms.can(CPerm.wagesPay) && worker.isActive)
                  OutlinedButton.icon(
                    style: bigOutlinedButton,
                    onPressed: () => context.go(
                      '/labour-advances/new?workerId=${worker.id}',
                    ),
                    icon: const Icon(Icons.add),
                    label: const Text('Pay advance'),
                  ),
                if (perms.can(CPerm.labourManage))
                  OutlinedButton.icon(
                    style: bigOutlinedButton,
                    onPressed: () => context.go('/workers/${worker.id}/edit'),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit worker'),
                  ),
              ],
            ),
            Expanded(
              child: CPage(
                maxWidth: 760,
                children: [
                  SectionCard(
                    title: 'Worker details',
                    child: FactsWrap(
                      facts: [
                        ('Trade', tradeLabel(worker.trade.api)),
                        ('Skill level', Skill.parse(worker.skill.api).label),
                        ('Daily rate', formatMoney(worker.dailyRate)),
                        ('Advance balance', formatMoney(worker.advanceBalance)),
                        ('Phone', worker.phone ?? ''),
                        ('Home site', worker.siteName ?? ''),
                        ('Contractor', worker.contractorName ?? ''),
                        ('Joined on', formatDate(worker.joinedOn)),
                        ('BOCW registration', worker.bocwRegNo ?? ''),
                        (
                          'Aadhaar',
                          worker.aadhaarLast4 == null
                              ? ''
                              : '••••${worker.aadhaarLast4}',
                        ),
                        ('Status', worker.isActive ? 'Active' : 'Inactive'),
                      ],
                    ),
                  ),
                  SectionCard(
                    title: 'Photo',
                    child: worker.photoFileId == null
                        ? const Text('No worker photo attached.')
                        : FileThumb(fileId: worker.photoFileId!, size: 180),
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
