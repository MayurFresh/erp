import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart' show CGate, showSuccess;
import 'contract_list_screen.dart' show contractTone;
import 'helpdesk_models.dart';
import 'helpdesk_repository.dart';

/// `/service-contracts/:id`: terms, covered items, visit calendar, bills.
class ContractDetailScreen extends ConsumerStatefulWidget {
  const ContractDetailScreen({super.key, required this.contractId});

  final String contractId;

  @override
  ConsumerState<ContractDetailScreen> createState() =>
      _ContractDetailScreenState();
}

class _ContractDetailScreenState extends ConsumerState<ContractDetailScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() job, String done) async {
    setState(() => _busy = true);
    try {
      await job();
      ref.read(helpdeskRevisionProvider.notifier).bump();
      if (mounted) showSuccess(context, done);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _complete(Visit v) async {
    final notes = TextEditingController();
    final parts = TextEditingController();
    final sign = TextEditingController();
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Visit due ${v.dueDate}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: notes,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Work done'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: parts,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Parts used, one per line, such as Fan x 2',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: sign,
                decoration: const InputDecoration(
                  labelText: 'Customer name (signed by)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).maybePop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Mark done'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await ref.read(helpdeskRepositoryProvider).completeVisit(v.id, {
        'notes': trimmedOrNull(notes.text),
        'signatureName': trimmedOrNull(sign.text),
        'partsUsed': [
          for (final line in parts.text.split('\n'))
            if (line.trim().isNotEmpty) _part(line.trim()),
        ],
      });
    }, 'Visit marked done');
  }

  Json _part(String line) {
    final m = RegExp(r'^(.*?)\s*[xX]\s*(\d+(\.\d+)?)$').firstMatch(line);
    return m == null
        ? {'name': line, 'qty': 1}
        : {'name': m.group(1)!.trim(), 'qty': double.parse(m.group(2)!)};
  }

  Future<void> _cancel(Contract c) async {
    final reason = TextEditingController();
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this contract'),
        content: TextField(
          controller: reason,
          decoration: const InputDecoration(labelText: 'Reason'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).maybePop(),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel contract'),
          ),
        ],
      ),
    );
    if (ok != true || reason.text.trim().isEmpty) return;
    await _run(
      () async => ref
          .read(helpdeskRepositoryProvider)
          .cancelContract(c.id, reason.text.trim()),
      'Contract cancelled',
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(contractDetailProvider(widget.contractId));
    final perms = ref.watch(permissionsProvider);
    final manage = perms.can(Perm.serviceContractsManage);
    final gutter = pageGutter(context);
    final theme = Theme.of(context);
    return CGate(
      anyOf: const [Perm.serviceContractsView, Perm.serviceContractsManage],
      child: AsyncValueView<Contract>(
        value: async,
        onRetry: () => ref.invalidate(contractDetailProvider),
        data: (c) => ListView(
          padding: EdgeInsets.all(gutter),
          children: [
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.number, style: theme.textTheme.labelLarge),
                  Text(c.title, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(c.partyName),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      StatusChip(
                        c.status,
                        label: c.renewalDue
                            ? 'Renewal due'
                            : contractStatusLabel(c.status),
                        tone: contractTone(c),
                      ),
                      Pill(visitFrequencies[c.visitFrequency] ?? ''),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('${c.startDate} to ${c.endDate}'),
                  Text(
                    'Value ${formatMoney(c.value)} before GST, '
                    'billed ${formatMoney(c.billedAmount)}',
                  ),
                  Text(
                    c.billing == 'upfront'
                        ? 'Billed upfront'
                        : 'Billed ${(billFrequencies[c.billFrequency] ?? '').toLowerCase()}',
                  ),
                ],
              ),
            ),
            if (manage && (c.status == 'active' || c.status == 'expired'))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (c.status == 'active')
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                final r = await ref
                                    .read(helpdeskRepositoryProvider)
                                    .billContract(c.id);
                                final n = asJsonList(r['created']).length;
                                if (n == 0 && mounted) {
                                  showInfoSnackBar(
                                    this.context,
                                    'Nothing is due to bill yet.',
                                  );
                                }
                              }, 'Bills created'),
                        child: const Text('Bill what is due'),
                      ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              final n = await ref
                                  .read(helpdeskRepositoryProvider)
                                  .renewContract(c.id);
                              if (mounted) {
                                this.context.go('/service-contracts/${n.id}');
                              }
                            }, 'Contract renewed'),
                      child: const Text('Renew'),
                    ),
                    if (c.status == 'active')
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: _busy ? null : () => _cancel(c),
                        child: const Text('Cancel contract'),
                      ),
                  ],
                ),
              ),
            SectionCard(
              title: 'Covered items',
              child: c.assets.isEmpty
                  ? const Text('Everything the customer owns is covered.')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [for (final a in c.assets) Text(a.label)],
                    ),
            ),
            SectionCard(
              title: 'Visits',
              child: c.visits.isEmpty
                  ? const Text('No preventive visits on this contract.')
                  : Column(
                      children: [
                        for (final v in c.visits)
                          _VisitRow(
                            visit: v,
                            onDone: manage && v.status == 'scheduled' && !_busy
                                ? () => _complete(v)
                                : null,
                          ),
                      ],
                    ),
            ),
            SectionCard(
              title: 'Bills',
              child: c.bills.isEmpty
                  ? const Text('Nothing billed yet.')
                  : Column(
                      children: [
                        for (final b in c.bills)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(asString(b['number'])),
                            subtitle: Text('Period ${asString(b['period'])}'),
                            trailing: Text(formatMoney(asDouble(b['amount']))),
                            onTap: () => context.go(
                              '/invoices/${asString(b['invoiceId'])}',
                            ),
                          ),
                      ],
                    ),
            ),
            if (c.links.isNotEmpty)
              SectionCard(
                title: 'Linked tickets and jobs',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final l in c.links)
                      InkWell(
                        onTap: () => context.go(
                          asString(l['refType']) == 'ticket'
                              ? '/helpdesk/${asString(l['refId'])}'
                              : '/job-cards/${asString(l['refId'])}',
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(asString(l['label'])),
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

class _VisitRow extends StatelessWidget {
  const _VisitRow({required this.visit, required this.onDone});

  final Visit visit;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    final v = visit;
    final tone = v.status == 'done'
        ? StatusTone.success
        : v.status == 'skipped'
        ? StatusTone.neutral
        : v.overdue
        ? StatusTone.danger
        : StatusTone.info;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 8,
      title: Text(v.dueDate),
      subtitle: Text(
        [
          if (v.doneDate != null) 'Done ${v.doneDate}',
          if (v.technicianName != null) v.technicianName!,
          if (v.notes != null) v.notes!,
        ].join('  ·  '),
      ),
      trailing: onDone != null
          ? OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: onDone,
              child: const Text('Log visit'),
            )
          : StatusChip(
              v.status,
              label: v.overdue ? 'Overdue' : sentence(v.status),
              tone: tone,
            ),
    );
  }
}
