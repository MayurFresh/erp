import 'package:flutter/material.dart';

import '../../widgets/layout.dart';
import 'transfer_model.dart';
import '../../core/app_colors.dart';

class TransferStatusPill extends StatelessWidget {
  const TransferStatusPill({super.key, required this.status});

  final TransferStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Pill(
      status.label,
      color: switch (status) {
        TransferStatus.inTransit => context.colors.warning,
        TransferStatus.received => context.colors.success,
        TransferStatus.cancelled => scheme.error,
      },
    );
  }
}
