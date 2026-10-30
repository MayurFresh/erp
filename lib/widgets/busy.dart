import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

bool _blocking = false;

/// Runs [task] behind a modal spinner so nothing else can be tapped until
/// it finishes. Returns `null` without running when another blocking task
/// is already in progress (double tap). Errors propagate to the caller.
Future<T?> runBlocking<T>(
  BuildContext context,
  Future<T> Function() task,
) async {
  if (_blocking) return null;
  _blocking = true;
  final nav = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: nav.context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: Center(child: CircularProgressIndicator()),
    ),
  );
  unawaited(nav.push(route));
  try {
    return await task();
  } finally {
    _blocking = false;
    if (route.isActive && nav.mounted) nav.removeRoute(route);
  }
}

/// Prompts "Discard changes?"; `true` when the user agrees to leave.
Future<bool> confirmDiscard(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Discard changes?'),
      content: const Text('You have unsaved changes that will be lost.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep editing'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Discard'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Asks "Discard changes?" before the route is popped (back button, swipe,
/// close) while [dirty] is true. Wrap a form's body with it; set [dirty]
/// when any field changes and false after a successful save.
class UnsavedChangesGuard extends StatelessWidget {
  const UnsavedChangesGuard({
    super.key,
    required this.dirty,
    required this.child,
    this.stillDirty,
  });

  final bool dirty;

  /// Re-checked when a pop is intercepted, so a save that finished after the
  /// last build still lets the user leave without a prompt.
  final bool Function()? stillDirty;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !dirty,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      final navigator = Navigator.of(context);
      if (stillDirty?.call() == false || await confirmDiscard(context)) {
        navigator.pop();
      }
    },
    child: child,
  );
}

/// Tracks "dirty" for a form: wrap the [Form] with [track] (uses
/// `Form.onChanged`) and call [markSaved] right before leaving after a
/// successful save.
mixin DirtyTracking<T extends StatefulWidget> on State<T> {
  bool dirty = false;

  void markDirty() {
    if (!dirty && mounted) setState(() => dirty = true);
  }

  void markSaved() {
    if (!dirty) return;
    dirty = false;
    if (mounted) setState(() {});
  }

  /// Cancel button helper: confirms when dirty, then goes to [location].
  Future<void> leave(String location) async {
    final router = GoRouter.of(context);
    if (!dirty || await confirmDiscard(context)) router.go(location);
  }

  /// Wraps [child] so leaving while [dirty] asks for confirmation.
  Widget track(Widget child) =>
      UnsavedChangesGuard(dirty: dirty, stillDirty: () => dirty, child: child);
}
