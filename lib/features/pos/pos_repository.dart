import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'pos_models.dart';

/// Bumped after a session opens or closes, a sale, a return or a hold.
enum PosKind { session, held, sales }

final posRevisionProvider =
    NotifierProvider.family<PosRevisionNotifier, int, PosKind>(
      PosRevisionNotifier.new,
    );

class PosRevisionNotifier extends Notifier<int> {
  PosRevisionNotifier(this.kind);

  final PosKind kind;

  @override
  int build() => 0;

  void bump() => state++;
}

final posRepositoryProvider = Provider<PosRepository>(
  (ref) => PosRepository(ref.watch(apiClientProvider)),
);

/// The caller's open register session, or null when none is open.
final currentPosSessionProvider = FutureProvider.autoDispose<PosSession?>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(posRevisionProvider(PosKind.session));
  return ref.watch(posRepositoryProvider).currentSession();
});

final posSessionReportProvider = FutureProvider.autoDispose
    .family<SessionReport, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(posRevisionProvider(PosKind.session));
      ref.watch(posRevisionProvider(PosKind.sales));
      return ref.watch(posRepositoryProvider).report(id);
    });

/// Company setting: counter prices include GST (MRP).
final posInclusiveProvider = FutureProvider.autoDispose<bool>((ref) async {
  ref.watch(activeCompanyIdProvider);
  final j = await ref.watch(apiClientProvider).getJson('/pos/settings');
  return j['pricesIncludeTax'] == true;
});

final posSessionsProvider = FutureProvider.autoDispose<Paged<PosSession>>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(posRevisionProvider(PosKind.session));
  return ref.watch(posRepositoryProvider).sessions();
});

final posHeldProvider = FutureProvider.autoDispose
    .family<List<HeldBill>, String>((ref, locationId) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(posRevisionProvider(PosKind.held));
      return ref.watch(posRepositoryProvider).held(locationId);
    });

final posQuickItemsProvider = FutureProvider.autoDispose
    .family<List<PosItem>, String>((ref, locationId) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(revisionProvider(DataKind.items));
      return ref.watch(posRepositoryProvider).frequent(locationId);
    });

class PosRepository {
  PosRepository(this._api);

  final ApiClient _api;

  Future<PosSession?> currentSession() async {
    final j = await _api.getJson('/pos/sessions/current');
    final s = asJsonOrNull(j['session']);
    return s == null ? null : PosSession.fromJson(s);
  }

  Future<PosSession> openSession(String locationId, double float) async =>
      PosSession.fromJson(
        await _api.postJson(
          '/pos/sessions',
          body: {'locationId': locationId, 'openingFloat': float},
        ),
      );

  Future<SessionReport> report(String id) async =>
      SessionReport.fromJson(await _api.getJson('/pos/sessions/$id/report'));

  Future<SessionReport> closeSession(
    String id,
    Map<String, double> counted, {
    String? notes,
    bool confirmHeld = false,
  }) async => SessionReport.fromJson(
    await _api.postJson(
      '/pos/sessions/$id/close',
      body: {
        'counted': counted,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
        if (confirmHeld) 'confirmHeld': true,
      },
    ),
  );

  Future<void> cashMove(
    String sessionId,
    String kind,
    double amount,
    String reason,
  ) => _api.post(
    '/pos/sessions/$sessionId/cash-moves',
    body: {'kind': kind, 'amount': amount, 'reason': reason},
  );

  Future<Paged<PosSession>> sessions({String? status, int limit = 50}) =>
      _api.getPage(
        '/pos/sessions',
        PosSession.fromJson,
        query: {'status': ?status, 'limit': limit},
      );

  Future<List<PosItem>> search(String q, String locationId) async {
    final j = await _api.getJson(
      '/pos/items',
      query: {'q': q, 'locationId': locationId},
    );
    return asJsonList(j['data']).map(PosItem.fromJson).toList();
  }

  /// Items for an exact barcode or SKU hit come back first and alone.
  Future<({bool exact, List<PosItem> items})> lookup(
    String q,
    String locationId,
  ) async {
    final j = await _api.getJson(
      '/pos/items',
      query: {'q': q, 'locationId': locationId},
    );
    return (
      exact: j['exact'] == true,
      items: asJsonList(j['data']).map(PosItem.fromJson).toList(),
    );
  }

  Future<List<PosItem>> frequent(String locationId) async {
    final j = await _api.getJson(
      '/pos/items/frequent',
      query: {'locationId': locationId, 'limit': 24},
    );
    return asJsonList(j['data']).map(PosItem.fromJson).toList();
  }

  Future<PosSale> sell({
    required String sessionId,
    required List<CartLine> lines,
    required List<PaymentInput> payments,
    String? partyId,
    BillDiscount? discount,
    bool allowCredit = false,
    double? expectedTotal,
    String? idempotencyKey,
  }) async => PosSale.fromJson(
    await _api.postJson(
      '/pos/sales',
      idempotencyKey: idempotencyKey,
      body: {
        'sessionId': sessionId,
        'partyId': ?partyId,
        'lines': [for (final l in lines) l.toApi()],
        'payments': [for (final p in payments) p.toApi()],
        if (discount != null && discount.value > 0)
          'billDiscount': discount.toApi(),
        if (allowCredit) 'allowCredit': true,
        'expectedTotal': ?expectedTotal,
      },
    ),
  );

  Future<PosSale> sale(String id) async =>
      PosSale.fromJson(await _api.getJson('/pos/sales/$id'));

  Future<Paged<Json>> sales({String? q, String? sessionId, int limit = 30}) =>
      _api.getPage(
        '/pos/sales',
        (j) => j,
        query: {
          if (q != null && q.isNotEmpty) 'q': q,
          'sessionId': ?sessionId,
          'limit': limit,
        },
      );

  Future<PosSale> returnSale(
    String saleId, {
    required List<({String lineId, double qty})> lines,
    required String reason,
    required String refundMode,
  }) async => PosSale.fromJson(
    await _api.postJson(
      '/pos/sales/$saleId/return',
      body: {
        'lines': [
          for (final l in lines) {'invoiceLineId': l.lineId, 'qty': l.qty},
        ],
        'reason': reason,
        'refundMode': refundMode,
      },
    ),
  );

  Future<List<HeldBill>> held(String locationId) async {
    final j = await _api.getJson(
      '/pos/held',
      query: {'locationId': locationId},
    );
    return asJsonList(j['data']).map(HeldBill.fromJson).toList();
  }

  Future<void> hold(
    String sessionId,
    Map<String, Object?> payload, {
    String? label,
    double total = 0,
  }) => _api.post(
    '/pos/held',
    body: {
      'sessionId': sessionId,
      'payload': payload,
      if (label != null && label.isNotEmpty) 'label': label,
      'total': total,
    },
  );

  Future<HeldBill> resume(String id) async =>
      HeldBill.fromJson(await _api.postJson('/pos/held/$id/resume'));

  Future<void> discardHeld(String id) => _api.delete('/pos/held/$id');
}
