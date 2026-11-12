/// Tracks which open forms have unsaved edits, so navigation that bypasses
/// the back button (sidebar, `context.go`, browser back) can ask first.
///
/// A form only declares that it is dirty, through `UnsavedChangesGuard` or
/// `DirtyTracking` in `widgets/busy.dart`; the router does the asking.
class DirtyRegistry {
  DirtyRegistry._();

  static final DirtyRegistry instance = DirtyRegistry._();

  final Set<Object> _dirty = {};
  DateTime? _lastSave;

  /// Sets whether [owner] has unsaved edits.
  void set(Object owner, bool dirty) {
    if (dirty) {
      _dirty.add(owner);
    } else {
      _dirty.remove(owner);
    }
  }

  void remove(Object owner) => _dirty.remove(owner);

  /// Called after any successful POST, PATCH or DELETE. A form that saves
  /// and then navigates is not asked to confirm leaving for a few seconds.
  void noteSaved() => _lastSave = DateTime.now();

  bool get savedJustNow =>
      _lastSave != null &&
      DateTime.now().difference(_lastSave!) < const Duration(seconds: 5);

  /// True when a form has unsaved edits and no save just succeeded.
  bool get isDirty => _dirty.isNotEmpty && !savedJustNow;

  /// Forgets all dirty forms (the user agreed to discard them).
  void clear() {
    _dirty.clear();
    _lastSave = null;
  }
}
