/// WhatsApp share links and UPI payment links (API v1.4 §9). Pure functions
/// except [openWhatsApp].
library;

import 'package:url_launcher/url_launcher.dart';

import 'money.dart';

/// `91` + 10 digits for an Indian mobile number, or `null` when [raw] is
/// empty or not a valid number. Accepts spaces, dashes and brackets, a
/// `+91` / `91` / `0` prefix, and a bare 10-digit number starting 6 to 9.
String? normalizeIndianPhone(String? raw) {
  var digits = (raw ?? '').replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return null;
  if (digits.length == 12 && digits.startsWith('91')) {
    digits = digits.substring(2);
  } else if (digits.length == 11 && digits.startsWith('0')) {
    digits = digits.substring(1);
  } else if (digits.length == 13 && digits.startsWith('091')) {
    digits = digits.substring(3);
  }
  if (!RegExp(r'^[6-9]\d{9}$').hasMatch(digits)) return null;
  return '91$digits';
}

/// `https://wa.me/<91XXXXXXXXXX>?text=…`; without a usable [phone] the
/// link has no number and the user picks the chat in WhatsApp.
Uri whatsAppUri({String? phone, required String text}) {
  final number = normalizeIndianPhone(phone);
  return Uri.parse(
    'https://wa.me/${number ?? ''}?text=${Uri.encodeComponent(text)}',
  );
}

/// `upi://pay?pa=<upiId>&pn=<name>&am=<amount, 2 dp>&tn=<note>&cu=INR`.
String buildUpiUri({
  required String upiId,
  required String payeeName,
  required double amount,
  required String note,
}) =>
    'upi://pay?pa=${upiId.trim()}'
    '&pn=${Uri.encodeComponent(payeeName)}'
    '&am=${amount.toStringAsFixed(2)}'
    '&tn=${Uri.encodeComponent(note)}'
    '&cu=INR';

/// Message for sharing an invoice: number, date, amount due, due date and
/// the UPI link (when given).
String invoiceWhatsAppText({
  required String companyName,
  required String? number,
  required String? invoiceDate,
  required double amountDue,
  String? dueDate,
  String? upiLink,
}) {
  final lines = [
    'Invoice ${number ?? ''} from $companyName',
    if (invoiceDate != null && invoiceDate.isNotEmpty)
      'Date: ${formatDate(invoiceDate)}',
    if (amountDue > 0) ...[
      'Amount due: ${formatMoney(amountDue)}',
      if (dueDate != null && dueDate.isNotEmpty)
        'Due date: ${formatDate(dueDate)}',
      if (upiLink != null) 'Pay by UPI: $upiLink',
    ] else
      'Paid in full. Thank you!',
  ];
  return lines.join('\n');
}

/// Polite dues reminder to a customer.
String duesReminderText({
  required String companyName,
  required String partyName,
  required double amountDue,
  String? documentNumber,
  String? dueDate,
  String? upiLink,
}) {
  final lines = [
    'Dear $partyName,',
    documentNumber == null
        ? 'This is a gentle reminder that ${formatMoney(amountDue)} is '
              'outstanding with $companyName.'
        : 'This is a gentle reminder that ${formatMoney(amountDue)} is '
              'outstanding on $documentNumber with $companyName'
              '${dueDate == null || dueDate.isEmpty ? '' : ' (due ${formatDate(dueDate)})'}.',
    if (upiLink != null) 'Pay by UPI: $upiLink',
    'Please ignore this message if you have already paid. Thank you!',
  ];
  return lines.join('\n');
}

/// Opens [uri] in WhatsApp (or the browser). Returns false if nothing
/// could handle it.
Future<bool> openWhatsApp(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);
