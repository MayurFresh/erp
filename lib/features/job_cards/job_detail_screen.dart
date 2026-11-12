import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
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
import '../construction/common/c_widgets.dart'
    show
        CGate,
        bigButton,
        bigOutlinedButton,
        confirm,
        showReasonDialog,
        showSuccess;
import '../items/item_picker.dart';
import '../memberships/pay_fields.dart';
import 'job_board_screen.dart';
import 'job_models.dart';
import 'job_pdf.dart';
import 'job_repository.dart';

/// `/job-cards/:id`: estimate, parts, status buttons and the bill.
class JobDetailScreen extends ConsumerWidget {
  const JobDetailScreen({super.key, required this.jobId});

  final String jobId;

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<Object?> Function() action, {
    String? done,
    bool money = false,
  }) async {
    try {
      await action();
      ref.bumpJobs(money: money);
      if (done != null && context.mounted) showSuccess(context, done);
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _addLine(
    BuildContext context,
    WidgetRef ref,
    JobDetail d,
    String kind,
  ) async {
    final item = await pickItem(context, ref, stockOnly: false);
    if (item == null || !context.mounted) return;
    final body = await showFormDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => _LineDialog(
        title: kind == 'part' ? 'Add part' : 'Add labour',
        name: item.name,
        rate: item.salePrice,
        unit: item.unit,
      ),
    );
    if (body == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref.read(jobRepositoryProvider).addLine(d.id, {
        'kind': kind,
        'itemId': item.id,
        ...body,
      }),
    );
  }

  Future<void> _status(
    BuildContext context,
    WidgetRef ref,
    JobDetail d,
    String next,
  ) async {
    final body = <String, Object?>{'status': next};
    if (next == 'approved') {
      final by = await showFormDialog<String>(
        context: context,
        builder: (_) => const _ApprovalDialog(),
      );
      if (by == null) return;
      if (by.isNotEmpty) body['approvedBy'] = by;
    } else if (next == 'cancelled') {
      final reason = await showReasonDialog(
        context,
        title: 'Cancel this job?',
        message: 'Give a reason. Issued parts stay in stock.',
        confirmLabel: 'Cancel job',
        cancelLabel: 'Keep job',
      );
      if (reason == null) return;
      body['reason'] = reason;
    } else if (next == 'delivered' && (d.invoice?.balance ?? 0) > 0.004) {
      final ok = await confirm(
        context,
        title: 'Deliver with a balance?',
        message: '${formatMoney(d.invoice!.balance)} is still unpaid.',
        confirmLabel: 'Deliver',
      );
      if (!ok) return;
    }
    if (!context.mounted) return;
    await _run(
      context,
      ref,
      () => ref.read(jobRepositoryProvider).setStatus(d.id, body),
    );
  }

  Future<void> _bill(BuildContext context, WidgetRef ref, JobDetail d) async {
    final out = await showFormDialog<bool>(
      context: context,
      builder: (_) => _BillDialog(job: d),
    );
    if (out != true) return;
    ref.bumpJobs(money: true);
    if (context.mounted) showSuccess(context, 'Bill created');
  }

  Future<void> _receipt(
    BuildContext context,
    WidgetRef ref,
    JobDetail d,
  ) async {
    final out = await showFormDialog<bool>(
      context: context,
      builder: (_) => _ReceiptDialog(job: d),
    );
    if (out != true) return;
    ref.bumpJobs(money: true);
    if (context.mounted) showSuccess(context, 'Receipt saved');
  }

  Future<void> _pdf(
    BuildContext context,
    WidgetRef ref,
    JobDetail d,
    bool estimate,
  ) async {
    try {
      Company? company;
      try {
        company = await ref.read(companyRepositoryProvider).get();
      } catch (_) {
        company = ref.read(sessionProvider).value?.company;
      }
      final brand = company == null
          ? null
          : await loadPdfBrand(ref.read(apiClientProvider), company);
      final theme = await pdfTheme();
      final bytes = estimate
          ? await buildJobEstimatePdf(d, brand: brand, theme: theme)
          : await buildJobIntakePdf(d, brand: brand, theme: theme);
      await Printing.layoutPdf(
        onLayout: (_) async => Uint8List.fromList(bytes),
        name: jobPdfName(d, estimate ? 'estimate' : 'job-card'),
        format: estimate ? PdfPageFormat.a4 : PdfPageFormat.a5,
      );
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final front = perms.canAny(const [
      Perm.jobCardsCreate,
      Perm.jobCardsManage,
    ]);
    final detail = ref.watch(jobDetailProvider(jobId));
    return CGate(
      anyOf: const [
        Perm.jobCardsView,
        Perm.jobCardsCreate,
        Perm.jobCardsWork,
        Perm.jobCardsManage,
      ],
      child: AsyncValueView<JobDetail>(
        value: detail,
        onRetry: () => ref.invalidate(jobDetailProvider(jobId)),
        data: (d) {
          final techs =
              ref.watch(technicianListProvider).value ?? const <Technician>[];
          final closed = d.status == 'delivered' || d.status == 'cancelled';
          final canWork = front || perms.can(Perm.jobCardsWork);
          final actions = <Widget>[
            for (final next in d.nextStatuses.where((n) {
              if (n == 'in_progress' || n == 'ready') return canWork;
              return front;
            }))
              next == 'cancelled'
                  ? OutlinedButton(
                      style: bigOutlinedButton,
                      onPressed: () => _status(context, ref, d, next),
                      child: Text(jobActionLabel(next)),
                    )
                  : FilledButton(
                      style: bigButton,
                      key: ValueKey('status-$next'),
                      onPressed: next == 'delivered' && d.invoice == null
                          ? null
                          : () => _status(context, ref, d, next),
                      child: Text(
                        next == 'in_progress' && d.status == 'ready'
                            ? 'Reopen'
                            : jobActionLabel(next),
                      ),
                    ),
            if (d.status == 'in_progress' && canWork && d.hasUnissuedParts)
              OutlinedButton.icon(
                style: bigOutlinedButton,
                onPressed: () => _run(
                  context,
                  ref,
                  () => ref.read(jobRepositoryProvider).issueParts(d.id),
                  done: 'Parts issued',
                ),
                icon: const Icon(Icons.inventory_2_outlined),
                label: const Text('Issue parts'),
              ),
            if (d.status == 'ready' &&
                d.invoice == null &&
                front &&
                perms.can(Perm.invoicesCreate))
              FilledButton.icon(
                style: bigButton,
                onPressed: () => _bill(context, ref, d),
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('Make bill'),
              ),
            if (d.invoice != null &&
                d.invoice!.balance > 0.004 &&
                front &&
                perms.can(Perm.paymentsCreate) &&
                d.status != 'cancelled')
              OutlinedButton.icon(
                style: bigOutlinedButton,
                onPressed: () => _receipt(context, ref, d),
                icon: const Icon(Icons.payments_outlined),
                label: Text('Receive ${formatMoney(d.invoice!.balance)}'),
              ),
          ];
          final gutter = pageGutter(context);
          return ListView(
            padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      d.asset,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  JobStatusChip(d.status),
                ],
              ),
              Text(
                '${d.number}  |  ${d.customerName}${d.customerPhone == null ? '' : '  |  ${d.customerPhone}'}',
              ),
              const SizedBox(height: 12),
              if (actions.isNotEmpty)
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              const SizedBox(height: 12),
              SectionCard(
                title: 'Job',
                child: Wrap(
                  spacing: 32,
                  runSpacing: 12,
                  children: [
                    LabeledValue('Complaints', d.complaints),
                    if (d.accessories != null)
                      LabeledValue('Received with it', d.accessories!),
                    if (d.isVehicle && d.odometer != null)
                      LabeledValue('Odometer', '${d.odometer} km'),
                    if (!d.isVehicle && d.serialNo != null)
                      LabeledValue('Serial / IMEI', d.serialNo!),
                    LabeledValue(
                      'Promised',
                      d.promisedDate == null ? '' : formatDate(d.promisedDate),
                    ),
                    if (d.approvedAt != null)
                      LabeledValue(
                        'Approved',
                        d.approvedBy ?? formatDate(d.approvedAt),
                      ),
                  ],
                ),
              ),
              if (front && !closed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: DropdownButtonFormField<String?>(
                    key: ValueKey('tech-${d.technicianId}'),
                    initialValue: techs.any((t) => t.id == d.technicianId)
                        ? d.technicianId
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Technician'),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Not assigned'),
                      ),
                      for (final t in techs)
                        DropdownMenuItem<String?>(
                          value: t.id,
                          child: Text(t.name),
                        ),
                    ],
                    onChanged: (v) => _run(
                      context,
                      ref,
                      () => ref.read(jobRepositoryProvider).update(d.id, {
                        'technicianId': v,
                        'expectedUpdatedAt': d.updatedAt,
                      }),
                    ),
                  ),
                )
              else if (d.technicianName != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('Technician: ${d.technicianName}'),
                ),
              SectionCard(
                title: 'Estimate, parts and labour',
                trailing: d.canEditLines && canWork
                    ? Wrap(
                        spacing: 4,
                        children: [
                          TextButton.icon(
                            onPressed: () => _addLine(context, ref, d, 'part'),
                            icon: const Icon(Icons.add),
                            label: const Text('Part'),
                          ),
                          TextButton.icon(
                            onPressed: () =>
                                _addLine(context, ref, d, 'labour'),
                            icon: const Icon(Icons.add),
                            label: const Text('Labour'),
                          ),
                        ],
                      )
                    : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (d.lines.isEmpty)
                      const Text('No parts or labour added yet.'),
                    for (final l in d.lines)
                      ListTile(
                        key: ValueKey('line-${l.id}'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          l.isPart
                              ? Icons.settings_outlined
                              : Icons.handyman_outlined,
                        ),
                        title: Text(l.itemName),
                        subtitle: Text(
                          '${formatQty(l.qty)} ${l.unit} x ${formatMoney(l.rate)}'
                          '${l.discountPct > 0 ? '  |  ${formatPlain(l.discountPct)}% off' : ''}'
                          '${l.isPart ? (l.issued ? '  |  issued' : '  |  not issued') : ''}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(formatMoney(l.amount)),
                            if (d.canEditLines && canWork && !l.issued)
                              IconButton(
                                tooltip: 'Remove ${l.itemName}',
                                onPressed: () => _run(
                                  context,
                                  ref,
                                  () => ref
                                      .read(jobRepositoryProvider)
                                      .removeLine(d.id, l.id),
                                ),
                                icon: const Icon(Icons.close),
                              ),
                          ],
                        ),
                      ),
                    const Divider(),
                    _TotalLine('Parts', d.totals.parts),
                    _TotalLine('Labour', d.totals.labour),
                    _TotalLine('Tax', d.totals.tax),
                    _TotalLine('Total', d.totals.total, strong: true),
                  ],
                ),
              ),
              if (d.invoice != null)
                SectionCard(
                  title: 'Bill',
                  child: Wrap(
                    spacing: 32,
                    runSpacing: 12,
                    children: [
                      LabeledValue('Number', d.invoice!.number),
                      LabeledValue('Total', formatMoney(d.invoice!.total)),
                      LabeledValue('Paid', formatMoney(d.invoice!.amountPaid)),
                      LabeledValue('Balance', formatMoney(d.invoice!.balance)),
                    ],
                  ),
                ),
              SectionCard(
                title: 'Message for the customer',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.statusMessage),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: d.statusMessage),
                            );
                            if (context.mounted) {
                              showSuccess(context, 'Message copied');
                            }
                          },
                          icon: const Icon(Icons.copy_outlined),
                          label: const Text('Copy message'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _pdf(context, ref, d, false),
                          icon: const Icon(Icons.print_outlined),
                          label: const Text('Job card slip'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _pdf(context, ref, d, true),
                          icon: const Icon(Icons.description_outlined),
                          label: const Text('Estimate PDF'),
                        ),
                        if (d.invoice != null)
                          TextButton(
                            onPressed: () =>
                                context.go('/invoices/${d.invoice!.id}'),
                            child: const Text('Open bill'),
                          ),
                      ],
                    ),
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

class _TotalLine extends StatelessWidget {
  const _TotalLine(this.label, this.value, {this.strong = false});

  final String label;
  final double value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final style = strong ? Theme.of(context).textTheme.titleSmall : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(formatMoney(value), style: style),
        ],
      ),
    );
  }
}

class _LineDialog extends StatefulWidget {
  const _LineDialog({
    required this.title,
    required this.name,
    required this.rate,
    required this.unit,
  });

  final String title;
  final String name;
  final double rate;
  final String unit;

  @override
  State<_LineDialog> createState() => _LineDialogState();
}

class _LineDialogState extends State<_LineDialog> {
  final _formKey = GlobalKey<FormState>();
  final _qty = TextEditingController(text: '1');
  late final _rate = TextEditingController(text: formatPlain(widget.rate));
  final _disc = TextEditingController();

  @override
  void dispose() {
    _qty.dispose();
    _rate.dispose();
    _disc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 420,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.name, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            FormRow(
              minCellWidth: 120,
              children: [
                TextFormField(
                  controller: _qty,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput(decimals: 3)],
                  decoration: InputDecoration(
                    labelText: 'Qty (${widget.unit})',
                  ),
                  validator: (v) => requiredNumber(v, label: 'Qty', min: 0.001),
                ),
                TextFormField(
                  controller: _rate,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  decoration: const InputDecoration(labelText: 'Rate'),
                  validator: (v) => requiredNumber(v, label: 'Rate', min: 0),
                ),
                TextFormField(
                  controller: _disc,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  decoration: const InputDecoration(labelText: 'Discount %'),
                  validator: (v) => optionalNumber(v, min: 0, max: 100),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (!validateAndReveal(_formKey)) return;
          Navigator.of(context).pop(<String, Object?>{
            'qty': parseNumber(_qty.text),
            'rate': parseNumber(_rate.text),
            if ((parseNumber(_disc.text) ?? 0) > 0)
              'discountPct': parseNumber(_disc.text),
          });
        },
        child: const Text('Add'),
      ),
    ],
  );
}

class _ApprovalDialog extends StatefulWidget {
  const _ApprovalDialog();

  @override
  State<_ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<_ApprovalDialog> {
  final _by = TextEditingController();

  @override
  void dispose() {
    _by.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Record approval'),
    content: SizedBox(
      width: 420,
      child: TextField(
        controller: _by,
        decoration: const InputDecoration(
          labelText: 'Approved by',
          helperText: 'Name, and how: in person, phone, message',
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_by.text.trim()),
        child: const Text('Approved'),
      ),
    ],
  );
}

class _BillDialog extends ConsumerStatefulWidget {
  const _BillDialog({required this.job});

  final JobDetail job;

  @override
  ConsumerState<_BillDialog> createState() => _BillDialogState();
}

class _BillDialogState extends ConsumerState<_BillDialog> {
  final _pay = PayController();
  bool _saving = false;

  @override
  void dispose() {
    _pay.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final payment = ref.read(permissionsProvider).can(Perm.paymentsCreate)
        ? _pay.body()
        : null;
    setState(() => _saving = true);
    try {
      await ref.read(jobRepositoryProvider).bill(widget.job.id, {
        'payment': ?payment,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPay = ref.watch(permissionsProvider).can(Perm.paymentsCreate);
    final j = widget.job;
    return AlertDialog(
      title: const Text('Make the bill'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Parts ${formatMoney(j.totals.parts)}, labour ${formatMoney(j.totals.labour)}, tax ${formatMoney(j.totals.tax)}.',
              ),
              Text(
                'Total ${formatMoney(j.totals.total)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              const Text(
                'Unissued parts are taken from stock when the bill is made.',
              ),
              if (canPay) ...[
                const SizedBox(height: 12),
                PayFields(controller: _pay, helper: 'Leave empty to bill only'),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        BusyButton(
          busy: _saving,
          onPressed: _saving ? null : _save,
          label: 'Create bill',
        ),
      ],
    );
  }
}

class _ReceiptDialog extends ConsumerStatefulWidget {
  const _ReceiptDialog({required this.job});

  final JobDetail job;

  @override
  ConsumerState<_ReceiptDialog> createState() => _ReceiptDialogState();
}

class _ReceiptDialogState extends ConsumerState<_ReceiptDialog> {
  final _pay = PayController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _pay.amount.text = formatPlain(widget.job.invoice!.balance);
  }

  @override
  void dispose() {
    _pay.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final body = _pay.body();
    if (body == null || _pay.accountId == null) {
      showErrorSnackBar(context, 'Enter the amount and the account.');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(jobRepositoryProvider).receipt(widget.job.id, body);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Receive payment'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(child: PayFields(controller: _pay)),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      BusyButton(
        busy: _saving,
        onPressed: _saving ? null : _save,
        label: 'Receive',
      ),
    ],
  );
}
