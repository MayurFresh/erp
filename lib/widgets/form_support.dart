import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api_exception.dart';
import '../core/validators.dart';
import 'busy.dart' show confirmDiscard;
import 'states.dart';

export '../core/validators.dart';

/// Maps `VALIDATION_ERROR` details onto form fields via `forceErrorText`.
mixin ServerFieldErrors<T extends StatefulWidget> on State<T> {
  Map<String, String> serverErrors = const {};

  String? serverError(String field) => serverErrors[field];

  void clearServerError(String field) {
    if (!serverErrors.containsKey(field)) return;
    setState(() => serverErrors = Map.of(serverErrors)..remove(field));
  }

  /// Shows [error] in a SnackBar and attaches field messages to fields.
  ///
  /// A `STALE_EDIT` error keeps the typed values and, when [onReload] is
  /// given, offers a Reload action that opens the latest version.
  void showSubmitError(Object error, {VoidCallback? onReload}) {
    final api = apiError(error);
    if (api != null && api.fieldErrors.isNotEmpty) {
      setState(() => serverErrors = Map.of(api.fieldErrors));
    }
    if (api?.code == ApiException.staleEdit && onReload != null) {
      showErrorSnackBar(
        context,
        error,
        actionLabel: 'Reload',
        onAction: onReload,
      );
      return;
    }
    showErrorSnackBar(context, error);
  }
}

/// Digits with up to [decimals] decimal places (optionally signed). Typed or
/// pasted grouping ("1,00,000") is accepted and stripped; letters are
/// rejected. [max] defaults to the contract limit (1e9 for quantities with
/// 3 decimals, 1e12 otherwise).
TextInputFormatter decimalInput({
  int decimals = 2,
  bool signed = false,
  double? max,
}) => NumberInputFormatter(
  decimals: decimals,
  signed: signed,
  max: max ?? (decimals == 3 ? kMaxQty : kMaxMoney),
);

const TextInputType decimalKeyboard = TextInputType.numberWithOptions(
  decimal: true,
);

double? parseNumber(String text) => parseIndianNumber(text);

String? requiredField(String? value, [String label = 'This field']) =>
    (value == null || value.trim().isEmpty) ? '$label is required' : null;

String? requiredNumber(
  String? value, {
  String label = 'Value',
  double? min,
  double max = kMaxMoney,
}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return '$label is required';
  final number = parseIndianNumber(text);
  if (number == null) return 'Enter a number';
  if (number.abs() > max) return '$label is too large';
  if (min != null && number < min) return '$label must be at least $min';
  return null;
}

String? optionalNumber(String? value, {double? min, double? max}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return null;
  final number = parseIndianNumber(text);
  if (number == null) return 'Enter a number';
  if (number.abs() > kMaxMoney) return 'Value is too large';
  if (min != null && number < min) return 'Must be at least $min';
  if (max != null && number > max) return 'Must be at most $max';
  return null;
}

String? trimmedOrNull(String text) {
  final value = text.trim();
  return value.isEmpty ? null : value;
}

/// `showDialog` for a dialog with a form. Closing it by tapping outside, Esc
/// or the system back asks "Discard changes?" when something was typed.
/// Cancel buttons should call `Navigator.of(context).maybePop()` so they ask
/// too; a Save that pops with a result is not affected.
Future<T?> showFormDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => showDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  builder: (context) => DirtyDialogGuard(child: builder(context)),
);

/// Intercepts closing of the dialog below it when a text field was edited.
///
/// It needs no list of controllers: it remembers each field's text when the
/// dialog opened and counts a field as changed only after the user focused
/// it, so values filled in by a load do not count.
class DirtyDialogGuard extends StatefulWidget {
  const DirtyDialogGuard({super.key, required this.child});

  final Widget child;

  @override
  State<DirtyDialogGuard> createState() => _DirtyDialogGuardState();
}

class _DirtyDialogGuardState extends State<DirtyDialogGuard> {
  final _initial = Expando<String>('dialog field start text');
  final _touched = <TextEditingController>{};

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) => _snapshot());
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocus);
    super.dispose();
  }

  Iterable<EditableText> _fields() {
    final found = <EditableText>[];
    void visit(Element element) {
      if (element.widget is EditableText) {
        found.add(element.widget as EditableText);
      }
      element.visitChildren(visit);
    }

    if (mounted) (context as Element).visitChildren(visit);
    return found;
  }

  void _snapshot() {
    for (final field in _fields()) {
      _initial[field.controller] ??= field.controller.text;
    }
  }

  void _onFocus() {
    final focused = FocusManager.instance.primaryFocus?.context;
    final field = focused?.findAncestorWidgetOfExactType<EditableText>();
    if (field != null && mounted) {
      // The first focus fixes the starting text, so a value filled in by a
      // load before the user touched the field does not count as a change.
      if (_touched.add(field.controller)) {
        _initial[field.controller] = field.controller.text;
      }
    }
  }

  bool get _dirty => _fields().any(
    (f) =>
        _touched.contains(f.controller) &&
        f.controller.text != (_initial[f.controller] ?? ''),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop) return;
      final navigator = Navigator.of(context);
      if (!_dirty || await confirmDiscard(context)) {
        // Popping inside the pop callback breaks the Navigator's update.
        await Future<void>.delayed(Duration.zero);
        if (navigator.canPop()) navigator.pop();
      }
    },
    child: widget.child,
  );
}

/// Validates [key]'s form and, when a field fails, scrolls the first
/// invalid field into view and focuses it. Use in place of
/// `key.currentState!.validate()` on submit.
bool validateAndReveal(GlobalKey<FormState> key) {
  final state = key.currentState;
  if (state == null) return true;
  final ok = state.validate();
  if (ok) return true;
  FormFieldState<dynamic>? first;
  void visit(Element element) {
    if (first != null) return;
    if (element is StatefulElement && element.state is FormFieldState) {
      final field = element.state as FormFieldState<dynamic>;
      if (field.hasError) {
        first = field;
        return;
      }
    }
    element.visitChildren(visit);
  }

  (key.currentContext as Element?)?.visitChildren(visit);
  final target = first;
  if (target != null) {
    Scrollable.ensureVisible(
      target.context,
      alignment: 0.1,
      duration: const Duration(milliseconds: 200),
    );
    FocusScope.of(target.context).focusInDirection(TraversalDirection.down);
  }
  return false;
}
