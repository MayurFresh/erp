import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';

import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_fonts.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import '../construction/common/c_widgets.dart';
import 'legal_dialogs.dart';
import 'legal_models.dart';
import 'legal_repository.dart';
import 'legal_widgets.dart';
import 'matter_pdf.dart';

enum _Tab { overview, hearings, tasks, entries, documents, bills }

const _tabLabels = {
  _Tab.overview: 'Overview',
  _Tab.hearings: 'Hearings',
  _Tab.tasks: 'Tasks',
  _Tab.entries: 'Time and expenses',
  _Tab.documents: 'Documents',
  _Tab.bills: 'Bills',
};

/// `/legal/matters/:id`: the matter file.
class MatterScreen extends ConsumerWidget {
  const MatterScreen({super.key, required this.matterId});

  final String matterId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CGate(
    anyOf: const [Perm.legalView],
    child: AsyncValueView<Matter>(
      value: ref.watch(legalMatterProvider(matterId)),
      onRetry: () => ref.invalidate(legalMatterProvider(matterId)),
      data: (m) => _MatterBody(matter: m),
    ),
  );
}

class _MatterBody extends ConsumerStatefulWidget {
  const _MatterBody({required this.matter});

  final Matter matter;

  @override
  ConsumerState<_MatterBody> createState() => _MatterBodyState();
}

class _MatterBodyState extends ConsumerState<_MatterBody> {
  _Tab _tab = _Tab.overview;

  Matter get m => widget.matter;

  Future<void> _edit() async {
    final saved = await showFormDialog<Matter>(
      context: context,
      builder: (_) =>
          MatterFormDialog(matter: m, canManage: ref.legalCanManage),
    );
    if (saved != null) ref.bumpLegal();
  }

  Future<void> _addHearing() async {
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (_) => HearingDialog(matter: m),
    );
    if (ok == true) ref.bumpLegal();
  }

  Future<void> _addEntry() async {
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (_) => EntryDialog(
        matter: m,
        canAddFee:
            ref.legalCanManage ||
            m.advocateId == ref.read(sessionProvider).value?.user?.id,
      ),
    );
    if (ok == true) {
      ref.bumpLegal();
      if (mounted) showSuccess(context, 'Entry saved');
    }
  }

  Future<void> _addTask() async {
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (_) => TaskDialog(matterId: m.id),
    );
    if (ok == true) ref.bumpLegal();
  }

  Future<void> _bill() async {
    List<Entry> entries;
    try {
      entries = (await ref.read(legalRepositoryProvider).entries(m.id))
          .where((e) => !e.billed && e.billable)
          .toList();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
      return;
    }
    if (!mounted) return;
    final number = await showFormDialog<String>(
      context: context,
      builder: (_) => BillDialog(matter: m, entries: entries),
    );
    if (number == null) return;
    ref.bumpLegal(money: true);
    if (mounted) showSuccess(context, 'Bill $number created');
  }

  Future<void> _receipt() async {
    Bills bills;
    try {
      bills = await ref.read(legalRepositoryProvider).bills(m.id);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
      return;
    }
    if (!mounted) return;
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (_) => ReceiptDialog(matter: m, bills: bills.bills),
    );
    if (ok != true) return;
    ref.bumpLegal(money: true);
    if (mounted) showSuccess(context, 'Receipt saved');
  }

  Future<void> _setStatus(String status) async {
    try {
      await ref.read(legalRepositoryProvider).saveMatter(m.id, {
        'status': status,
        'expectedUpdatedAt': m.updatedAt,
      });
      ref.bumpLegal();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _pdf({required bool share}) async {
    try {
      Company? company;
      try {
        company = await ref.read(companyRepositoryProvider).get();
      } catch (_) {
        company = ref.read(sessionProvider).value?.company;
      }
      final co =
          company ?? const Company(id: '', name: 'Company', stateCode: '');
      final bills = ref.read(legalRepositoryProvider).bills(m.id);
      final bytes = await buildMatterStatusPdf(
        m,
        co,
        bills: await bills.catchError((_) => const Bills([], [])),
        brand: await loadPdfBrand(ref.read(apiClientProvider), co),
        theme: await pdfTheme(),
      );
      if (share) {
        await Printing.sharePdf(
          bytes: Uint8List.fromList(bytes),
          filename: matterPdfName(m),
        );
      } else {
        await Printing.layoutPdf(
          onLayout: (_) async => Uint8List.fromList(bytes),
          name: matterPdfName(m),
        );
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final work = ref.legalCanWork;
    final manage = ref.legalCanManage;
    final perms = ref.watch(permissionsProvider);
    final canBill = manage && perms.can(Perm.invoicesCreate);
    return FormPage(
      maxWidth: 1000,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconButton(
              tooltip: 'Back to matters',
              onPressed: () => context.go('/legal/matters'),
              icon: const Icon(Icons.arrow_back),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.title, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('${m.matterNo}  |  ${m.clientName}'),
                      MatterStatusChip(m.status),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (work && m.isOpen)
              FilledButton.icon(
                onPressed: _addHearing,
                icon: const Icon(Icons.event_outlined),
                label: const Text('Add hearing'),
              ),
            if (work && m.status != 'closed')
              OutlinedButton.icon(
                onPressed: _addEntry,
                icon: const Icon(Icons.timer_outlined),
                label: const Text('Time or expense'),
              ),
            if (work)
              OutlinedButton.icon(
                onPressed: _addTask,
                icon: const Icon(Icons.checklist_outlined),
                label: const Text('Add task'),
              ),
            if (canBill)
              OutlinedButton.icon(
                onPressed: _bill,
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('Create bill'),
              ),
            if (canBill && perms.can(Perm.paymentsCreate))
              OutlinedButton.icon(
                onPressed: _receipt,
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Record receipt'),
              ),
            OutlinedButton.icon(
              onPressed: () => _pdf(share: true),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('Status PDF'),
            ),
            if (work)
              OutlinedButton.icon(
                onPressed: _edit,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
              ),
            if (work)
              PopupMenuButton<String>(
                tooltip: 'Change status',
                onSelected: _setStatus,
                itemBuilder: (_) => [
                  for (final e in matterStatuses.entries)
                    if (e.key != m.status)
                      PopupMenuItem(
                        value: e.key,
                        child: Text(
                          e.key == 'open'
                              ? 'Reopen'
                              : 'Mark as ${e.value.toLowerCase()}',
                        ),
                      ),
                ],
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.more_vert),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final t in _Tab.values)
              ChoiceChip(
                key: ValueKey('tab-${t.name}'),
                label: Text(_tabLabels[t]!),
                selected: _tab == t,
                onSelected: (_) => setState(() => _tab = t),
              ),
          ],
        ),
        const SizedBox(height: 12),
        switch (_tab) {
          _Tab.overview => _Overview(matter: m),
          _Tab.hearings => _Hearings(matter: m, canWork: work),
          _Tab.tasks => _Tasks(matter: m, canWork: work),
          _Tab.entries => _Entries(matter: m, canWork: work),
          _Tab.documents => _Documents(matter: m, canWork: work),
          _Tab.bills => _BillsTab(matter: m),
        },
      ],
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.matter});

  final Matter matter;

  @override
  Widget build(BuildContext context) {
    final m = matter;
    final u = m.unbilled;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'Case',
          icon: Icons.gavel_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LegalFact('Client', m.clientName),
              LegalFact('Against', m.opposingParty),
              LegalFact('Court', m.court),
              LegalFact('Case type', m.caseType),
              LegalFact('Case number', m.caseRef),
              LegalFact(
                'Filed',
                m.filingDate == null ? null : formatDate(m.filingDate),
              ),
              LegalFact('Stage', m.stage),
              LegalFact(
                'Next hearing',
                m.nextHearingDate == null
                    ? 'No date fixed'
                    : formatDate(m.nextHearingDate),
              ),
              LegalFact('Advocate', m.advocateName),
              LegalFact('Team', m.team.map((p) => p.name).join(', ')),
              LegalFact('Notes', m.notes),
            ],
          ),
        ),
        SectionCard(
          title: 'Fees',
          icon: Icons.account_balance_wallet_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LegalFact('Arrangement', feeTypes[m.feeType]),
              if (m.agreedFee > 0)
                LegalFact('Agreed fee', formatMoney(m.agreedFee)),
              if (m.hourlyRate != null)
                LegalFact('Hourly rate', formatMoney(m.hourlyRate)),
              if (u != null) ...[
                LegalFact('Unbilled time', formatMoney(u.time)),
                LegalFact('Unbilled fees', formatMoney(u.fee)),
                LegalFact('Unbilled expenses', formatMoney(u.disbursement)),
              ],
              LegalFact('Billed', formatMoney(m.billedTotal)),
              LegalFact('Received on bills', formatMoney(m.billedPaid)),
              if (m.advanceReceived > 0)
                LegalFact('Advance held', formatMoney(m.advanceReceived)),
              if (m.openTasks > 0)
                Text(
                  '${m.openTasks} open tasks',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Hearings extends ConsumerWidget {
  const _Hearings({required this.matter, required this.canWork});

  final Matter matter;
  final bool canWork;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hs = matter.hearings;
    return SectionCard(
      title: 'Hearings',
      icon: Icons.event_outlined,
      child: hs.isEmpty
          ? const Text('No hearings yet.')
          : Column(
              children: [
                for (final h in hs)
                  Padding(
                    key: ValueKey('h-${h.id}'),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${formatDate(h.date)}${h.purpose == null ? '' : ', ${h.purpose}'}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (h.court != null)
                                Text(
                                  h.court!,
                                  style: theme.textTheme.bodySmall,
                                ),
                              if (h.held)
                                Text(
                                  h.outcome ?? '',
                                  style: theme.textTheme.bodyMedium,
                                )
                              else
                                Text(
                                  'Not yet held',
                                  style: theme.textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                        if (!h.held && canWork)
                          TextButton(
                            onPressed: () => recordHearingOutcome(
                              context,
                              ref,
                              hearingId: h.id,
                              matterTitle: matter.title,
                              hearingDate: h.date,
                            ),
                            child: const Text('Record outcome'),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Tasks extends ConsumerWidget {
  const _Tasks({required this.matter, required this.canWork});

  final Matter matter;
  final bool canWork;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
    title: 'Tasks and deadlines',
    icon: Icons.checklist_outlined,
    child: AsyncValueView<List<LegalTask>>(
      value: ref.watch(legalTasksProvider(matter.id)),
      onRetry: () => ref.invalidate(legalTasksProvider(matter.id)),
      data: (tasks) => tasks.isEmpty
          ? const Text('No tasks yet.')
          : Column(
              children: [
                for (final t in tasks)
                  CheckboxListTile(
                    key: ValueKey('t-${t.id}'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: t.done,
                    onChanged: canWork
                        ? (on) async {
                            try {
                              await ref.read(legalRepositoryProvider).patchTask(
                                t.id,
                                {'status': on == true ? 'done' : 'open'},
                              );
                              ref.bumpLegal();
                            } catch (e) {
                              if (context.mounted) {
                                showErrorSnackBar(context, e);
                              }
                            }
                          }
                        : null,
                    title: Text(
                      t.title,
                      style: TextStyle(
                        decoration: t.done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    subtitle: Text(
                      [
                        taskKinds[t.kind],
                        t.overdue
                            ? 'Overdue since ${formatDate(t.dueDate)}'
                            : 'Due ${formatDate(t.dueDate)}',
                        t.assigneeName,
                      ].whereType<String>().join('  |  '),
                    ),
                  ),
              ],
            ),
    ),
  );
}

class _Entries extends ConsumerWidget {
  const _Entries({required this.matter, required this.canWork});

  final Matter matter;
  final bool canWork;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
    title: 'Time and expenses',
    icon: Icons.timer_outlined,
    child: AsyncValueView<List<Entry>>(
      value: ref.watch(legalEntriesProvider(matter.id)),
      onRetry: () => ref.invalidate(legalEntriesProvider(matter.id)),
      data: (entries) => entries.isEmpty
          ? const Text('No entries yet.')
          : Column(
              children: [
                for (final e in entries)
                  ListTile(
                    key: ValueKey('e-${e.id}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      e.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        formatDate(e.date),
                        e.kindLabel,
                        if (e.detail.isNotEmpty) e.detail,
                        if (!e.billable) 'Not billed to client',
                        if (e.billed) 'Billed ${e.invoiceNumber ?? ''}'.trim(),
                      ].join('  |  '),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(formatMoney(e.amount)),
                        if (canWork && !e.billed)
                          IconButton(
                            tooltip: 'Delete entry',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              try {
                                await ref
                                    .read(legalRepositoryProvider)
                                    .deleteEntry(e.id);
                                ref.bumpLegal();
                              } catch (err) {
                                if (context.mounted) {
                                  showErrorSnackBar(context, err);
                                }
                              }
                            },
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    ),
  );
}

class _Documents extends ConsumerWidget {
  const _Documents({required this.matter, required this.canWork});

  final Matter matter;
  final bool canWork;

  Future<void> _attach(BuildContext context, WidgetRef ref) async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png', 'webp'],
      );
      if (file == null) return;
      final ext = file.name.split('.').last.toLowerCase();
      final mime = switch (ext) {
        'pdf' => 'application/pdf',
        'png' => 'image/png',
        'webp' => 'image/webp',
        _ => 'image/jpeg',
      };
      await ref
          .read(legalRepositoryProvider)
          .attach(matter.id, await file.readAsBytes(), file.name, mime);
      ref.bumpLegal();
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
    title: 'Documents',
    icon: Icons.folder_outlined,
    trailing: canWork
        ? TextButton.icon(
            onPressed: () => _attach(context, ref),
            icon: const Icon(Icons.attach_file),
            label: const Text('Attach'),
          )
        : null,
    child: AsyncValueView<List<MatterDoc>>(
      value: ref.watch(legalDocsProvider(matter.id)),
      onRetry: () => ref.invalidate(legalDocsProvider(matter.id)),
      data: (docs) => docs.isEmpty
          ? const Text(
              'No documents attached. PDF and image files up to 10 MB.',
            )
          : Column(
              children: [
                for (final d in docs)
                  ListTile(
                    key: ValueKey('d-${d.id}'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.description_outlined),
                    title: Text(
                      d.label ?? d.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('${(d.size / 1024).ceil()} KB'),
                    trailing: canWork
                        ? IconButton(
                            tooltip: 'Remove from matter',
                            icon: const Icon(Icons.close),
                            onPressed: () async {
                              try {
                                await ref
                                    .read(legalRepositoryProvider)
                                    .removeDocument(d.id);
                                ref.bumpLegal();
                              } catch (e) {
                                if (context.mounted) {
                                  showErrorSnackBar(context, e);
                                }
                              }
                            },
                          )
                        : null,
                  ),
              ],
            ),
    ),
  );
}

class _BillsTab extends ConsumerWidget {
  const _BillsTab({required this.matter});

  final Matter matter;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
    title: 'Bills and receipts',
    icon: Icons.receipt_long_outlined,
    child: AsyncValueView<Bills>(
      value: ref.watch(legalBillsProvider(matter.id)),
      onRetry: () => ref.invalidate(legalBillsProvider(matter.id)),
      data: (b) => b.bills.isEmpty && b.receipts.isEmpty
          ? const Text('No bills yet.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final i in b.bills)
                  ListTile(
                    key: ValueKey('b-${i.invoiceId}'),
                    contentPadding: EdgeInsets.zero,
                    onTap: () => context.go('/invoices/${i.invoiceId}'),
                    title: Text('${i.number}  ${formatMoney(i.total)}'),
                    subtitle: Text(
                      [
                        formatDate(i.date),
                        if (i.status == 'cancelled')
                          'Cancelled'
                        else
                          i.due > 0.004 ? 'Due ${formatMoney(i.due)}' : 'Paid',
                        if (i.reverseCharge) 'Reverse charge',
                      ].join('  |  '),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                  ),
                for (final r in b.receipts)
                  ListTile(
                    key: ValueKey('r-${r.number}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text('${r.number}  ${formatMoney(r.amount)}'),
                    subtitle: Text(
                      '${formatDate(r.date)}  |  ${r.kind == 'advance' ? 'Advance' : 'Against a bill'}',
                    ),
                  ),
              ],
            ),
    ),
  );
}
