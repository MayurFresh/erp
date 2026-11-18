import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'finance_models.dart';

final financeRepositoryProvider = Provider<FinanceRepository>(
  (ref) => FinanceRepository(ref.watch(apiClientProvider)),
);

/// Bumped after a write so the screens reload.
final financeRevisionProvider = NotifierProvider<FinanceRevision, int>(
  FinanceRevision.new,
);

class FinanceRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

typedef PeriodKey = ({String from, String to, bool compare});

final cashFlowProvider = FutureProvider.autoDispose
    .family<CashFlowReport, PeriodKey>((ref, k) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(financeRevisionProvider);
      return ref.watch(financeRepositoryProvider).cashFlow(k);
    });

final ratiosProvider = FutureProvider.autoDispose
    .family<RatioReport, PeriodKey>((ref, k) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(financeRepositoryProvider).ratios(k);
    });

final cfMappingProvider = FutureProvider.autoDispose<List<CfMappingRow>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(financeRevisionProvider);
  return ref.watch(financeRepositoryProvider).mapping();
});

final yearEndPreviewProvider = FutureProvider.autoDispose
    .family<YearEndPreview, String>((ref, fy) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(financeRevisionProvider);
      return ref.watch(financeRepositoryProvider).yearEndPreview(fy);
    });

final yearEndClosesProvider = FutureProvider.autoDispose<List<YearEndClose>>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(financeRevisionProvider);
  return ref.watch(financeRepositoryProvider).yearEndCloses();
});

final budgetsProvider = FutureProvider.autoDispose
    .family<List<BudgetRow>, String>((ref, fy) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(financeRevisionProvider);
      return ref.watch(financeRepositoryProvider).budgets(fy);
    });

final budgetVarianceProvider = FutureProvider.autoDispose
    .family<BudgetVariance, ({String fy, String month})>((ref, k) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(financeRevisionProvider);
      return ref.watch(financeRepositoryProvider).variance(k.fy, k.month);
    });

final chequesProvider = FutureProvider.autoDispose
    .family<List<Cheque>, String>((ref, scope) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(financeRevisionProvider);
      return ref.watch(financeRepositoryProvider).cheques(scope);
    });

final chequeBooksProvider = FutureProvider.autoDispose<List<ChequeBook>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(financeRevisionProvider);
  return ref.watch(financeRepositoryProvider).books();
});

class FinanceRepository {
  FinanceRepository(this._api);
  final ApiClient _api;

  Map<String, dynamic> _q(PeriodKey k) => {
    'from': k.from,
    'to': k.to,
    'compare': '${k.compare}',
  };

  Future<CashFlowReport> cashFlow(PeriodKey k) async => CashFlowReport.fromJson(
    await _api.getJson('/reports/cash-flow', query: _q(k)),
  );

  Future<RatioReport> ratios(PeriodKey k) async => RatioReport.fromJson(
    await _api.getJson('/reports/ratios', query: _q(k)),
  );

  Future<List<CfMappingRow>> mapping() async => asJsonList(
    (await _api.getJson('/cash-flow/mapping'))['data'],
  ).map(CfMappingRow.fromJson).toList();

  Future<void> setMapping(String accountId, String? category) =>
      _api.patch('/cash-flow/mapping/$accountId', body: {'category': category});

  Future<YearEndPreview> yearEndPreview(String fy) async =>
      YearEndPreview.fromJson(
        await _api.getJson('/year-end/preview', query: {'fy': fy}),
      );

  Future<List<YearEndClose>> yearEndCloses() async => asJsonList(
    (await _api.getJson('/year-end/closes'))['data'],
  ).map(YearEndClose.fromJson).toList();

  Future<void> closeYear(String fy) =>
      _api.post('/year-end/close', body: {'fy': fy});

  Future<void> reopenYear(String id) => _api.post('/year-end/$id/reopen');

  Future<List<BudgetRow>> budgets(String fy) async => asJsonList(
    (await _api.getJson('/budgets', query: {'fy': fy}))['data'],
  ).map(BudgetRow.fromJson).toList();

  /// Replaces one row's months (an empty map deletes the row).
  Future<void> saveBudget(
    String fy,
    String accountId,
    Map<String, double> months, {
    String? costCentreId,
  }) => _api.patch(
    '/budgets',
    body: {
      'fy': fy,
      'rows': [
        {
          'accountId': accountId,
          'costCentreId': ?costCentreId,
          'months': months,
        },
      ],
    },
  );

  Future<int> copyBudget(
    String fromFy,
    String toFy,
    double uplift,
    bool replace,
  ) async => asInt(
    (await _api.postJson(
      '/budgets/copy',
      body: {
        'fromFy': fromFy,
        'toFy': toFy,
        'upliftPercent': uplift,
        'replace': replace,
      },
    ))['copied'],
  );

  Future<BudgetVariance> variance(String fy, String month) async =>
      BudgetVariance.fromJson(
        await _api.getJson(
          '/reports/budget-variance',
          query: {'fy': fy, 'month': month},
        ),
      );

  Future<List<Cheque>> cheques(String scope) async {
    final path = scope == 'due' ? '/cheques/due-today' : '/cheques';
    final json = await _api.getJson(
      path,
      query: scope == 'due' ? null : {'limit': '100'},
    );
    return asJsonList(json['data']).map(Cheque.fromJson).toList();
  }

  Future<void> recordCheque(Json body) => _api.post('/cheques', body: body);

  Future<void> chequeAction(String id, String action, [Json? body]) =>
      _api.post('/cheques/$id/$action', body: body ?? <String, dynamic>{});

  /// Prints the cheque for a bank payment. Uses the cheque already linked to
  /// the payment, or takes the next leaf of the bank account's cheque book.
  Future<({String chequeNo, ChequePrint data})> chequeForPayment(
    String paymentId,
  ) async {
    final got = await _api.getJson('/payments/$paymentId/cheque');
    var cheque = got['cheque'];
    cheque ??= await _api.post('/payments/$paymentId/cheque', body: <String, dynamic>{});
    final c = Cheque.fromJson(asJson(cheque));
    return (chequeNo: c.chequeNo, data: await chequePrint(c.id));
  }

  Future<ChequePrint> chequePrint(String id) async =>
      ChequePrint.fromJson(await _api.getJson('/cheques/$id/print'));

  Future<List<ChequeBook>> books() async => asJsonList(
    (await _api.getJson('/cheque-books'))['data'],
  ).map(ChequeBook.fromJson).toList();

  Future<void> addBook(Json body) => _api.post('/cheque-books', body: body);

  Future<List<ChequeLeaf>> register(String bookId) async => asJsonList(
    (await _api.getJson('/cheque-books/$bookId/register'))['leaves'],
  ).map(ChequeLeaf.fromJson).toList();

  Future<ChequeLayout> layout(String accountId) async => ChequeLayout.fromJson(
    await _api.getJson('/bank-accounts/$accountId/cheque-layout'),
  );

  Future<void> saveLayout(String accountId, ChequeLayout l) =>
      _api.patch('/bank-accounts/$accountId/cheque-layout', body: l.toJson());
}
