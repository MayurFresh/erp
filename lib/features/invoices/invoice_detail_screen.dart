import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/india_states.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import '../parties/parties_repository.dart';
import '../parties/party_model.dart';
import 'invoice_model.dart';
import 'invoice_pdf.dart';
import 'invoice_widgets.dart';
import 'invoices_repository.dart';

class InvoiceDetailScreen extends ConsumerWidget {
  const InvoiceDetailScreen({super.key, required this.invoiceId});

  final String invoiceId;

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    Invoice invoice,
  ) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => CancelReasonDialog(
        title: 'Cancel ${invoice.number ?? 'invoice'}?',
        message:
            'The invoice keeps its number and stock is returned to the '
            'location. This cannot be undone.',
        confirmLabel: 'Cancel invoice',
        keepLabel: 'Keep invoice',
      ),
    );
    if (reason == null || !context.mounted) return;
    try {
      await ref.read(invoicesRepositoryProvider).cancel(invoiceId, reason);
      ref.bump(const [DataKind.invoices, DataKind.stock, DataKind.parties]);
      if (context.mounted) {
        showInfoSnackBar(context, 'Invoice ${invoice.number} cancelled');
      }
    } catch (e) {
      if (!context.mounted) return;
      if (isCancelBlocked(e)) {
        await showCancelBlocked(
          context,
          e,
          document: 'invoice',
          settlements: invoice.settlements ?? const [],
        );
      } else {
        showErrorSnackBar(context, e);
      }
    }
  }

  /// Company profile (falls back to the membership from `/me`) and the
  /// party's address when the user may read parties.
  Future<Uint8List> _pdf(WidgetRef ref, Invoice invoice) async {
    Company? company;
    try {
      company = await ref.read(companyRepositoryProvider).get();
    } catch (_) {
      company = ref.read(sessionProvider).value?.company;
    }
    Party? party;
    if (ref.read(permissionsProvider).can(Perm.partiesView)) {
      try {
        party = await ref.read(partiesRepositoryProvider).get(invoice.partyId);
      } catch (_) {
        // The PDF still has the name and GSTIN from the invoice.
      }
    }
    return buildInvoicePdf(
      invoice,
      company ?? const Company(id: '', name: 'Company', stateCode: ''),
      party: party,
    );
  }

  Future<void> _print(
    BuildContext context,
    WidgetRef ref,
    Invoice invoice,
  ) async {
    try {
      final bytes = await _pdf(ref, invoice);
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: invoiceFileName(invoice),
        format: PdfPageFormat.a4,
      );
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _share(
    BuildContext context,
    WidgetRef ref,
    Invoice invoice,
  ) async {
    try {
      final bytes = await _pdf(ref, invoice);
      await Printing.sharePdf(bytes: bytes, filename: invoiceFileName(invoice));
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _whatsApp(
    BuildContext context,
    WidgetRef ref,
    Invoice invoice,
  ) async {
    final company = ref.read(sessionProvider).value?.company?.name ?? '';
    final uri = whatsAppShareUri(
      invoiceShareText(invoice, companyName: company),
    );
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && context.mounted) {
        showInfoSnackBar(context, 'Could not open WhatsApp.');
      }
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return AsyncValueView(
      value: ref.watch(invoiceProvider(invoiceId)),
      onRetry: () => ref.invalidate(invoiceProvider(invoiceId)),
      data: (invoice) {
        final posted = invoice.status == DocStatus.posted;
        final due = invoice.amountDue;
        final canReceive =
            posted &&
            perms.can(Perm.paymentsCreate) &&
            (due == null || due > 0);
        final canReturn =
            posted &&
            perms.can(Perm.creditNotesCreate) &&
            invoice.hasReturnableQty;
        final actions = [
          if (canReceive)
            DocAction(
              label: 'Record receipt',
              icon: Icons.payments_outlined,
              primary: true,
              onPressed: () => context.push(
                Uri(
                  path: '/receipts/new',
                  queryParameters: {
                    'partyId': invoice.partyId,
                    'docId': invoiceId,
                    if (due != null) 'amount': formatPlain(due),
                  },
                ).toString(),
              ),
            ),
          DocAction(
            label: 'Print',
            icon: Icons.print_outlined,
            primary: true,
            onPressed: () => _print(context, ref, invoice),
          ),
          DocAction(
            label: 'Download / share PDF',
            icon: Icons.ios_share,
            onPressed: () => _share(context, ref, invoice),
          ),
          DocAction(
            label: 'Share on WhatsApp',
            icon: Icons.chat_outlined,
            onPressed: () => _whatsApp(context, ref, invoice),
          ),
          if (canReturn)
            DocAction(
              label: 'Create credit note',
              icon: Icons.assignment_return_outlined,
              onPressed: () =>
                  context.push('/credit-notes/new?invoiceId=$invoiceId'),
            ),
          if (posted && perms.can(Perm.invoicesCancel))
            DocAction(
              label: 'Cancel invoice',
              icon: Icons.block,
              destructive: true,
              onPressed: () => _cancel(context, ref, invoice),
            ),
        ];
        final settlements = invoice.settlements;
        final lines = invoice.lines ?? const <InvoiceLine>[];
        return FormPage(
          maxWidth: 1100,
          children: [
            DocHeader(
              title: invoice.number ?? 'Invoice',
              pills: DocPills(
                status: invoice.status,
                paymentStatus: invoice.paymentStatus,
              ),
              actions: actions,
              facts: [
                LabeledValue('Date', formatDate(invoice.invoiceDate)),
                if (invoice.dueDate != null)
                  LabeledValue('Due date', _dueLabel(invoice)),
                LabeledValue('Location', invoice.locationName),
                LabeledValue('Total', formatMoney(invoice.total)),
                if (due != null && posted)
                  LabeledValue('Amount due', formatMoney(due)),
                if (invoice.createdBy != null)
                  LabeledValue(
                    'Created by',
                    '${invoice.createdBy!.name} · '
                        '${formatDateTime(invoice.createdAt)}',
                  ),
              ],
            ),
            if (invoice.isCancelled)
              CancelledBanner(
                cancelledAt: invoice.cancelledAt,
                reason: invoice.cancelReason,
              ),
            FormRow(
              breakpoint: 760,
              children: [
                SectionCard(
                  title: 'Bill to',
                  child: Wrap(
                    spacing: 32,
                    runSpacing: 12,
                    children: [
                      LabeledValue('Party', invoice.partyName),
                      LabeledValue('GSTIN', invoice.partyGstin ?? ''),
                      LabeledValue(
                        'Place of supply',
                        stateLabel(invoice.placeOfSupply),
                      ),
                      LabeledValue(
                        'Supply type',
                        invoice.isInterState
                            ? 'Inter-state (IGST)'
                            : 'Intra-state (CGST + SGST)',
                      ),
                    ],
                  ),
                ),
                SectionCard(
                  title: 'Totals',
                  child: TaxTotals(
                    summary: invoice,
                    amountPaid: posted ? invoice.amountPaid : null,
                    amountDue: posted ? invoice.amountDue : null,
                  ),
                ),
              ],
            ),
            if (settlements != null)
              SectionCard(
                title: 'Receipts & credit notes',
                child: SettlementsList(
                  settlements: settlements,
                  canOpen: (s) => perms.can(
                    s.kind == 'credit_note'
                        ? Perm.creditNotesView
                        : Perm.paymentsView,
                  ),
                ),
              ),
            SectionCard(
              title: 'Lines',
              child: TaxLinesView(
                lines: lines,
                interState: invoice.isInterState,
                showReturned: lines.any((l) => l.returnedQty > 0),
              ),
            ),
            if (invoice.notes != null && invoice.notes!.isNotEmpty)
              SectionCard(title: 'Notes', child: Text(invoice.notes!)),
          ],
        );
      },
    );
  }

  static String _dueLabel(Invoice invoice) {
    final label = formatDate(invoice.dueDate);
    final due = DateTime.tryParse(invoice.dueDate ?? '');
    final today = DateUtils.dateOnly(DateTime.now());
    final overdue =
        due != null &&
        due.isBefore(today) &&
        (invoice.amountDue ?? 0) > 0 &&
        !invoice.isCancelled;
    return overdue ? '$label (overdue)' : label;
  }
}
