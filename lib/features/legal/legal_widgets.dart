import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart';
import 'legal_dialogs.dart';
import 'legal_models.dart';
import 'legal_repository.dart';

extension LegalAccess on WidgetRef {
  bool get legalCanWork => read(
    permissionsProvider,
  ).canAny(const [Perm.legalWork, Perm.legalManage]);

  bool get legalCanManage => read(permissionsProvider).can(Perm.legalManage);
}

/// Opens the outcome dialog and reloads on save. A matter left without a next
/// date gets a warning.
Future<void> recordHearingOutcome(
  BuildContext context,
  WidgetRef ref, {
  required String hearingId,
  required String matterTitle,
  required String hearingDate,
}) async {
  final warning = await showFormDialog<String>(
    context: context,
    builder: (_) => OutcomeDialog(
      hearingId: hearingId,
      matterTitle: matterTitle,
      hearingDate: hearingDate,
    ),
  );
  if (warning == null) return;
  ref.bumpLegal();
  if (!context.mounted) return;
  if (warning.isEmpty) {
    showSuccess(context, 'Outcome saved and next hearing added');
  } else {
    showInfoSnackBar(context, 'Outcome saved. $warning');
  }
}

StatusTone matterTone(String status) => switch (status) {
  'open' => StatusTone.info,
  'disposed' => StatusTone.success,
  _ => StatusTone.neutral,
};

class MatterStatusChip extends StatelessWidget {
  const MatterStatusChip(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) => StatusChip(
    status,
    label: matterStatuses[status] ?? status,
    tone: matterTone(status),
  );
}

/// A small label and value line.
class LegalFact extends StatelessWidget {
  const LegalFact(this.label, this.value, {super.key});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    if (value == null || value!.trim().isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label  ',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}
