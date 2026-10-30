import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/whatsapp.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import 'parties_repository.dart';

/// Opens WhatsApp with a dues reminder for a customer. Fetches the party's
/// phone (WhatsApp lets the user pick the chat when there is none) and the
/// company's UPI ID for a pay link.
Future<void> sendPartyReminder(
  BuildContext context,
  WidgetRef ref, {
  required String partyId,
  required String partyName,
  required double amountDue,
  String? documentNumber,
  String? dueDate,
}) async {
  if (amountDue <= 0) {
    showInfoSnackBar(context, '$partyName has nothing due.');
    return;
  }
  Company? company;
  try {
    company = await ref.read(companyRepositoryProvider).get();
  } catch (_) {
    company = ref.read(sessionProvider).value?.company;
  }
  String? phone;
  try {
    phone = (await ref.read(partiesRepositoryProvider).get(partyId)).phone;
  } catch (_) {
    // No permission or offline: the user picks the chat.
  }
  final upiId = company?.upiId;
  final text = duesReminderText(
    companyName: company?.name ?? '',
    partyName: partyName,
    amountDue: amountDue,
    documentNumber: documentNumber,
    dueDate: dueDate,
    upiLink: upiId == null || upiId.isEmpty
        ? null
        : buildUpiUri(
            upiId: upiId,
            payeeName: company!.name,
            amount: amountDue,
            note: documentNumber ?? 'Dues',
          ),
  );
  try {
    final opened = await openWhatsApp(whatsAppUri(phone: phone, text: text));
    if (!opened && context.mounted) {
      showInfoSnackBar(context, 'Could not open WhatsApp.');
    }
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
  }
}
