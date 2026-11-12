import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../compliance/compliance_widgets.dart' show pickTextFile;
import 'channels_models.dart';
import 'channels_repository.dart';

export '../construction/common/c_widgets.dart'
    show CGate, bigButton, confirm, showSuccess;

/// Colour for an inbox, order or settlement status word.
Color statusColor(BuildContext context, String status) {
  final c = context.colors;
  return switch (status) {
    'processed' ||
    'posted' ||
    'matched' ||
    'create' ||
    'connected' => c.success,
    'failed' || 'dead' || 'unbalanced' || 'blocked' => c.danger,
    'ignored' ||
    'duplicate' ||
    'imported' ||
    'received' ||
    'disabled' => c.onNeutralContainer,
    'cancel' || 'degraded' => c.warning,
    _ => c.info,
  };
}

String statusLabel(String s) {
  const words = {
    'create': 'Will create',
    'duplicate': 'Already imported',
    'cancel': 'Will cancel',
    'ignored': 'Skipped',
    'blocked': 'Cannot import',
    'processed': 'Done',
    'failed': 'Needs attention',
    'imported': 'Not matched yet',
    'matched': 'Matched',
    'unbalanced': 'Does not add up',
    'posted': 'Posted',
  };
  final w = words[s] ?? s.replaceAll('_', ' ');
  return w.isEmpty ? w : w[0].toUpperCase() + w.substring(1);
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) =>
      Pill(statusLabel(status), color: statusColor(context, status));
}

/// Chooses one of the company's channels. Selects the first one when [value] is empty.
class ChannelDropdown extends ConsumerWidget {
  const ChannelDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    this.allowAll = false,
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final bool allowAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channels = ref.watch(channelsProvider).value ?? const <Channel>[];
    final selected = channels.any((c) => c.id == value) ? value : null;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: DropdownButtonFormField<String?>(
        key: const Key('channel-dropdown'),
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Channel', isDense: true),
        items: [
          if (allowAll)
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All channels'),
            ),
          for (final c in channels)
            DropdownMenuItem<String?>(
              value: c.id,
              child: Text(c.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

/// A text box for CSV content with a "Choose file" button. Tests and small files can type or paste.
class CsvInput extends StatelessWidget {
  const CsvInput({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hint = '',
  });

  final TextEditingController controller;
  final VoidCallback onChanged;
  final String hint;

  Future<void> _pick(BuildContext context) async {
    try {
      final file = await pickTextFile(const ['csv', 'txt']);
      if (file == null) return;
      controller.text = file.text;
      onChanged();
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: const Key('csv-choose'),
              onPressed: () => _pick(context),
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Choose CSV file'),
            ),
            Text(
              'or paste the rows below',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: Space.sm),
        TextField(
          key: const Key('csv-text'),
          controller: controller,
          minLines: 4,
          maxLines: 8,
          onChanged: (_) => onChanged(),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
          decoration: InputDecoration(
            labelText: 'File contents',
            hintText: hint,
            alignLabelWithHint: true,
          ),
        ),
      ],
    );
  }
}

/// A label with a number or word, for the small summary rows.
class SummaryChip extends StatelessWidget {
  const SummaryChip(this.label, this.value, {super.key, this.color});

  final String label;
  final int value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: Space.md,
      vertical: Space.sm,
    ),
    decoration: BoxDecoration(
      border: Border.all(color: context.colors.hairline),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
          style: TextStyle(fontWeight: FontWeight.w700, color: color),
        ),
        const SizedBox(width: Space.xs + 2),
        Text(label),
      ],
    ),
  );
}
