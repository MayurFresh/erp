import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import '../invoices/invoice_model.dart';

class TopItem {
  const TopItem({
    required this.itemId,
    required this.name,
    required this.qty,
    required this.amount,
  });

  factory TopItem.fromJson(Json json) => TopItem(
    itemId: asString(json['itemId']),
    name: asString(json['name']),
    qty: asDouble(json['qty']),
    amount: asDouble(json['amount']),
  );

  final String itemId;
  final String name;
  final double qty;
  final double amount;
}

class Dashboard {
  const Dashboard({
    required this.salesToday,
    required this.salesThisMonth,
    required this.invoicesThisMonth,
    required this.lowStockCount,
    this.recentInvoices = const [],
    this.topItems = const [],
    this.receivables,
    this.payables,
    this.cashAndBank,
    this.purchasesThisMonth,
  });

  factory Dashboard.fromJson(Json json) => Dashboard(
    salesToday: asDouble(json['salesToday']),
    salesThisMonth: asDouble(json['salesThisMonth']),
    invoicesThisMonth: asInt(json['invoicesThisMonth']),
    lowStockCount: asInt(json['lowStockCount']),
    recentInvoices: asJsonList(
      json['recentInvoices'],
    ).map(Invoice.fromJson).toList(),
    topItems: asJsonList(json['topItems']).map(TopItem.fromJson).toList(),
    receivables: asDoubleOrNull(json['receivables']),
    payables: asDoubleOrNull(json['payables']),
    cashAndBank: asDoubleOrNull(json['cashAndBank']),
    purchasesThisMonth: asDoubleOrNull(json['purchasesThisMonth']),
  );

  final double salesToday;
  final double salesThisMonth;
  final int invoicesThisMonth;
  final int lowStockCount;
  final List<Invoice> recentInvoices;
  final List<TopItem> topItems;

  /// v1.1 fields; `null` when the server does not send them.
  final double? receivables;
  final double? payables;
  final double? cashAndBank;
  final double? purchasesThisMonth;
}

final dashboardRepositoryProvider = Provider<DashboardRepository>(
  (ref) => DashboardRepository(ref.watch(apiClientProvider)),
);

final dashboardProvider = FutureProvider.autoDispose<Dashboard>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watchRevisions(const [...moneyKinds, DataKind.stock, DataKind.expenses]);
  return ref.watch(dashboardRepositoryProvider).get();
});

class DashboardRepository {
  DashboardRepository(this._api);

  final ApiClient _api;

  Future<Dashboard> get() async =>
      Dashboard.fromJson(await _api.getJson('/dashboard'));
}
