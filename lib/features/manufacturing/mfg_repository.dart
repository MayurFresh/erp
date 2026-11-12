import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'mfg_models.dart';

/// Bumped after every manufacturing write so lists and details reload.
final mfgRevisionProvider = NotifierProvider<MfgRevision, int>(MfgRevision.new);

class MfgRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final mfgRepositoryProvider = Provider<MfgRepository>(
  (ref) => MfgRepository(ref.watch(apiClientProvider)),
);

FutureProvider<T> _watched<T>(Future<T> Function(MfgRepository r) load) =>
    FutureProvider<T>((ref) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(mfgRevisionProvider);
      return load(ref.watch(mfgRepositoryProvider));
    });

final mfgHomeProvider = _watched((r) => r.home());
final mfgOverheadProvider = _watched((r) => r.overheadPct());
final mfgWorkCentresProvider = _watched((r) => r.workCentres());
final mfgShortagesProvider = _watched((r) => r.shortages());
final mfgItc04Provider = _watched((r) => r.itc04());

final mfgBomsProvider = FutureProvider.family<List<BomSummary>, String>((ref, q) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(mfgRevisionProvider);
  return ref.watch(mfgRepositoryProvider).boms(q: q);
});

final mfgBomProvider = FutureProvider.family<Bom, String>((ref, id) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(mfgRevisionProvider);
  return ref.watch(mfgRepositoryProvider).bom(id);
});

final mfgOrdersProvider = FutureProvider.family<List<OrderSummary>, String>((ref, status) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(mfgRevisionProvider);
  return ref.watch(mfgRepositoryProvider).orders(status: status);
});

final mfgOrderProvider = FutureProvider.family<MfgOrder, String>((ref, id) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(mfgRevisionProvider);
  return ref.watch(mfgRepositoryProvider).order(id);
});

final mfgChallansProvider = FutureProvider.family<List<ChallanSummary>, String>((ref, status) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(mfgRevisionProvider);
  return ref.watch(mfgRepositoryProvider).challans(status: status);
});

final mfgChallanProvider = FutureProvider.family<Challan, String>((ref, id) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(mfgRevisionProvider);
  return ref.watch(mfgRepositoryProvider).challan(id);
});

class MfgRepository {
  MfgRepository(this._api);

  final ApiClient _api;

  static const _b = '/manufacturing';

  Future<MfgHome> home() async => MfgHome.fromJson(await _api.getJson('$_b/home'));

  Future<double> overheadPct() async =>
      asDouble((await _api.getJson('$_b/settings'))['overheadPct']);

  /// `PUT /settings` also answers PATCH, because the client has no PUT.
  Future<void> saveOverheadPct(double pct) =>
      _api.patch('$_b/settings', body: {'overheadPct': pct});

  Future<List<WorkCentre>> workCentres() async =>
      (await _api.getPage('$_b/work-centres', WorkCentre.fromJson)).data;

  Future<void> saveWorkCentre({String? id, required Json body}) => id == null
      ? _api.post('$_b/work-centres', body: body)
      : _api.patch('$_b/work-centres/$id', body: body);

  // ------------------------------------------------------------------ BOMs

  Future<List<BomSummary>> boms({String q = ''}) async => (await _api.getPage(
    '$_b/boms',
    BomSummary.fromJson,
    query: {if (q.isNotEmpty) 'q': q, 'limit': 100},
  )).data;

  Future<Bom> bom(String id) async => Bom.fromJson(await _api.getJson('$_b/boms/$id'));

  Future<Bom> createBom(Json body) async =>
      Bom.fromJson(await _api.postJson('$_b/boms', body: body));

  Future<Bom> updateBom(String id, Json body) async =>
      Bom.fromJson(await _api.patchJson('$_b/boms/$id', body: body));

  Future<Bom> activateBom(String id) async =>
      Bom.fromJson(await _api.postJson('$_b/boms/$id/activate'));

  Future<Bom> copyBom(String id) async =>
      Bom.fromJson(await _api.postJson('$_b/boms/$id/copy'));

  Future<void> deleteBom(String id) => _api.delete('$_b/boms/$id');

  Future<Explosion> explode({required String bomId, required double qty}) async =>
      Explosion.fromJson(
        await _api.getJson('$_b/explode', query: {'bomId': bomId, 'qty': qty}),
      );

  // ---------------------------------------------------------------- orders

  Future<List<OrderSummary>> orders({String status = ''}) async => (await _api.getPage(
    '$_b/orders',
    OrderSummary.fromJson,
    query: {if (status.isNotEmpty) 'status': status, 'limit': 100},
  )).data;

  Future<MfgOrder> order(String id) async =>
      MfgOrder.fromJson(await _api.getJson('$_b/orders/$id'));

  Future<MfgOrder> createOrder(Json body) async =>
      MfgOrder.fromJson(await _api.postJson('$_b/orders', body: body));

  Future<MfgOrder> updateOrder(String id, Json body) async =>
      MfgOrder.fromJson(await _api.patchJson('$_b/orders/$id', body: body));

  Future<MfgOrder> setMaterial(String id, String itemId, double plannedQty) async =>
      MfgOrder.fromJson(
        await _api.patchJson('$_b/orders/$id/materials/$itemId', body: {'plannedQty': plannedQty}),
      );

  Future<MfgOrder> _act(String id, String action, [Json? body]) async =>
      MfgOrder.fromJson(await _api.postJson('$_b/orders/$id/$action', body: body ?? {}));

  Future<MfgOrder> release(String id) => _act(id, 'release');
  Future<MfgOrder> cancel(String id, String reason) => _act(id, 'cancel', {'reason': reason});
  Future<MfgOrder> issue(String id, Json body) => _act(id, 'issue', body);
  Future<MfgOrder> returnMaterial(String id, Json body) => _act(id, 'return', body);
  Future<MfgOrder> output(String id, Json body) => _act(id, 'output', body);
  Future<MfgOrder> inspect(String id, Json body) => _act(id, 'inspections', body);
  Future<MfgOrder> close(String id, String? note) =>
      _act(id, 'close', {'note': ?note});

  // -------------------------------------------------------------- planning

  Future<List<Shortage>> shortages() async {
    final j = await _api.getJson('$_b/mrp');
    return asJsonList(j['shortages']).map(Shortage.fromJson).toList();
  }

  Future<Json> createPurchaseOrder(Json body) =>
      _api.postJson('$_b/mrp/purchase-order', body: body);

  // -------------------------------------------------------------- job work

  Future<List<ChallanSummary>> challans({String status = ''}) async => (await _api.getPage(
    '$_b/jobwork',
    ChallanSummary.fromJson,
    query: {if (status.isNotEmpty) 'status': status, 'limit': 100},
  )).data;

  Future<Challan> challan(String id) async =>
      Challan.fromJson(await _api.getJson('$_b/jobwork/$id'));

  Future<Challan> createChallan(Json body) async =>
      Challan.fromJson(await _api.postJson('$_b/jobwork', body: body));

  Future<Challan> receive(String id, Json body) async =>
      Challan.fromJson(await _api.postJson('$_b/jobwork/$id/receive', body: body));

  Future<Challan> cancelChallan(String id, String reason) async =>
      Challan.fromJson(await _api.postJson('$_b/jobwork/$id/cancel', body: {'reason': reason}));

  Future<List<Itc04Row>> itc04() async {
    final j = await _api.getJson('$_b/jobwork/itc04');
    return asJsonList(j['rows']).map(Itc04Row.fromJson).toList();
  }
}
