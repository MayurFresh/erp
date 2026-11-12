import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/states.dart';
import 'platform_repository.dart';

/// Asks which channel to use, then queues a payment reminder for the party.
Future<void> sendPaymentReminder(
  BuildContext context,
  WidgetRef ref,
  String partyId,
) async {
  final channel = await showModalBottomSheet<String>(
    context: context,
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('Send payment reminder by')),
          ListTile(
            key: const Key('remind.email'),
            leading: const Icon(Icons.email_outlined),
            title: const Text('Email'),
            onTap: () => Navigator.pop(context, 'email'),
          ),
          ListTile(
            key: const Key('remind.whatsapp'),
            leading: const Icon(Icons.chat_outlined),
            title: const Text('WhatsApp'),
            onTap: () => Navigator.pop(context, 'whatsapp'),
          ),
        ],
      ),
    ),
  );
  if (channel == null) return;
  try {
    await ref.read(platformRepositoryProvider).remind(partyId, channel);
    if (context.mounted) showInfoSnackBar(context, 'Reminder queued');
  } catch (e) {
    final api = apiError(e);
    if (context.mounted) {
      showErrorSnackBar(
        context,
        api?.code == 'TOO_SOON'
            ? 'A reminder was already sent in the last 24 hours.'
            : e,
      );
    }
  }
}
