import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';

/// Construction data whose lists and details reload after a write.
///
/// The app-wide [DataKind] enum lives in core; the pack keeps its own so it
/// can be added without editing shared files.
enum CKind { projects, boq, indents, issues, dprs, workers, attendance, wages }

final cRevisionProvider =
    NotifierProvider.family<CRevisionNotifier, int, CKind>(
      CRevisionNotifier.new,
    );

class CRevisionNotifier extends Notifier<int> {
  CRevisionNotifier(this.kind);

  final CKind kind;

  @override
  int build() => 0;

  void bump() => state++;
}

extension CWatchRevisions on Ref {
  /// Re-runs the provider after a write to any of [kinds].
  void watchC(Iterable<CKind> kinds) {
    for (final kind in kinds) {
      watch(cRevisionProvider(kind));
    }
  }
}

extension CRevisionRef on WidgetRef {
  /// Bumps construction kinds and, optionally, app-wide [DataKind]s (e.g.
  /// stock after a material issue).
  void bumpC(Iterable<CKind> kinds, [Iterable<DataKind> core = const []]) {
    for (final kind in kinds) {
      read(cRevisionProvider(kind).notifier).bump();
    }
    if (core.isNotEmpty) bump(core);
  }
}
