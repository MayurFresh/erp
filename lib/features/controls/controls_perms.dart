import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session.dart';

/// Permission keys of the v1.7 controls pack. F1 adds the same keys to
/// `lib/core/permissions.dart`; switch to `Perm.*` once they exist.
abstract final class ControlsPerm {
  static const approvalsView = 'approvals.view';
  static const approvalsManage = 'approvals.manage';
  static const importsRun = 'imports.run';
  static const companyManage = 'company.manage';
  static const accountsManage = 'accounts.manage';
  static const accountsView = 'accounts.view';
}

/// Id of the signed-in user (overridable in tests).
final currentUserIdProvider = Provider<String?>(
  (ref) => ref.watch(sessionProvider.select((s) => s.value?.user?.id)),
);
