import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../core/api_exception.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import 'invoice_model.dart';
import 'invoices_repository.dart';

/// Permission for IRNs and e-way bills (API v1.3).
const String kEinvoiceManage = 'einvoice.manage';

const Map<String, String> kCancelReasonCodes = {
  '1': 'Duplicate',
  '2': 'Data-entry mistake',
  '3': 'Order cancelled',
  '4': 'Other',
};

const Map<String, String> kTransportModes = {
  'road': 'Road',
  'rail': 'Rail',
  'air': 'Air',
  'ship': 'Ship',
};

/// A readable list of what is wrong, from a `400 VALIDATION_ERROR`'s
/// `details` (`field → message | [messages] | {nested}`), or the message
/// alone for other errors.
List<String> describeApiProblems(Object error) {
  if (error is! ApiException) return [error.toString()];
  final lines = <String>[];
  void walk(String prefix, Object? value) {
    if (value is Map) {
      value.forEach((k, v) => walk(prefix.isEmpty ? '$k' : '$prefix.$k', v));
    } else if (value is List) {
      if (value.every((e) => e is! Map && e is! List)) {
        lines.add(_line(prefix, value.join(', ')));
      } else {
        for (final e in value) {
          walk(prefix, e);
        }
      }
    } else if (value != null) {
      lines.add(_line(prefix, value.toString()));
    }
  }

  walk('', error.details);
  return lines.isEmpty ? [error.message] : [error.message, ...lines];
}

String _line(String field, String message) =>
    field.isEmpty ? message : '$field: $message';

Future<void> showProblemsDialog(
  BuildContext context,
  String title,
  Object error,
) {
  final lines = describeApiProblems(error);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(lines.first),
            if (lines.length > 1) const SizedBox(height: 8),
            for (final line in lines.skip(1))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('•  '),
                    Expanded(child: Text(line)),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// "GST e-invoice" card of the invoice detail: IRN, e-way bill and their
/// actions (`einvoice.manage`).
class EInvoiceSection extends ConsumerStatefulWidget {
  const EInvoiceSection({super.key, required this.invoice});

  final Invoice invoice;

  @override
  ConsumerState<EInvoiceSection> createState() => _EInvoiceSectionState();
}

class _EInvoiceSectionState extends ConsumerState<EInvoiceSection> {
  bool _busy = false;

  Invoice get _invoice => widget.invoice;

  Future<void> _run(
    Future<Invoice> Function() call,
    String done,
    String errorTitle,
  ) async {
    setState(() => _busy = true);
    try {
      await call();
      ref.bump(const [DataKind.invoices]);
      if (mounted) showInfoSnackBar(context, done);
    } catch (e) {
      if (mounted) {
        if (e is ApiException && (e.isValidation || e.statusCode == 400)) {
          await showProblemsDialog(context, errorTitle, e);
        } else {
          showErrorSnackBar(context, e);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generateIrn(Company company) async {
    final id = _invoice.id!;
    final repo = ref.read(invoicesRepositoryProvider);
    if (company.einvoiceSandbox) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Generate test IRN?'),
          content: const Text(
            'Sandbox mode makes test values locally. They are flagged '
            '"SANDBOX" and are not valid for GST filing.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Generate'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      await _run(
        () => repo.generateIrn(id),
        'IRN generated',
        'Cannot generate IRN',
      );
      return;
    }
    final body = await showDialog<Json>(
      context: context,
      builder: (_) => ManualIrnDialog(invoiceId: id),
    );
    if (body == null || !mounted) return;
    await _run(
      () => repo.generateIrn(id, body),
      'IRN recorded',
      'Cannot record IRN',
    );
  }

  Future<void> _cancel({required bool ewb}) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => CancelWithCodeDialog(
        title: ewb ? 'Cancel e-way bill?' : 'Cancel IRN?',
        message: ewb
            ? 'An e-way bill can be cancelled within 24 hours of '
                  'generating it.'
            : 'An IRN can be cancelled within 24 hours of its '
                  'acknowledgement. The invoice itself stays posted. After '
                  'that, issue a credit note.',
      ),
    );
    if (result == null || !mounted) return;
    final repo = ref.read(invoicesRepositoryProvider);
    final id = _invoice.id!;
    await _run(
      () => ewb
          ? repo.cancelEwayBill(id, reasonCode: result.$1, remark: result.$2)
          : repo.cancelIrn(id, reasonCode: result.$1, remark: result.$2),
      ewb ? 'E-way bill cancelled' : 'IRN cancelled',
      ewb ? 'Cannot cancel e-way bill' : 'Cannot cancel IRN',
    );
  }

  Future<void> _generateEwb(Company company) async {
    final body = await showDialog<Json>(
      context: context,
      builder: (_) => EwayBillDialog(manual: !company.einvoiceSandbox),
    );
    if (body == null || !mounted) return;
    await _run(
      () => ref
          .read(invoicesRepositoryProvider)
          .generateEwayBill(_invoice.id!, body),
      'E-way bill generated',
      'Cannot generate e-way bill',
    );
  }

  Future<void> _downloadJson() async {
    try {
      final payload = await ref
          .read(invoicesRepositoryProvider)
          .einvoicePayload(_invoice.id!);
      final text = const JsonEncoder.withIndent('  ').convert(payload);
      final name =
          '${(_invoice.number ?? 'invoice').replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}-einvoice.json';
      await Clipboard.setData(ClipboardData(text: text));
      await Printing.sharePdf(bytes: utf8.encode(text), filename: name);
      if (mounted) {
        showInfoSnackBar(context, 'IRP JSON downloaded and copied');
      }
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && e.statusCode == 400) {
        await showProblemsDialog(context, 'Cannot build the IRP JSON', e);
      } else {
        showErrorSnackBar(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final can = ref.watch(permissionsProvider).can(kEinvoiceManage);
    final e = _invoice.einvoice;
    if (!can && e == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final company = ref.watch(companyProfileProvider).value;
    final posted = _invoice.status == DocStatus.posted;
    final hasGstin = (_invoice.partyGstin ?? '').trim().isNotEmpty;
    final ewb = _invoice.ewaybill;
    final now = DateTime.now();
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final children = <Widget>[];
    if (e != null) {
      children.add(
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Pill(
              e.isActive ? 'IRN active' : 'IRN cancelled',
              color: e.isActive
                  ? Colors.green.shade700
                  : theme.colorScheme.error,
            ),
            if (e.sandbox) Pill('SANDBOX', color: Colors.orange.shade800),
          ],
        ),
      );
      children.add(const SizedBox(height: 12));
      children.add(
        Wrap(
          spacing: 32,
          runSpacing: 12,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: LabeledValue('IRN', e.irn),
            ),
            LabeledValue('Ack No', e.ackNo),
            LabeledValue('Ack date', formatDateTime(e.ackDate)),
            if (!e.isActive && e.cancelledAt != null)
              LabeledValue('Cancelled', formatDateTime(e.cancelledAt)),
            if (!e.isActive && (e.cancelReason ?? '').isNotEmpty)
              LabeledValue('Reason', e.cancelReason!),
          ],
        ),
      );
      if (e.sandbox) {
        children.add(const SizedBox(height: 8));
        children.add(
          Text(
            'SANDBOX — not valid for GST',
            style: theme.textTheme.labelLarge,
          ),
        );
      }
      if (e.isActive && can) {
        final deadline = e.cancelDeadline;
        final open = e.canCancelAt(now);
        children.add(const SizedBox(height: 8));
        children.add(
          Text(
            deadline == null
                ? 'An IRN can be cancelled within 24 hours.'
                : open
                ? 'Can be cancelled until ${formatDateTime(deadline)} '
                      '(24 hours from acknowledgement).'
                : 'The 24-hour cancel window closed on '
                      '${formatDateTime(deadline)}. Issue a credit note '
                      'instead.',
            style: muted,
          ),
        );
      }
    } else if (posted && can) {
      if (company != null && !company.einvoiceEnabled) {
        children.add(
          Text(
            'E-invoicing is switched off. Turn it on in Company settings.',
            style: muted,
          ),
        );
      } else if (!hasGstin) {
        children.add(
          Text(
            'This party has no GSTIN (B2C), so no IRN is needed.',
            style: muted,
          ),
        );
      } else {
        children.add(Text('No IRN generated yet.', style: muted));
      }
    }

    if (ewb != null) {
      children.add(const Divider(height: 24));
      children.add(
        Wrap(
          spacing: 8,
          children: [
            Pill(
              ewb.isActive ? 'E-way bill active' : 'E-way bill cancelled',
              color: ewb.isActive
                  ? Colors.green.shade700
                  : theme.colorScheme.error,
            ),
          ],
        ),
      );
      children.add(const SizedBox(height: 12));
      children.add(
        Wrap(
          spacing: 32,
          runSpacing: 12,
          children: [
            LabeledValue('E-way bill no', ewb.ewbNo),
            LabeledValue('Generated', formatDateTime(ewb.ewbDate)),
            LabeledValue('Valid until', formatDateTime(ewb.validUntil)),
            LabeledValue(
              'Transport',
              kTransportModes[ewb.transportMode] ?? ewb.transportMode,
            ),
            LabeledValue('Distance', '${ewb.distanceKm} km'),
            if ((ewb.vehicleNo ?? '').isNotEmpty)
              LabeledValue('Vehicle', ewb.vehicleNo!),
            if ((ewb.transporterGstin ?? '').isNotEmpty)
              LabeledValue('Transporter GSTIN', ewb.transporterGstin!),
          ],
        ),
      );
    }

    final enabled = company?.einvoiceEnabled ?? true;
    final buttons = <Widget>[
      if (can && posted && (e == null || !e.isActive) && hasGstin && enabled)
        FilledButton.icon(
          onPressed: _busy || company == null
              ? null
              : () => _generateIrn(company),
          icon: const Icon(Icons.qr_code_2),
          label: const Text('Generate IRN'),
        ),
      if (can &&
          e != null &&
          e.isActive &&
          e.canCancelAt(now) &&
          ewb?.isActive != true)
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _cancel(ewb: false),
          icon: const Icon(Icons.block),
          label: const Text('Cancel IRN'),
        ),
      if (can && e != null && e.isActive && ewb?.isActive != true)
        OutlinedButton.icon(
          onPressed: _busy || company == null
              ? null
              : () => _generateEwb(company),
          icon: const Icon(Icons.local_shipping_outlined),
          label: const Text('Generate e-way bill'),
        ),
      if (can && ewb != null && ewb.isActive && ewb.canCancelAt(now))
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _cancel(ewb: true),
          icon: const Icon(Icons.block),
          label: const Text('Cancel e-way bill'),
        ),
      if (can &&
          posted &&
          hasGstin &&
          company != null &&
          !company.einvoiceSandbox &&
          (e == null || !e.isActive))
        OutlinedButton.icon(
          onPressed: _busy ? null : _downloadJson,
          icon: const Icon(Icons.download_outlined),
          label: const Text('Download JSON'),
        ),
    ];
    if (buttons.isNotEmpty) {
      children.add(const SizedBox(height: 16));
      children.add(Wrap(spacing: 8, runSpacing: 8, children: buttons));
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'GST e-invoice',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// Parses `YYYY-MM-DD` or `YYYY-MM-DD HH:mm`.
DateTime? parseStamp(String? text) =>
    DateTime.tryParse((text ?? '').trim().replaceFirst(' ', 'T'));

String stampText(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

/// Records the IRN, acknowledgement and signed QR the IRP returned
/// (manual mode). Pops with the request body.
class ManualIrnDialog extends StatefulWidget {
  const ManualIrnDialog({super.key, required this.invoiceId});

  final String invoiceId;

  @override
  State<ManualIrnDialog> createState() => _ManualIrnDialogState();
}

class _ManualIrnDialogState extends State<ManualIrnDialog> {
  final _formKey = GlobalKey<FormState>();
  final _irn = TextEditingController();
  final _ackNo = TextEditingController();
  final _ackDate = TextEditingController(text: stampText(DateTime.now()));
  final _qr = TextEditingController();

  @override
  void dispose() {
    _irn.dispose();
    _ackNo.dispose();
    _ackDate.dispose();
    _qr.dispose();
    super.dispose();
  }

  static final _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(<String, dynamic>{
      'irn': _irn.text.trim().toLowerCase(),
      'ackNo': _ackNo.text.trim(),
      'ackDate': parseStamp(_ackDate.text)!.toUtc().toIso8601String(),
      'signedQrCode': _qr.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Record IRN'),
    scrollable: true,
    content: SizedBox(
      width: 480,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Upload the downloaded JSON on the IRP portal, then enter what '
              'it returns.',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _irn,
              decoration: const InputDecoration(
                labelText: 'IRN',
                helperText: '64 hex characters',
              ),
              maxLength: 64,
              validator: (v) => _hex64.hasMatch((v ?? '').trim())
                  ? null
                  : 'Enter the 64-character IRN',
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _ackNo,
              decoration: const InputDecoration(labelText: 'Ack No'),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Ack No is required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _ackDate,
              decoration: const InputDecoration(
                labelText: 'Ack date and time',
                helperText: 'YYYY-MM-DD HH:mm',
              ),
              validator: (v) =>
                  parseStamp(v) == null ? 'Use YYYY-MM-DD HH:mm' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _qr,
              decoration: const InputDecoration(
                labelText: 'Signed QR code',
                alignLabelWithHint: true,
              ),
              minLines: 3,
              maxLines: 6,
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Paste the signed QR code' : null,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Record IRN')),
    ],
  );
}

/// Reason code + remark for cancelling an IRN or e-way bill; pops with
/// `(reasonCode, remark)`.
class CancelWithCodeDialog extends StatefulWidget {
  const CancelWithCodeDialog({
    super.key,
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  @override
  State<CancelWithCodeDialog> createState() => _CancelWithCodeDialogState();
}

class _CancelWithCodeDialogState extends State<CancelWithCodeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _remark = TextEditingController();
  String _code = '2';

  @override
  void dispose() {
    _remark.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.message),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _code,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Reason'),
                items: [
                  for (final MapEntry(:key, :value)
                      in kCancelReasonCodes.entries)
                    DropdownMenuItem(value: key, child: Text(value)),
                ],
                onChanged: (v) => setState(() => _code = v ?? _code),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _remark,
                maxLength: 100,
                decoration: const InputDecoration(labelText: 'Remark'),
                validator: (v) => (v ?? '').trim().length < 3
                    ? 'At least 3 characters'
                    : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.of(context).pop((_code, _remark.text.trim()));
            }
          },
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Transport details for an e-way bill; manual mode also takes the number
/// and dates from the portal. Pops with the request body.
class EwayBillDialog extends StatefulWidget {
  const EwayBillDialog({super.key, required this.manual});

  final bool manual;

  @override
  State<EwayBillDialog> createState() => _EwayBillDialogState();
}

class _EwayBillDialogState extends State<EwayBillDialog> {
  final _formKey = GlobalKey<FormState>();
  final _distance = TextEditingController();
  final _vehicle = TextEditingController();
  final _transporter = TextEditingController();
  final _ewbNo = TextEditingController();
  final _ewbDate = TextEditingController(text: stampText(DateTime.now()));
  final _validUntil = TextEditingController(
    text: stampText(
      DateTime.now()
          .add(const Duration(days: 1))
          .copyWith(hour: 23, minute: 59),
    ),
  );
  String _mode = 'road';

  @override
  void dispose() {
    for (final c in [
      _distance,
      _vehicle,
      _transporter,
      _ewbNo,
      _ewbDate,
      _validUntil,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    String? text(TextEditingController c) {
      final t = c.text.trim();
      return t.isEmpty ? null : t;
    }

    final body = withoutNulls({
      'transportMode': _mode,
      'distanceKm': int.parse(_distance.text.trim()),
      'vehicleNo': text(_vehicle)?.toUpperCase(),
      'transporterGstin': text(_transporter)?.toUpperCase(),
      if (widget.manual) ...{
        'ewbNo': _ewbNo.text.trim(),
        'ewbDate': parseStamp(_ewbDate.text)!.toUtc().toIso8601String(),
        'validUntil': parseStamp(_validUntil.text)!.toUtc().toIso8601String(),
      },
    });
    Navigator.of(context).pop(body);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Generate e-way bill'),
    scrollable: true,
    content: SizedBox(
      width: 480,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _mode,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Transport mode'),
              items: [
                for (final MapEntry(:key, :value) in kTransportModes.entries)
                  DropdownMenuItem(value: key, child: Text(value)),
              ],
              onChanged: (v) => setState(() => _mode = v ?? _mode),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _distance,
              decoration: const InputDecoration(
                labelText: 'Distance (km)',
                helperText: '0 to 4000',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (v) {
                final n = int.tryParse((v ?? '').trim());
                return n == null || n < 0 || n > 4000
                    ? 'Enter 0 to 4000'
                    : null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _vehicle,
              decoration: InputDecoration(
                labelText: _mode == 'road'
                    ? 'Vehicle no'
                    : 'Vehicle / document no (optional)',
              ),
              textCapitalization: TextCapitalization.characters,
              validator: (v) => _mode == 'road' && (v ?? '').trim().isEmpty
                  ? 'Vehicle no is required for road transport'
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _transporter,
              decoration: const InputDecoration(
                labelText: 'Transporter GSTIN (optional)',
              ),
              textCapitalization: TextCapitalization.characters,
              maxLength: 15,
            ),
            if (widget.manual) ...[
              const SizedBox(height: 8),
              TextFormField(
                controller: _ewbNo,
                decoration: const InputDecoration(
                  labelText: 'E-way bill no',
                  helperText: '12 digits, from the portal',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 12,
                validator: (v) => RegExp(r'^\d{12}$').hasMatch((v ?? '').trim())
                    ? null
                    : 'Enter the 12-digit number',
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _ewbDate,
                decoration: const InputDecoration(
                  labelText: 'Generated on',
                  helperText: 'YYYY-MM-DD HH:mm',
                ),
                validator: (v) =>
                    parseStamp(v) == null ? 'Use YYYY-MM-DD HH:mm' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _validUntil,
                decoration: const InputDecoration(
                  labelText: 'Valid until',
                  helperText: 'YYYY-MM-DD HH:mm',
                ),
                validator: (v) =>
                    parseStamp(v) == null ? 'Use YYYY-MM-DD HH:mm' : null,
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Generate')),
    ],
  );
}
