import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'rest_models.dart';

/// Bumped after every restaurant write so lists and the order reload.
final restRevisionProvider = NotifierProvider<RestRevision, int>(
  RestRevision.new,
);

class RestRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// How often the floor, order and kitchen screens reload on their own.
/// Tests override this with `null`.
final restPollProvider = Provider<Duration?>(
  (ref) => const Duration(seconds: 5),
);

final restaurantRepositoryProvider = Provider<RestaurantRepository>(
  (ref) => RestaurantRepository(ref.watch(apiClientProvider)),
);

final restSettingsProvider = FutureProvider.autoDispose<RestSettings>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(restRevisionProvider);
  return ref.watch(restaurantRepositoryProvider).settings();
});

final restCategoriesProvider = FutureProvider.autoDispose<List<MenuCategory>>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(restRevisionProvider);
  return ref.watch(restaurantRepositoryProvider).categories();
});

final restMenuProvider = FutureProvider.autoDispose<List<MenuEntry>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(restRevisionProvider);
  return ref.watch(restaurantRepositoryProvider).menu();
});

final restFloorProvider = FutureProvider.autoDispose<List<FloorArea>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(restRevisionProvider);
  return ref.watch(restaurantRepositoryProvider).floor();
});

final restOrderProvider = FutureProvider.autoDispose.family<RestOrder, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(restRevisionProvider);
  return ref.watch(restaurantRepositoryProvider).order(id);
});

/// Orders other than dine-in. [status] is `active` or `settled,cancelled`.
final restOrdersProvider = FutureProvider.autoDispose
    .family<List<OrderSummary>, String>((ref, status) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(restRevisionProvider);
      return ref.watch(restaurantRepositoryProvider).orders(status: status);
    });

/// Tickets for a station (`''` for all) in the given statuses.
final restKotsProvider = FutureProvider.autoDispose
    .family<List<Kot>, ({String station, String status})>((ref, q) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(restRevisionProvider);
      return ref
          .watch(restaurantRepositoryProvider)
          .kots(station: q.station, status: q.status);
    });

/// Runs [onTick] every poll interval until the owner is disposed.
class RestPoller {
  RestPoller(Duration? every, void Function() onTick) {
    if (every != null) _timer = Timer.periodic(every, (_) => onTick());
  }

  Timer? _timer;

  void dispose() => _timer?.cancel();
}

class SendKotResult {
  const SendKotResult(this.newKotIds, this.order);

  final List<String> newKotIds;
  final RestOrder order;
}

class SettleResult {
  const SettleResult({
    required this.order,
    required this.invoiceNumber,
    required this.total,
    this.chargedToRoom = false,
  });

  final RestOrder order;
  final String invoiceNumber;
  final double total;
  final bool chargedToRoom;
}

class RestaurantRepository {
  RestaurantRepository(this._api);

  final ApiClient _api;

  // ----------------------------------------------------------------- setup

  Future<RestSettings> settings() async =>
      RestSettings.fromJson(await _api.getJson('/restaurant/settings'));

  Future<void> saveSettings({
    double? serviceChargePct,
    double? serviceChargeGst,
  }) => _api.patch(
    '/restaurant/settings',
    body: {
      'serviceChargePct': ?serviceChargePct,
      'serviceChargeGst': ?serviceChargeGst,
    },
  );

  Future<List<MenuCategory>> categories() async => (await _api.getPage(
    '/restaurant/categories',
    MenuCategory.fromJson,
  )).data;

  Future<void> saveCategory({String? id, required Json body}) => id == null
      ? _api.post('/restaurant/categories', body: body)
      : _api.patch('/restaurant/categories/$id', body: body);

  Future<void> deleteCategory(String id) =>
      _api.delete('/restaurant/categories/$id');

  Future<List<MenuEntry>> menu() async =>
      (await _api.getPage('/restaurant/menu', MenuEntry.fromJson)).data;

  Future<void> createMenuEntry(Json body) =>
      _api.post('/restaurant/menu', body: body);

  Future<void> saveMenuEntry(String itemId, Json body) =>
      _api.patch('/restaurant/menu/$itemId', body: body);

  Future<void> deleteMenuEntry(String itemId) =>
      _api.delete('/restaurant/menu/$itemId');

  Future<List<FloorArea>> floor() async {
    final json = await _api.getJson('/restaurant/floor');
    return asJsonList(json['areas']).map(FloorArea.fromJson).toList();
  }

  Future<void> saveArea({String? id, required Json body}) => id == null
      ? _api.post('/restaurant/areas', body: body)
      : _api.patch('/restaurant/areas/$id', body: body);

  Future<void> deleteArea(String id) => _api.delete('/restaurant/areas/$id');

  Future<void> saveTable({String? id, required Json body}) => id == null
      ? _api.post('/restaurant/tables', body: body)
      : _api.patch('/restaurant/tables/$id', body: body);

  Future<void> deleteTable(String id) => _api.delete('/restaurant/tables/$id');

  // ---------------------------------------------------------------- orders

  Future<List<OrderSummary>> orders({String status = 'active'}) async {
    final page = await _api.getPage(
      '/restaurant/orders',
      OrderSummary.fromJson,
      query: {'status': status, 'limit': 100},
    );
    return page.data.where((o) => o.kind != 'dine_in').toList();
  }

  Future<RestOrder> order(String id) async =>
      RestOrder.fromJson(await _api.getJson('/restaurant/orders/$id'));

  Future<RestOrder> createOrder(Json body) async =>
      RestOrder.fromJson(await _api.postJson('/restaurant/orders', body: body));

  Future<RestOrder> _post(String id, String action, [Json? body]) async =>
      RestOrder.fromJson(
        await _api.postJson('/restaurant/orders/$id/$action', body: body),
      );

  Future<RestOrder> addItems(
    String id,
    List<({String itemId, double qty, String? note})> items,
  ) => _post(id, 'lines', {
    'items': [
      for (final i in items)
        {'itemId': i.itemId, 'qty': i.qty, 'note': ?i.note},
    ],
  });

  Future<void> editLine(String orderId, String lineId, Json body) =>
      _api.patch('/restaurant/orders/$orderId/lines/$lineId', body: body);

  Future<RestOrder> cancelLine(
    String orderId,
    String lineId, {
    String? reason,
  }) => _post(orderId, 'lines/$lineId/cancel', {'reason': ?reason});

  Future<SendKotResult> sendKot(String id) async {
    final json = await _api.postJson('/restaurant/orders/$id/send-kot');
    return SendKotResult(
      asStringList(json['newKotIds']),
      RestOrder.fromJson(asJson(json['order'])),
    );
  }

  Future<RestOrder> editOrder(String id, Json body) async => RestOrder.fromJson(
    await _api.patchJson('/restaurant/orders/$id', body: body),
  );

  Future<RestOrder> move(String id, String tableId) =>
      _post(id, 'move', {'tableId': tableId});

  Future<RestOrder> merge(String id, String fromOrderId) =>
      _post(id, 'merge', {'fromOrderId': fromOrderId});

  Future<RestOrder> printBill(
    String id, {
    double? discountPct,
    double? discountAmount,
    String? discountReason,
    bool waiveServiceCharge = false,
  }) => _post(id, 'print-bill', {
    if ((discountPct ?? 0) > 0) 'discountPct': discountPct,
    if ((discountAmount ?? 0) > 0) 'discountAmount': discountAmount,
    if ((discountPct ?? 0) > 0 || (discountAmount ?? 0) > 0)
      'discountReason': discountReason,
    if (waiveServiceCharge) 'waiveServiceCharge': true,
  });

  Future<RestOrder> reopen(String id) => _post(id, 'reopen');

  Future<RestOrder> cancelOrder(String id, String reason) =>
      _post(id, 'cancel', {'reason': reason});

  Future<SettleResult> settle(
    String id,
    List<({String mode, double amount, String? reference})> payments, {
    String? roomNumber,
  }) async {
    final json = await _api.postJson(
      '/restaurant/orders/$id/settle',
      body: {
        if (roomNumber == null)
          'payments': [
            for (final p in payments)
              {'mode': p.mode, 'amount': p.amount, 'reference': ?p.reference},
          ],
        'chargeToRoom': ?(roomNumber == null
            ? null
            : {'roomNumber': roomNumber}),
      },
    );
    final invoice = asJson(json['invoice']);
    final folio = asJson(json['folio']);
    return SettleResult(
      order: RestOrder.fromJson(asJson(json['order'])),
      invoiceNumber: roomNumber == null
          ? asString(invoice['number'])
          : 'charged to room $roomNumber',
      total: roomNumber == null
          ? asDouble(invoice['total'])
          : asDouble(folio['amount']),
      chargedToRoom: roomNumber != null,
    );
  }

  // --------------------------------------------------------------- kitchen

  Future<List<Kot>> kots({String station = '', String status = ''}) async {
    final json = await _api.getJson(
      '/restaurant/kots',
      query: {
        if (station.isNotEmpty) 'station': station,
        if (status.isNotEmpty) 'status': status,
      },
    );
    return asJsonList(json['data']).map(Kot.fromJson).toList();
  }

  Future<Kot> kot(String id) async =>
      Kot.fromJson(await _api.getJson('/restaurant/kots/$id'));

  Future<void> advanceKot(String id, KitchenStatus to) =>
      _api.patch('/restaurant/kots/$id/status', body: {'status': to.wire});

  Future<void> advanceLine(String id, KitchenStatus to) =>
      _api.patch('/restaurant/kot-lines/$id/status', body: {'status': to.wire});
}
