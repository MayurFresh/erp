import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/states.dart';
import '../auth/session.dart';

/// Shows [child] only when the user holds one of [anyOf].
class RGate extends ConsumerWidget {
  const RGate({super.key, required this.anyOf, required this.child});

  final List<String> anyOf;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    if (session == null) return const LoadingView();
    if (!session.permissions.canAny(anyOf)) {
      return const EmptyView(
        icon: Icons.lock_outline,
        message: 'You do not have access to this page.\nAsk an administrator for access.',
      );
    }
    return child;
  }
}

/// A date shown as a read-only field that opens the date picker.
class RDateField extends StatelessWidget {
  const RDateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.clearable = false,
    this.lastDate,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool clearable;
  final DateTime? lastDate;

  @override
  Widget build(BuildContext context) {
    final text = value == null
        ? ''
        : '${value!.day.toString().padLeft(2, '0')}/${value!.month.toString().padLeft(2, '0')}/${value!.year}';
    return TextFormField(
      key: ValueKey('date-$label'),
      controller: TextEditingController(text: text),
      readOnly: true,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: clearable && value != null
            ? IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close),
                onPressed: () => onChanged(null),
              )
            : const Icon(Icons.calendar_today_outlined, size: 18),
      ),
      onTap: () async {
        final now = DateTime.now();
        final d = await showDatePicker(
          context: context,
          initialDate: value ?? now,
          firstDate: DateTime(now.year - 10),
          lastDate: lastDate ?? DateTime(now.year + 10),
        );
        if (d != null) onChanged(d);
      },
    );
  }
}

/// Start of the financial year (1 April) containing [d].
DateTime fyStartOf(DateTime d) => DateTime(d.month >= 4 ? d.year : d.year - 1, 4, 1);
