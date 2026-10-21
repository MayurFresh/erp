import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'account_model.dart';

final accountsRepositoryProvider = Provider<AccountsRepository>(
  (ref) => AccountsRepository(ref.watch(apiClientProvider)),
);

/// Active cash and bank accounts, by code (for receipts, payments and
/// expenses).
final cashBankAccountsProvider = FutureProvider.autoDispose<List<Account>>((
  ref,
) async {
  ref.watch(activeCompanyIdProvider);
  ref.watch(revisionProvider(DataKind.accounts));
  final page = await ref
      .watch(accountsRepositoryProvider)
      .list(type: 'asset', activeOnly: true, limit: 200);
  return page.data.where((a) => a.isCashOrBank).toList();
});

/// Active expense heads, by code.
final expenseHeadsProvider = FutureProvider.autoDispose<List<Account>>((
  ref,
) async {
  ref.watch(activeCompanyIdProvider);
  ref.watch(revisionProvider(DataKind.accounts));
  final page = await ref
      .watch(accountsRepositoryProvider)
      .list(type: 'expense', activeOnly: true, limit: 200);
  return page.data.where((a) => a.isExpenseHead).toList();
});

class AccountsRepository {
  AccountsRepository(this._api);

  final ApiClient _api;

  /// Ordered by code.
  Future<Paged<Account>> list({
    String? type,
    String? subtype,
    bool activeOnly = false,
    String? q,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/accounts',
    Account.fromJson,
    query: {
      'type': type,
      'subtype': subtype,
      if (activeOnly) 'activeOnly': true,
      'q': q,
      'offset': offset,
      'limit': limit,
    },
  );
}
