import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/money.dart';
import '../../core/pdf_kit.dart';
import 'hotel_models.dart';

String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');

String billFileName(Folio f) => 'guest-bill-${_safe(f.reservation.number)}.pdf';
String cardFileName(Reservation r) => 'registration-card-${_safe(r.number)}.pdf';

String _qty(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

/// The guest bill: every folio line, tax, payments and the balance. Before
/// check-out it is marked as an estimate; the tax invoice comes at check-out.
Future<Uint8List> buildGuestBillPdf(
  Folio f, {
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? PdfBrand.plain(), theme: theme);
  final r = f.reservation;
  final doc = kit.document(title: 'Guest bill ${r.number}', subject: r.guestName);
  final t = f.totals;
  final live = f.lines.where((l) => !l.voided).toList();
  final rooms = r.rooms
      .map((b) => b.roomNumber)
      .whereType<String>()
      .join(', ');
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(format: PdfPageFormat.a4, margin: 32),
      footer: (c) => kit.footer(c, left: '${r.number}  |  ${r.guestName}'),
      build: (c) => [
        kit.header(
          title: 'Guest bill',
          subtitle: f.invoice != null
              ? 'Tax invoice ${f.invoice!.number}'
              : 'Estimate. The tax invoice is raised at check-out.',
        ),
        pw.SizedBox(height: 10),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  kit.kv('Guest', r.guestName),
                  if (kit.has(r.guestPhone)) kit.kv('Phone', r.guestPhone!),
                  kit.kv('Reservation', r.number),
                ],
              ),
            ),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  kit.kv('Arrival', formatDate(r.arrival)),
                  kit.kv('Departure', formatDate(r.departure)),
                  if (rooms.isNotEmpty) kit.kv('Rooms', rooms),
                ],
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 10),
        kit.table(
          columns: const [
            PdfCol('Date', width: 54),
            PdfCol('Description', flex: 4),
            PdfCol('Qty', width: 34, right: true),
            PdfCol('Rate', width: 62, right: true),
            PdfCol('GST', width: 34, right: true),
            PdfCol('Amount', width: 70, right: true, bold: true),
          ],
          rows: [
            for (final l in live)
              [
                formatDate(l.date),
                l.description,
                l.isDiscount ? '' : _qty(l.qty),
                l.isDiscount ? '' : formatMoney(l.rate),
                l.isDiscount ? '' : '${_qty(l.gstRate)}%',
                '${l.isDiscount ? '-' : ''}${formatMoney(l.amount)}',
              ],
          ],
        ),
        pw.SizedBox(height: 10),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.SizedBox(
            width: 230,
            child: kit.totalsBox([
              kit.totalRow('Charges', formatMoney(t.gross)),
              if (t.discount > 0) kit.totalRow('Discount', '-${formatMoney(t.discount)}'),
              kit.totalRow(
                f.pricesIncludeTax ? 'Tax included' : 'Tax',
                formatMoney(t.tax),
              ),
              kit.totalRow(
                t.estimate ? 'Total (estimate)' : 'Total',
                formatMoney(t.total),
                strong: true,
              ),
              kit.totalRow('Paid', formatMoney(t.paid)),
              kit.totalRow('Balance', formatMoney(t.balance), strong: true),
            ]),
          ),
        ),
        pw.SizedBox(height: 18),
        pw.Align(alignment: pw.Alignment.centerRight, child: kit.signature()),
      ],
    ),
  );
  return doc.save();
}

/// One registration card per booked room, with the guest, ID and, for a
/// foreign guest, passport and visa details (Form C).
Future<Uint8List> buildRegistrationCardPdf(
  Reservation r, {
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? PdfBrand.plain(), theme: theme);
  final doc = kit.document(title: 'Registration card ${r.number}', subject: r.guestName);
  for (final b in r.rooms) {
    final g = b.guest;
    final foreign = g?.nationality != null &&
        !RegExp(r'^(india|indian)$', caseSensitive: false).hasMatch(g!.nationality!.trim());
    String v(String? s) => kit.has(s) ? s! : '';
    doc.addPage(
      pw.Page(
        pageTheme: kit.pageTheme(format: PdfPageFormat.a5, margin: 28),
        build: (c) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            kit.header(title: 'Registration card', subtitle: r.number),
            pw.SizedBox(height: 10),
            kit.kv('Room', b.roomNumber == null ? b.typeName : '${b.roomNumber}  (${b.typeName})', keyWidth: 90),
            kit.kv('Arrival', formatDate(r.arrival), keyWidth: 90),
            kit.kv('Departure', formatDate(r.departure), keyWidth: 90),
            kit.kv('Adults, children', '${b.adults}, ${b.children}', keyWidth: 90),
            pw.SizedBox(height: 6),
            kit.sectionTitle('Guest'),
            kit.kv('Name', v(g?.name ?? r.guestName), keyWidth: 90),
            kit.kv('Phone', v(g?.phone ?? r.guestPhone), keyWidth: 90),
            kit.kv('Address', v(g?.address), keyWidth: 90),
            kit.kv('ID', '${v(g?.idType?.replaceAll('_', ' '))}  ${v(g?.idNumber)}'.trim(), keyWidth: 90),
            kit.kv('Nationality', v(g?.nationality ?? 'Indian'), keyWidth: 90),
            if (foreign) ...[
              kit.kv('Passport no.', v(g.passportNo), keyWidth: 90),
              kit.kv('Visa no. and type', '${v(g.visaNo)}  ${v(g.visaType)}'.trim(), keyWidth: 90),
              kit.kv('Visa expiry', v(g.visaExpiry), keyWidth: 90),
            ],
            kit.kv('Coming from', v(g?.arrivedFrom), keyWidth: 90),
            kit.kv('Going to', v(g?.goingTo), keyWidth: 90),
            kit.kv('Purpose', v(g?.purpose), keyWidth: 90),
            pw.Spacer(),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                kit.signature(role: 'Guest signature', width: 150),
                kit.signature(width: 150),
              ],
            ),
          ],
        ),
      ),
    );
  }
  return doc.save();
}
