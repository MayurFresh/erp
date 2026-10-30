import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/india_states.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../auth/session.dart';
import 'report_exports.dart';
import 'report_models.dart';
import 'report_period.dart';
import 'report_widgets.dart';
import 'reports_hub_screen.dart' show LocationFilter, locationName;
import 'reports_repository.dart';

/// `/reports/sales-register` or `/reports/purchase-register`.
class RegisterReportScreen extends ConsumerStatefulWidget {
  const RegisterReportScreen({super.key, required this.purchase});

  final bool purchase;

  @override
  ConsumerState<RegisterReportScreen> createState() => _RegisterState();
}

class _RegisterState extends ConsumerState<RegisterReportScreen> {
  DateRange _range = DateRange.fyToDate();
  String? _locationId;

  @override
  Widget build(BuildContext context) {
    final purchase = widget.purchase;
    final key = (
      from: _range.apiFrom,
      to: _range.apiTo,
      locationId: _locationId,
    );
    final provider = purchase
        ? purchaseRegisterProvider(key)
        : salesRegisterProvider(key);
    final value = ref.watch(provider);
    final perms = ref.watch(permissionsProvider);
    final canOpen = perms.can(
      purchase ? Perm.purchasesView : Perm.invoicesView,
    );
    final docPath = purchase ? '/purchases' : '/invoices';
    String money(RegisterRow r, double v) =>
        r.isCancelled ? '—' : formatMoney(v);

    return ReportPage(
      title: purchase ? 'Purchase register' : 'Sales register',
      subtitle: _range.label,
      export: value.value == null
          ? null
          : registerExport(
              value.value!,
              purchase: purchase,
              period: _range.label,
              location: locationName(ref, _locationId),
            ),
      controls: [
        PeriodButton(
          value: _range,
          onChanged: (r) => setState(() => _range = r),
        ),
        LocationFilter(
          value: _locationId,
          onChanged: (v) => setState(() => _locationId = v),
        ),
      ],
      body: ReportBody<Register>(
        value: value,
        onRetry: () => ref.invalidate(provider),
        isEmpty: (r) => r.rows.isEmpty,
        emptyMessage: purchase
            ? 'No purchase bills in this period.'
            : 'No invoices in this period.',
        builder: (reg) => [
          StatRow(
            children: [
              StatTile(
                label: 'Taxable value',
                value: formatMoney(reg.totals.taxable),
              ),
              StatTile(label: 'GST', value: formatMoney(reg.totals.tax)),
              StatTile(
                label: 'Total',
                value: formatMoney(reg.totals.total),
                caption:
                    '${reg.postedCount} posted'
                    '${reg.cancelledCount == 0 ? '' : ' · ${reg.cancelledCount} cancelled'}',
              ),
            ],
          ),
          ReportTable<RegisterRow>(
            rows: reg.rows,
            dimmed: (r) => r.isCancelled,
            onTap: canOpen ? (r) => context.push('$docPath/${r.id}') : null,
            columns: [
              ReportColumn('Number', (r) => r.number),
              if (purchase)
                ReportColumn(
                  'Supplier inv.',
                  (r) => r.supplierInvoiceNo ?? '—',
                ),
              ReportColumn('Date', (r) => formatDate(r.date)),
              ReportColumn(
                purchase ? 'Vendor' : 'Customer',
                (r) => r.partyName,
                flex: true,
                maxWidth: 240,
              ),
              ReportColumn('GSTIN', (r) => r.partyGstin ?? '—'),
              ReportColumn('POS', (r) => r.placeOfSupply ?? ''),
              ReportColumn(
                'Taxable',
                (r) => money(r, r.taxable),
                numeric: true,
              ),
              ReportColumn('CGST', (r) => money(r, r.cgst), numeric: true),
              ReportColumn('SGST', (r) => money(r, r.sgst), numeric: true),
              ReportColumn('IGST', (r) => money(r, r.igst), numeric: true),
              ReportColumn('Total', (r) => money(r, r.total), numeric: true),
              ReportColumn(
                'Status',
                (r) => r.isCancelled ? 'Cancelled' : 'Posted',
              ),
            ],
            totals: [
              'Total',
              if (purchase) '',
              '',
              '${reg.postedCount} posted',
              '',
              '',
              formatMoney(reg.totals.taxable),
              formatMoney(reg.totals.cgst),
              formatMoney(reg.totals.sgst),
              formatMoney(reg.totals.igst),
              formatMoney(reg.totals.total),
              '',
            ],
            cardBuilder: (context, r) => ReportRowCard(
              title: r.number,
              subtitle: [
                formatDate(r.date),
                r.partyName,
                if (r.partyGstin != null) r.partyGstin!,
                if (r.placeOfSupply != null) stateLabel(r.placeOfSupply),
                if (purchase && r.supplierInvoiceNo != null)
                  'Supplier inv. ${r.supplierInvoiceNo}',
              ].join(' · '),
              trailing: r.isCancelled ? 'Cancelled' : formatMoney(r.total),
              dimmed: r.isCancelled,
              pairs: r.isCancelled
                  ? const []
                  : [
                      ('Taxable', formatMoney(r.taxable)),
                      ('GST', formatMoney(r.tax)),
                    ],
              onTap: canOpen ? () => context.push('$docPath/${r.id}') : null,
            ),
            totalsCard: ReportRowCard(
              title: 'Total (${reg.postedCount} posted)',
              trailing: formatMoney(reg.totals.total),
              highlight: true,
              pairs: [
                ('Taxable', formatMoney(reg.totals.taxable)),
                ('CGST', formatMoney(reg.totals.cgst)),
                ('SGST', formatMoney(reg.totals.sgst)),
                ('IGST', formatMoney(reg.totals.igst)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
