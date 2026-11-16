import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../core/whatsapp.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/money_text.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import '../documents/document_widgets.dart';
import '../parties/parties_repository.dart';
import '../reports/pdf_actions.dart';
import '../sales_orders/o2c_repository.dart';
import 'quotation_models.dart';
import 'quotation_pdf.dart';
import 'quotation_repository.dart';

/// Plain-words text of a WhatsApp message that goes with the PDF.
String quotationWhatsAppText({
  required String companyName,
  required Quotation quotation,
  String? contactName,
}) {
  final q = quotation;
  return [
    'Hello${contactName == null ? '' : ' $contactName'},',
    '${kindLabel(q.kind)} ${q.number} from $companyName',
    'Total ${formatMoney(q.total)}',
    if (q.validUntil != null) 'Valid until ${formatDate(q.validUntil)}',
    'The PDF is attached.',
  ].join('\n');
}

class QuotationDetailScreen extends ConsumerWidget {
  const QuotationDetailScreen({super.key, required this.quotationId});

  final String quotationId;

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<Object?> Function() action,
    String done,
  ) async {
    try {
      await action();
      ref.read(quotationRevisionProvider.notifier).bump();
      if (context.mounted) showInfoSnackBar(context, done);
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _send(BuildContext context, WidgetRef ref, Quotation q) async {
    try {
      await ref.read(quotationRepositoryProvider).action(q.id, 'send');
      ref.read(quotationRevisionProvider.notifier).bump();
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
      return;
    }
    if (!context.mounted) return;
    await _share(context, ref, q);
  }

  /// The phone of the quotation's contact person, else the customer's.
  Future<String?> _phone(WidgetRef ref, Quotation q) async {
    final repo = ref.read(partiesRepositoryProvider);
    try {
      if (q.contactId != null) {
        final contacts = await repo.contacts(q.partyId);
        for (final c in contacts) {
          if (c.id == q.contactId && (c.phone ?? '').isNotEmpty) return c.phone;
        }
      }
      return (await repo.get(q.partyId)).phone;
    } catch (_) {
      return null;
    }
  }

  Future<void> _share(BuildContext context, WidgetRef ref, Quotation q) async {
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Share ${q.number}'),
        scrollable: true,
        content: const Text(
          'Share the PDF first, then send the WhatsApp message to the '
          'customer. The message does not carry the file.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: const Text('Close'),
          ),
          OutlinedButton.icon(
            onPressed: () => _sharePdf(context, ref, q),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Share PDF'),
          ),
          FilledButton.icon(
            onPressed: () => _whatsApp(context, ref, q),
            icon: const Icon(Icons.chat_outlined),
            label: const Text('WhatsApp message'),
          ),
        ],
      ),
    );
  }

  Future<void> _sharePdf(
    BuildContext context,
    WidgetRef ref,
    Quotation q,
  ) async {
    try {
      final p = await loadPdfContext(ref);
      final bytes = await buildQuotationPdf(
        q,
        p.company,
        party: await p.party(q.partyId),
        brand: p.brand,
        theme: p.theme,
      );
      await Printing.sharePdf(bytes: bytes, filename: quotationFileName(q));
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _whatsApp(
    BuildContext context,
    WidgetRef ref,
    Quotation q,
  ) async {
    Company? company;
    try {
      company = await ref.read(companyRepositoryProvider).get();
    } catch (_) {
      company = ref.read(sessionProvider).value?.company;
    }
    final phone = await _phone(ref, q);
    String? contactName;
    if (q.contactId != null) {
      try {
        final contacts = await ref
            .read(partiesRepositoryProvider)
            .contacts(q.partyId);
        contactName = contacts
            .where((c) => c.id == q.contactId)
            .map((c) => c.name)
            .firstOrNull;
      } catch (_) {}
    }
    final uri = whatsAppUri(
      phone: phone,
      text: quotationWhatsAppText(
        companyName: company?.name ?? '',
        quotation: q,
        contactName: contactName,
      ),
    );
    try {
      final opened = await openWhatsApp(uri);
      if (!opened && context.mounted) {
        showInfoSnackBar(context, 'Could not open WhatsApp.');
      }
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _decline(
    BuildContext context,
    WidgetRef ref,
    Quotation q,
  ) async {
    final reason = await showFormDialog<String>(
      context: context,
      builder: (_) => CancelReasonDialog(
        title: 'Decline ${q.number}?',
        message: 'Note why the customer said no. It stays on the record.',
        confirmLabel: 'Decline',
        keepLabel: 'Back',
      ),
    );
    if (reason == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref
          .read(quotationRepositoryProvider)
          .action(q.id, 'decline', reason: reason),
      '${q.number} declined',
    );
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref, Quotation q) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Cancel ${q.number}?'),
        content: const Text('A cancelled quotation cannot be used again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: const Text('Cancel quotation'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref.read(quotationRepositoryProvider).action(q.id, 'cancel'),
      '${q.number} cancelled',
    );
  }

  Future<void> _revise(BuildContext context, WidgetRef ref, Quotation q) async {
    try {
      final n = await ref
          .read(quotationRepositoryProvider)
          .action(q.id, 'revise');
      ref.read(quotationRevisionProvider.notifier).bump();
      if (!context.mounted) return;
      showInfoSnackBar(context, 'Revision ${n.number} created as a draft');
      context.go('/quotations/${n.id}');
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _convert(
    BuildContext context,
    WidgetRef ref,
    Quotation q,
    String to,
  ) async {
    final target = to == 'invoice' ? 'an invoice' : 'a sales order';
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Convert ${q.number}?'),
        content: Text(
          'This creates $target for ${q.partyName} from these items. '
          'The quotation is marked converted and cannot be edited.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: Text(to == 'invoice' ? 'Create invoice' : 'Create order'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final r = await ref.read(quotationRepositoryProvider).convert(q.id, to);
      ref.read(quotationRevisionProvider.notifier).bump();
      ref.read(o2cRevisionProvider.notifier).bump();
      ref.bump(const [DataKind.invoices, DataKind.stock, DataKind.parties]);
      if (!context.mounted) return;
      if (r.salesOrderId != null) {
        showInfoSnackBar(context, 'Sales order created from ${q.number}');
        context.go('/sales-orders/${r.salesOrderId}');
      } else if (r.invoiceId != null) {
        showInfoSnackBar(context, 'Invoice created from ${q.number}');
        context.go('/invoices/${r.invoiceId}');
      }
    } catch (e) {
      if (!context.mounted) return;
      if (apiError(e)?.code == 'NOT_STOCK_ITEMS') {
        await _notStock(context, ref, q);
      } else {
        showErrorSnackBar(context, e);
      }
    }
  }

  Future<void> _notStock(
    BuildContext context,
    WidgetRef ref,
    Quotation q,
  ) async {
    final canInvoice = ref.read(permissionsProvider).can(Perm.invoicesCreate);
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Cannot make a sales order'),
        content: Text(
          'A sales order can hold only items that you keep in stock. This '
          'quotation has service items or items without stock tracking.'
          '${canInvoice ? ' You can convert it to an invoice instead.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: const Text('Close'),
          ),
          if (canInvoice)
            FilledButton(
              onPressed: () => Navigator.of(d).pop(true),
              child: const Text('Convert to invoice'),
            ),
        ],
      ),
    );
    if (go == true && context.mounted) {
      await _convert(context, ref, q, 'invoice');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final repo = ref.read(quotationRepositoryProvider);
    return AsyncValueView(
      value: ref.watch(quotationProvider(quotationId)),
      onRetry: () => ref.invalidate(quotationProvider(quotationId)),
      data: (q) {
        final manage = perms.can(Perm.quotationsManage);
        final open = q.status == 'draft' || q.status == 'sent';
        final toOrder =
            manage && q.canConvert && perms.can(Perm.salesOrdersManage);
        final toInvoice =
            manage && q.canConvert && perms.can(Perm.invoicesCreate);
        final word = quotationStatuses[q.statusWord] ?? q.statusWord;
        return FormPage(
          maxWidth: 1100,
          children: [
            DocHeader(
              title: q.number,
              pills: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  StatusChip(q.statusWord, label: word),
                  Pill(kindLabel(q.kind)),
                ],
              ),
              actions: [
                ...pdfDocActions(
                  context,
                  ref,
                  fileName: quotationFileName(q),
                  build: (p) async => buildQuotationPdf(
                    q,
                    p.company,
                    party: await p.party(q.partyId),
                    brand: p.brand,
                    theme: p.theme,
                  ),
                ),
                if (manage && q.status == 'draft')
                  DocAction(
                    label: 'Send',
                    icon: Icons.send_outlined,
                    primary: true,
                    onPressed: () => _send(context, ref, q),
                  ),
                if (q.status == 'sent')
                  DocAction(
                    label: 'Share again',
                    icon: Icons.share_outlined,
                    onPressed: () => _share(context, ref, q),
                  ),
                if (manage && q.status == 'sent')
                  DocAction(
                    label: 'Accept',
                    icon: Icons.check_circle_outline,
                    primary: true,
                    onPressed: () => _run(
                      context,
                      ref,
                      () => repo.action(q.id, 'accept'),
                      '${q.number} accepted',
                    ),
                  ),
                if (manage && q.status == 'sent')
                  DocAction(
                    label: 'Decline',
                    icon: Icons.thumb_down_outlined,
                    onPressed: () => _decline(context, ref, q),
                  ),
                if (toOrder)
                  DocAction(
                    label: 'Convert to sales order',
                    icon: Icons.shopping_bag_outlined,
                    primary: q.status == 'accepted',
                    onPressed: () => _convert(context, ref, q, 'sales_order'),
                  ),
                if (toInvoice)
                  DocAction(
                    label: 'Convert to invoice',
                    icon: Icons.receipt_long_outlined,
                    onPressed: () => _convert(context, ref, q, 'invoice'),
                  ),
                if (manage && open)
                  DocAction(
                    label: 'Edit',
                    icon: Icons.edit_outlined,
                    onPressed: () => context.go('/quotations/${q.id}/edit'),
                  ),
                if (manage &&
                    (q.status == 'sent' ||
                        q.status == 'accepted' ||
                        q.status == 'declined'))
                  DocAction(
                    label: 'Revise',
                    icon: Icons.history_edu_outlined,
                    onPressed: () => _revise(context, ref, q),
                  ),
                if (manage && q.canCancel)
                  DocAction(
                    label: 'Cancel',
                    icon: Icons.block,
                    destructive: true,
                    onPressed: () => _cancel(context, ref, q),
                  ),
              ],
              facts: [
                LabeledValue('Customer', q.partyName),
                LabeledValue('Date', formatDate(q.quoteDate)),
                LabeledValue('Valid until', formatDate(q.validUntil)),
                if (q.locationName.isNotEmpty)
                  LabeledValue('Location', q.locationName),
                LabeledValue('Total', formatMoney(q.total)),
              ],
            ),
            if (q.expired && open)
              SectionCard(
                title: 'Expired',
                child: Text(
                  'The valid date, ${formatDate(q.validUntil)}, has passed. '
                  'Revise it with a new date if the customer is still '
                  'interested.',
                ),
              ),
            if (q.status == 'declined' && q.declineReason != null)
              SectionCard(title: 'Declined', child: Text(q.declineReason!)),
            if (q.salesOrderId != null ||
                q.invoiceId != null ||
                q.revisionOf != null)
              SectionCard(
                title: 'Linked documents',
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (q.salesOrderId != null)
                      OutlinedButton(
                        onPressed: () =>
                            context.go('/sales-orders/${q.salesOrderId}'),
                        child: const Text('Open sales order'),
                      ),
                    if (q.invoiceId != null)
                      OutlinedButton(
                        onPressed: () => context.go('/invoices/${q.invoiceId}'),
                        child: const Text('Open invoice'),
                      ),
                    if (q.revisionOf != null)
                      OutlinedButton(
                        onPressed: () =>
                            context.go('/quotations/${q.revisionOf}'),
                        child: const Text('Open earlier version'),
                      ),
                  ],
                ),
              ),
            SectionCard(
              title: 'Items',
              child: _Lines(quotation: q),
            ),
            SectionCard(
              title: 'Totals',
              child: _Totals(quotation: q),
            ),
            if ((q.notes ?? '').isNotEmpty)
              SectionCard(title: 'Notes', child: Text(q.notes!)),
            if ((q.terms ?? '').isNotEmpty)
              SectionCard(title: 'Terms', child: Text(q.terms!)),
          ],
        );
      },
    );
  }
}

String _discount(QuotationLine l) => l.discountAmount > 0
    ? formatMoney(l.discountAmount)
    : l.discountPct > 0
    ? formatPercent(l.discountPct)
    : '';

class _Lines extends StatelessWidget {
  const _Lines({required this.quotation});

  final Quotation quotation;

  @override
  Widget build(BuildContext context) {
    final lines = quotation.lines;
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 760) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: c.maxWidth),
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Item')),
                  DataColumn(label: Text('Quantity'), numeric: true),
                  DataColumn(label: Text('Rate'), numeric: true),
                  DataColumn(label: Text('Discount'), numeric: true),
                  DataColumn(label: Text('Before tax'), numeric: true),
                  DataColumn(label: Text('GST'), numeric: true),
                  DataColumn(label: Text('Total'), numeric: true),
                ],
                rows: [
                  for (final l in lines)
                    DataRow(
                      cells: [
                        DataCell(Text(l.itemName)),
                        DataCell(Text('${formatQty(l.qty)} ${l.unit}')),
                        DataCell(MoneyText(l.rate)),
                        DataCell(Text(_discount(l))),
                        DataCell(MoneyText(l.taxable)),
                        DataCell(
                          Text(
                            '${formatPercent(l.gstRate)}  ${formatMoney(l.tax)}',
                          ),
                        ),
                        DataCell(MoneyText(l.total)),
                      ],
                    ),
                ],
              ),
            ),
          );
        }
        final theme = Theme.of(context);
        return Column(
          children: [
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.itemName, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 20,
                      runSpacing: 8,
                      children: [
                        LabeledValue(
                          'Quantity',
                          '${formatQty(l.qty)} ${l.unit}',
                        ),
                        LabeledValue('Rate', formatMoney(l.rate)),
                        if (_discount(l).isNotEmpty)
                          LabeledValue('Discount', _discount(l)),
                        LabeledValue(
                          'GST',
                          '${formatPercent(l.gstRate)}  ${formatMoney(l.tax)}',
                        ),
                        LabeledValue('Total', formatMoney(l.total)),
                      ],
                    ),
                    const Divider(height: 16),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.quotation});

  final Quotation quotation;

  @override
  Widget build(BuildContext context) {
    final q = quotation;
    final t = q.taxSplit;
    final theme = Theme.of(context);
    Widget row(String label, double amount, {bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: strong ? theme.textTheme.titleSmall : null,
            ),
          ),
          MoneyText(
            amount,
            style: strong
                ? theme.textTheme.titleMedium
                : theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          children: [
            row('Amount before tax', q.subtotal),
            if (t.cgst > 0) row('CGST', t.cgst),
            if (t.sgst > 0) row('SGST', t.sgst),
            if (t.igst > 0) row('IGST', t.igst),
            if (t.cgst + t.sgst + t.igst == 0 && q.taxTotal > 0)
              row('Tax', q.taxTotal),
            const Divider(),
            row('Total', q.total, strong: true),
          ],
        ),
      ),
    );
  }
}
