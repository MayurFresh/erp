import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../locations/location_model.dart';
import '../locations/locations_repository.dart';
import 'mfg_repository.dart';

/// A mistake found before sending: its [message] is shown as typed.
class MfgInputError implements Exception {
  const MfgInputError(this.message);

  final String message;
}

/// Shows a plain message as an error snackbar.
void mfgError(BuildContext context, String message) =>
    showErrorSnackBar(context, ApiException(0, 'INPUT', message));

/// Runs a write and shows the error as a snackbar when it fails.
Future<bool> mfgGuarded(BuildContext context, Future<void> Function() call) async {
  try {
    await call();
    return true;
  } on MfgInputError catch (e) {
    if (context.mounted) mfgError(context, e.message);
    return false;
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
    return false;
  }
}

extension MfgRefresh on WidgetRef {
  void bumpMfg() => read(mfgRevisionProvider.notifier).bump();

  bool mfgCan(String permission) =>
      watch(sessionProvider).value?.permissions.can(permission) ?? false;
}

void mfgToast(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));

/// A bordered block with a title row, used for sections of a detail page.
class MfgCard extends StatelessWidget {
  const MfgCard({super.key, required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Material(
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.mediumAll,
          side: BorderSide(color: context.colors.hairline),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                  ?trailing,
                ],
              ),
              const SizedBox(height: Space.sm),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Label on the left, value on the right; wraps instead of overflowing.
class MfgKv extends StatelessWidget {
  const MfgKv(this.label, this.value, {super.key, this.bold = false});

  final String label, value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          const SizedBox(width: Space.sm),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: bold ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Quantity with its unit: `12.5 kg`.
String qtyUnit(num qty, String unit) => '${formatQty(qty)} $unit'.trim();

/// A decimal input that must hold a number above [min].
Widget mfgNumberField({
  required TextEditingController controller,
  required String label,
  bool required = true,
  double min = 0,
  bool allowZero = false,
  double? max,
  String? suffix,
}) => TextFormField(
  controller: controller,
  keyboardType: decimalKeyboard,
  decoration: InputDecoration(labelText: label, suffixText: suffix),
  validator: (v) {
    final text = v?.trim() ?? '';
    if (text.isEmpty) return required ? '$label is required' : null;
    final n = parseNumber(text);
    if (n == null) return 'Enter a number';
    if (n < min || (!allowZero && n <= min && min == 0)) {
      return allowZero ? 'Must be at least $min' : 'Must be more than $min';
    }
    if (max != null && n > max) return 'Must be at most ${formatQty(max)}';
    return null;
  },
);

/// Location chooser fed from the user's locations. [onChanged] gets the id.
class MfgLocationField extends ConsumerWidget {
  const MfgLocationField({super.key, required this.value, required this.onChanged, this.label = 'Location'});

  final String? value;
  final ValueChanged<String?> onChanged;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locs = ref.watch(locationsLookupProvider);
    final List<Location> items = locs.value ?? const [];
    final active = items.where((l) => l.isActive).toList();
    return DropdownButtonFormField<String>(
      initialValue: active.any((l) => l.id == value) ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final l in active) DropdownMenuItem(value: l.id, child: Text(l.name, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: onChanged,
      validator: (v) => v == null ? '$label is required' : null,
    );
  }
}

/// Asks for a reason; returns it, or null when cancelled.
Future<String?> askReason(
  BuildContext context, {
  required String title,
  required String action,
  String label = 'Reason',
  bool required = true,
}) {
  final c = TextEditingController();
  final key = GlobalKey<FormState>();
  return showFormDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Form(
        key: key,
        child: TextFormField(
          controller: c,
          autofocus: true,
          maxLines: 2,
          decoration: InputDecoration(labelText: label),
          validator: required ? (v) => requiredField(v, label) : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).maybePop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (key.currentState!.validate()) Navigator.of(ctx).pop(c.text.trim());
          },
          child: Text(action),
        ),
      ],
    ),
  );
}

/// Shows a cost figure only when the API sent it.
String costText(double? v) => v == null ? '' : formatMoney(v);

/// A page of tabs/sections should not stretch beyond a readable width.
Widget mfgBody(BuildContext context, List<Widget> children) => ListView(
  padding: EdgeInsets.fromLTRB(pageGutter(context), 0, pageGutter(context), Space.xxl),
  children: [
    Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    ),
  ],
);
