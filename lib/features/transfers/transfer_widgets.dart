import 'package:flutter/material.dart';

import '../../widgets/layout.dart';
import 'transfer_model.dart';

class TransferStatusPill extends StatelessWidget {
  const TransferStatusPill({super.key, required this.status});

  final TransferStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Pill(
      status.label,
      color: switch (status) {
        TransferStatus.inTransit => Colors.orange.shade800,
        TransferStatus.received => Colors.green,
        TransferStatus.cancelled => scheme.error,
      },
    );
  }
}
