import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import '../documents/document_models.dart';
import 'expense_model.dart';

final expensesRepositoryProvider = Provider<ExpensesRepository>(
  (ref) => ExpensesRepository(ref.watch(apiClientProvider)),
);

final expenseProvider = FutureProvider.autoDispose.family<Expense, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(revisionProvider(DataKind.expenses));
  return ref.watch(expensesRepositoryProvider).get(id);
});

class ExpensesRepository {
  ExpensesRepository(this._api);

  final ApiClient _api;

  Future<Paged<Expense>> list({
    String? q,
    String? from,
    String? to,
    String? accountId,
    String? locationId,
    DocStatus? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/expenses',
    Expense.fromJson,
    query: {
      'q': q,
      'from': from,
      'to': to,
      'accountId': accountId,
      'locationId': locationId,
      'status': status?.name,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Expense> get(String id) async =>
      Expense.fromJson(await _api.getJson('/expenses/$id'));

  Future<Expense> create(ExpenseDraft draft) async =>
      Expense.fromJson(await _api.postJson('/expenses', body: draft.toJson()));

  Future<Expense> cancel(String id, String reason) async => Expense.fromJson(
    await _api.postJson('/expenses/$id/cancel', body: {'reason': reason}),
  );
}
