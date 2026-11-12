import 'dart:typed_data';

import 'package:flutter/material.dart';
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
import 'hotel_models.dart';
import 'hotel_pdf.dart';
import 'hotel_repository.dart';
import 'hotel_widgets.dart';

const _chargeTypes = {
  'food': 'Food and drink',
  'laundry': 'Laundry',
  'minibar': 'Minibar',
  'extra_bed': 'Extra bed',
  'other': 'Other',
};

/// `/hotel/reservations/:id`: one stay, its folio and every action on it.
class FolioScreen extends ConsumerStatefulWidget {
  const FolioScreen({super.key, required this.reservationId});

  final String reservationId;

  @override
  ConsumerState<FolioScreen> createState() => _FolioScreenState();
}

class _FolioScreenState extends ConsumerState<FolioScreen> {
  bool _busy = false;

  /// Runs [call] with the buttons disabled; reloads the hotel lists after.
  Future<T?> _run<T>(Future<T> Function() call, {bool money = false}) async {
    if (_busy) return null;
    setState(() => _busy = true);
    try {
      final out = await call();
      if (mounted) ref.bumpHotel(money: money);
      return out;
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  HotelRepository get _repo => ref.read(hotelRepositoryProvider);

  Future<void> _addCharge({bool discount = false}) async {
    final body = await showFormDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => _ChargeDialog(discount: discount),
    );
    if (body == null) return;
    await _run(() => _repo.addCharge(widget.reservationId, body));
  }

  Future<void> _void(FolioLine l) async {
    final reason = await showReasonDialog(
      context,
      title: 'Void ${l.description}?',
      message: 'The line stays on record but is no longer billed.',
      confirmLabel: 'Void',
    );
    if (reason == null) return;
    await _run(() => _repo.voidCharge(widget.reservationId, l.id, reason));
  }

  Future<void> _takePayment(Folio f, {required bool advance}) async {
    final body = await showPaymentDialog(
      context,
      title: advance ? 'Advance received' : 'Payment received',
      suggested: advance ? null : f.totals.balance,
    );
    if (body == null) return;
    final ok = await _run(
      () => advance
          ? _repo.action(widget.reservationId, 'advance', body: body)
          : _repo.addPayment(widget.reservationId, body),
      money: true,
    );
    if (ok != null && mounted) showSuccess(context, 'Payment recorded');
  }

  Future<void> _simple(
    String action,
    String title,
    String message, {
    bool reason = false,
    double advance = 0,
  }) async {
    Map<String, Object?>? body;
    if (reason) {
      final r = await showReasonDialog(
        context,
        title: title,
        message: message,
        confirmLabel: 'Cancel reservation',
        cancelLabel: 'Keep it',
      );
      if (r == null) return;
      body = {'reason': r};
      if (advance > 0 && mounted) {
        final refund = await showPaymentDialog(
          context,
          title: 'Refund the advance?',
          suggested: advance,
          confirmLabel: 'Refund and cancel',
          note:
              'Advance held ${formatMoney(advance)}. Close this box to cancel without a refund.',
        );
        if (refund != null) body['refund'] = refund;
      }
    } else {
      final ok = await confirm(
        context,
        title: title,
        message: message,
        confirmLabel: 'Yes',
      );
      if (!ok) return;
    }
    await _run(() => _repo.action(widget.reservationId, action, body: body));
  }

  Future<void> _checkOut(Folio f, {bool credit = false}) async {
    Map<String, Object?>? pay;
    final due = f.totals.balance.roundToDouble();
    if (!credit && due > 0) {
      pay = await showPaymentDialog(
        context,
        title: 'Check out ${f.reservation.guestName}',
        suggested: due,
        confirmLabel: 'Take payment and check out',
        note:
            'Balance ${formatMoney(f.totals.balance)}. The tax invoice is made now '
            'and its total may differ by a few paise because of rounding.',
      );
      if (pay == null) return;
    } else {
      final ok = await confirm(
        context,
        title: 'Check out ${f.reservation.guestName}?',
        message: credit
            ? 'The unpaid balance stays on the guest account as a receivable.'
            : 'Nothing is due. The tax invoice is made now and the rooms go to housekeeping.',
        confirmLabel: 'Check out',
      );
      if (!ok) return;
    }
    final r = await _run(
      () => _repo.checkOut(widget.reservationId, {
        'payment': ?pay,
        if (credit) 'allowCredit': true,
      }),
      money: true,
    );
    if (r == null || !mounted) return;
    showSuccess(
      context,
      'Checked out. Invoice ${r.invoiceNumber}, ${formatMoney(r.total)}'
      '${r.refundDue > 0 ? '. Refund due ${formatMoney(r.refundDue)}' : ''}',
    );
  }

  Future<void> _print(Folio f, {required bool card}) async {
    await _run(() async {
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
      final Uint8List bytes = card
          ? await buildRegistrationCardPdf(
              f.reservation,
              brand: brand,
              theme: theme,
            )
          : await buildGuestBillPdf(f, brand: brand, theme: theme);
      await Printing.layoutPdf(
        onLayout: (_) async => Uint8List.fromList(bytes),
        name: card ? cardFileName(f.reservation) : billFileName(f),
        format: card ? PdfPageFormat.a5 : PdfPageFormat.a4,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final folio = ref.watch(hotelFolioProvider(widget.reservationId));
    final perms = ref.watch(permissionsProvider);
    final desk = perms.canAny(const [Perm.hotelFrontOffice, Perm.hotelManage]);
    final manage = perms.can(Perm.hotelManage);
    return CGate(
      anyOf: const [Perm.hotelView],
      child: AsyncValueView<Folio>(
        value: folio,
        onRetry: () => ref.invalidate(hotelFolioProvider(widget.reservationId)),
        data: (f) => _content(context, f, desk: desk, manage: manage),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    Folio f, {
    required bool desk,
    required bool manage,
  }) {
    final theme = Theme.of(context);
    final r = f.reservation;
    final gutter = pageGutter(context);
    final live = f.lines.where((l) => !l.voided).toList();
    final actions = <Widget>[
      if (desk && r.status == 'tentative')
        OutlinedButton(
          style: bigOutlinedButton,
          onPressed: _busy
              ? null
              : () => _simple(
                  'confirm',
                  'Confirm reservation?',
                  'The guest is sure to come.',
                ),
          child: const Text('Confirm'),
        ),
      if (desk && r.canCheckIn)
        FilledButton.icon(
          style: bigButton,
          onPressed: _busy
              ? null
              : () => context.go('/hotel/reservations/${r.id}/check-in'),
          icon: const Icon(Icons.login),
          label: const Text('Check in'),
        ),
      if (desk && r.isOpen)
        OutlinedButton(
          style: bigOutlinedButton,
          onPressed: _busy ? null : () => _takePayment(f, advance: !r.inHouse),
          child: Text(r.inHouse ? 'Take payment' : 'Take advance'),
        ),
      if (desk && r.inHouse)
        OutlinedButton(
          style: bigOutlinedButton,
          onPressed: _busy ? null : () => _addCharge(),
          child: const Text('Add charge'),
        ),
      if (manage && r.inHouse)
        OutlinedButton(
          style: bigOutlinedButton,
          onPressed: _busy ? null : () => _addCharge(discount: true),
          child: const Text('Discount'),
        ),
      if (desk && r.inHouse)
        FilledButton.icon(
          style: bigButton,
          onPressed: _busy ? null : () => _checkOut(f),
          icon: const Icon(Icons.logout),
          label: const Text('Check out'),
        ),
      if (desk && r.inHouse && f.totals.balance > 0)
        TextButton(
          onPressed: _busy ? null : () => _checkOut(f, credit: true),
          child: const Text('Check out on credit'),
        ),
      if (desk && r.canCheckIn)
        TextButton(
          onPressed: _busy
              ? null
              : () => _simple(
                  'cancel',
                  'Cancel this reservation?',
                  'Give a reason. The rooms are released.',
                  reason: true,
                  advance: r.advance,
                ),
          child: const Text('Cancel reservation'),
        ),
      if (desk && r.canCheckIn)
        TextButton(
          onPressed: _busy
              ? null
              : () => _simple(
                  'no-show',
                  'Mark as no-show?',
                  'The guest did not arrive. The rooms are released.',
                ),
          child: const Text('No-show'),
        ),
      OutlinedButton.icon(
        style: bigOutlinedButton,
        onPressed: _busy ? null : () => _print(f, card: false),
        icon: const Icon(Icons.receipt_long_outlined),
        label: const Text('Print bill'),
      ),
      if (r.inHouse || r.status == 'checked_out')
        OutlinedButton.icon(
          style: bigOutlinedButton,
          onPressed: _busy ? null : () => _print(f, card: true),
          icon: const Icon(Icons.badge_outlined),
          label: const Text('Registration card'),
        ),
    ];
    return ListView(
      padding: EdgeInsets.fromLTRB(gutter, Space.md, gutter, Space.xl),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(r.guestName, style: theme.textTheme.headlineSmall),
            ),
            ReservationChip(r.status),
          ],
        ),
        Text(
          [
            r.number,
            '${shortDate(r.arrival)} to ${shortDate(r.departure)}',
            nightsText(r.nights),
            sourceLabel(r.source) +
                (r.sourceName == null ? '' : ' (${r.sourceName})'),
          ].join('  |  '),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: Space.md),
        Wrap(spacing: Space.sm, runSpacing: Space.sm, children: actions),
        const SizedBox(height: Space.md),
        SectionCard(
          title: 'Rooms',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final b in r.rooms)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '${b.label}  |  ${b.adults} adults, ${b.children} children'
                    '${b.ratePlanName == null ? '' : '  |  ${b.ratePlanName}'}',
                  ),
                ),
              if (r.overrideTariff != null)
                Text(
                  'Tariff set to ${formatMoney(r.overrideTariff)} per night',
                ),
              if (r.notes != null) Text(r.notes!),
            ],
          ),
        ),
        const SizedBox(height: Space.md),
        SectionCard(
          title: 'Charges',
          child: live.isEmpty
              ? const Text(
                  'No charges yet. Room charges are posted at check-in and each night.',
                )
              : Column(
                  children: [
                    for (final l in f.lines)
                      _LineRow(
                        line: l,
                        onVoid:
                            desk &&
                                r.inHouse &&
                                l.canVoid &&
                                (!l.isDiscount || manage)
                            ? () => _void(l)
                            : null,
                        busy: _busy,
                      ),
                  ],
                ),
        ),
        const SizedBox(height: Space.md),
        SectionCard(
          title: f.totals.estimate ? 'Balance (estimate)' : 'Balance',
          child: Column(
            children: [
              _Money('Charges', f.totals.gross),
              if (f.totals.discount > 0) _Money('Discount', -f.totals.discount),
              _Money(f.pricesIncludeTax ? 'Tax included' : 'Tax', f.totals.tax),
              _Money('Total', f.totals.total, strong: true),
              for (final p in f.payments)
                _Money(
                  '${p.kind == 'advance'
                      ? 'Advance'
                      : p.kind == 'refund'
                      ? 'Refund'
                      : 'Payment'} ${p.number} (${p.mode})${p.status == 'cancelled' ? ', cancelled' : ''}',
                  p.kind == 'refund' ? p.amount : -p.amount,
                ),
              const Divider(),
              _Money(
                f.totals.balance < 0 ? 'Refund due' : 'Balance due',
                f.totals.balance.abs(),
                strong: true,
              ),
              if (f.invoice != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Invoice ${f.invoice!.number}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Money extends StatelessWidget {
  const _Money(this.label, this.amount, {this.strong = false});

  final String label;
  final double amount;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final style = strong
        ? Theme.of(context).textTheme.titleSmall
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(
            amount < 0 ? '-${formatMoney(-amount)}' : formatMoney(amount),
            style: style,
          ),
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.line,
    required this.onVoid,
    required this.busy,
  });

  final FolioLine line;
  final VoidCallback? onVoid;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final struck = line.voided
        ? theme.textTheme.bodyMedium?.copyWith(
            decoration: TextDecoration.lineThrough,
          )
        : theme.textTheme.bodyMedium;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.description, style: struck),
                Text(
                  [
                    shortDate(line.date),
                    if (!line.isDiscount && line.qty != 1)
                      '${line.qty} x ${formatMoney(line.rate)}',
                    if (!line.isDiscount)
                      'GST ${line.gstRate.toStringAsFixed(line.gstRate == line.gstRate.roundToDouble() ? 0 : 1)}%',
                    if (line.voided) 'Voided',
                  ].join('  |  '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Text(
            '${line.isDiscount ? '-' : ''}${formatMoney(line.amount)}',
            style: struck,
          ),
          if (onVoid != null)
            IconButton(
              tooltip: 'Void ${line.description}',
              onPressed: busy ? null : onVoid,
              icon: const Icon(Icons.remove_circle_outline),
            ),
        ],
      ),
    );
  }
}

class _ChargeDialog extends StatefulWidget {
  const _ChargeDialog({required this.discount});

  final bool discount;

  @override
  State<_ChargeDialog> createState() => _ChargeDialogState();
}

class _ChargeDialogState extends State<_ChargeDialog> {
  final _desc = TextEditingController();
  final _qty = TextEditingController(text: '1');
  final _rate = TextEditingController();
  String _type = 'food';
  String? _error;

  @override
  void dispose() {
    _desc.dispose();
    _qty.dispose();
    _rate.dispose();
    super.dispose();
  }

  void _submit() {
    final rate = parseNumber(_rate.text) ?? 0;
    final qty = parseNumber(_qty.text) ?? 0;
    if (_desc.text.trim().isEmpty) {
      setState(() => _error = 'Describe the charge.');
    } else if (rate <= 0 || (!widget.discount && qty <= 0)) {
      setState(() => _error = 'Enter the amount.');
    } else {
      Navigator.of(context).pop(<String, Object?>{
        'chargeType': widget.discount ? 'discount' : _type,
        'description': _desc.text.trim(),
        if (!widget.discount) 'qty': qty,
        'rate': rate,
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.discount ? 'Give a discount' : 'Add a charge'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.discount) ...[
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [
                  for (final e in _chargeTypes.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _type = v ?? 'food'),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _desc,
              decoration: InputDecoration(
                labelText: widget.discount ? 'Reason' : 'Description',
              ),
            ),
            const SizedBox(height: 12),
            FormRow(
              minCellWidth: 140,
              children: [
                if (!widget.discount)
                  TextField(
                    controller: _qty,
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput(decimals: 3)],
                    decoration: const InputDecoration(labelText: 'Quantity'),
                  ),
                TextField(
                  controller: _rate,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  decoration: InputDecoration(
                    labelText: widget.discount ? 'Amount off' : 'Rate',
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
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
        onPressed: _submit,
        child: Text(widget.discount ? 'Give discount' : 'Add'),
      ),
    ],
  );
}
