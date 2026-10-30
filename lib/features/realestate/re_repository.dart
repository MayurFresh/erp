import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 're_models.dart';

/// Real-estate data whose lists and details reload after a write.
enum RKind { units, plans, bookings, demands, rera }

final rRevisionProvider =
    NotifierProvider.family<RRevisionNotifier, int, RKind>(
      RRevisionNotifier.new,
    );

class RRevisionNotifier extends Notifier<int> {
  RRevisionNotifier(this.kind);

  final RKind kind;

  @override
  int build() => 0;

  void bump() => state++;
}

extension RWatchRevisions on Ref {
  void watchR(Iterable<RKind> kinds) {
    for (final kind in kinds) {
      watch(rRevisionProvider(kind));
    }
  }
}

extension RRevisionRef on WidgetRef {
  /// Bumps real-estate kinds and the app-wide kinds a booking touches.
  void bumpR(Iterable<RKind> kinds, {bool money = false}) {
    for (final kind in kinds) {
      read(rRevisionProvider(kind).notifier).bump();
    }
    if (money) {
      bump(const [DataKind.parties, DataKind.accounts, DataKind.payments]);
    }
  }
}

final realEstateRepositoryProvider = Provider<RealEstateRepository>(
  (ref) => RealEstateRepository(ref.watch(apiClientProvider)),
);

final bookingProvider = FutureProvider.autoDispose.family<Booking, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchR(const [RKind.bookings, RKind.demands, RKind.units]);
  ref.watchRevisions(const [DataKind.payments]);
  return ref.watch(realEstateRepositoryProvider).booking(id);
});

final demandProvider = FutureProvider.autoDispose.family<Demand, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchR(const [RKind.demands]);
  ref.watchRevisions(const [DataKind.payments]);
  return ref.watch(realEstateRepositoryProvider).demand(id);
});

final paymentPlanProvider = FutureProvider.autoDispose
    .family<PaymentPlan, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watchR(const [RKind.plans]);
      return ref.watch(realEstateRepositoryProvider).plan(id);
    });

/// All units of a project (for the stacking view and the unit picker).
final projectUnitsProvider = FutureProvider.autoDispose
    .family<List<Unit>, String>((ref, projectId) {
      ref.watch(activeCompanyIdProvider);
      ref.watchR(const [RKind.units, RKind.bookings]);
      return ref.watch(realEstateRepositoryProvider).allUnits(projectId);
    });

/// Active payment plans of a project.
final projectPlansProvider = FutureProvider.autoDispose
    .family<List<PaymentPlan>, String>((ref, projectId) async {
      ref.watch(activeCompanyIdProvider);
      ref.watchR(const [RKind.plans]);
      final page = await ref
          .watch(realEstateRepositoryProvider)
          .plans(projectId: projectId, activeOnly: true, limit: 100);
      return page.data;
    });

final projectReraProvider = FutureProvider.autoDispose
    .family<ProjectRera, String>((ref, projectId) {
      ref.watch(activeCompanyIdProvider);
      ref.watchR(const [RKind.rera, RKind.demands]);
      ref.watchRevisions(const [DataKind.payments, DataKind.accounts]);
      return ref.watch(realEstateRepositoryProvider).rera(projectId);
    });

/// A `{projectId, name, code}` entry for project pickers.
class ProjectOption {
  const ProjectOption({required this.id, required this.name, this.code = ''});

  factory ProjectOption.fromJson(Json json) => ProjectOption(
    id: asString(json['id']),
    name: asString(json['name']),
    code: asString(json['code']),
  );

  final String id;
  final String name;
  final String code;

  String get label => code.isEmpty ? name : '$code · $name';
}

final projectOptionsProvider = FutureProvider.autoDispose<List<ProjectOption>>((
  ref,
) async {
  ref.watch(activeCompanyIdProvider);
  final page = await ref.watch(realEstateRepositoryProvider).projects();
  return page.data;
});

class RealEstateRepository {
  RealEstateRepository(this._api);

  final ApiClient _api;

  // ---------------------------------------------------------------- projects

  Future<Paged<ProjectOption>> projects() =>
      _api.getPage('/projects', ProjectOption.fromJson, query: {'limit': 200});

  /// `PATCH /projects/:id` with the RERA fields; `null` clears one.
  Future<void> updateProjectRera(
    String projectId, {
    required String? reraRegNo,
    required String? reraAccountId,
  }) async {
    await _api.patchJson(
      '/projects/$projectId',
      body: {'reraRegNo': reraRegNo, 'reraAccountId': reraAccountId},
    );
  }

  Future<ProjectRera> rera(String projectId, {String? to}) async =>
      ProjectRera.fromJson(
        await _api.getJson('/projects/$projectId/rera', query: {'to': to}),
      );

  // ------------------------------------------------------------------- units

  Future<Paged<Unit>> units({
    String? projectId,
    UnitStatus? status,
    String? wing,
    String? unitType,
    String? q,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/units',
    Unit.fromJson,
    query: {
      'projectId': projectId,
      'status': status?.api,
      'wing': wing,
      'unitType': unitType,
      'q': q,
      'offset': offset,
      'limit': limit,
    },
  );

  /// Every unit of [projectId], paging through the list.
  Future<List<Unit>> allUnits(String projectId) async {
    final all = <Unit>[];
    while (true) {
      final page = await units(
        projectId: projectId,
        offset: all.length,
        limit: 200,
      );
      all.addAll(page.data);
      if (page.data.isEmpty || all.length >= page.total) return all;
    }
  }

  Future<Unit> unit(String id) async =>
      Unit.fromJson(await _api.getJson('/units/$id'));

  Future<Unit> createUnit(String projectId, Json body) async => Unit.fromJson(
    await _api.postJson(
      '/units',
      body: withoutNulls({'projectId': projectId, ...body}),
    ),
  );

  Future<List<Unit>> createUnits(String projectId, List<Json> units) async =>
      Paged.fromJson(
        await _api.postJson(
          '/units',
          body: {
            'projectId': projectId,
            'units': [for (final u in units) withoutNulls(u)],
          },
        ),
        Unit.fromJson,
      ).data;

  /// Sends the changed fields; `null` clears an optional one.
  Future<Unit> updateUnit(String id, Json changes) async =>
      Unit.fromJson(await _api.patchJson('/units/$id', body: changes));

  Future<Unit> setUnitHold(String id, bool hold) =>
      updateUnit(id, {'status': hold ? 'hold' : 'available'});

  // ---------------------------------------------------------- payment plans

  Future<Paged<PaymentPlan>> plans({
    String? projectId,
    bool activeOnly = false,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/payment-plans',
    PaymentPlan.fromJson,
    query: {
      'projectId': projectId,
      if (activeOnly) 'activeOnly': true,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<PaymentPlan> plan(String id) async =>
      PaymentPlan.fromJson(await _api.getJson('/payment-plans/$id'));

  Future<PaymentPlan> createPlan({
    required String projectId,
    required String name,
    required List<Json> stages,
  }) async => PaymentPlan.fromJson(
    await _api.postJson(
      '/payment-plans',
      body: {'projectId': projectId, 'name': name, 'stages': stages},
    ),
  );

  Future<PaymentPlan> updatePlan(String id, Json changes) async =>
      PaymentPlan.fromJson(
        await _api.patchJson('/payment-plans/$id', body: changes),
      );

  // ---------------------------------------------------------------- bookings

  Future<Paged<Booking>> bookings({
    String? projectId,
    String? unitId,
    String? customerId,
    BookingStatus? status,
    String? q,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/bookings',
    Booking.fromJson,
    query: {
      'projectId': projectId,
      'unitId': unitId,
      'customerId': customerId,
      'status': status?.api,
      'q': q,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Booking> booking(String id) async =>
      Booking.fromJson(await _api.getJson('/bookings/$id'));

  Future<Booking> createBooking(Json body) async => Booking.fromJson(
    await _api.postJson('/bookings', body: withoutNulls(body)),
  );

  Future<Booking> updateBooking(String id, Json changes) async =>
      Booking.fromJson(await _api.patchJson('/bookings/$id', body: changes));

  Future<Booking> recordAgreement(
    String id, {
    required String agreementNo,
    required String agreementDate,
  }) async => Booking.fromJson(
    await _api.postJson(
      '/bookings/$id/agreement',
      body: {'agreementNo': agreementNo, 'agreementDate': agreementDate},
    ),
  );

  Future<Demand> raiseDemand(
    String id, {
    required List<String> stageIds,
    String? date,
    String? dueDate,
  }) async => Demand.fromJson(
    await _api.postJson(
      '/bookings/$id/demands',
      body: withoutNulls({
        'stageIds': stageIds,
        'date': date,
        'dueDate': dueDate,
      }),
    ),
  );

  Future<Booking> recordPossession(String id, String date) async =>
      Booking.fromJson(
        await _api.postJson('/bookings/$id/possession', body: {'date': date}),
      );

  Future<Booking> cancelBooking(String id, String reason) async =>
      Booking.fromJson(
        await _api.postJson('/bookings/$id/cancel', body: {'reason': reason}),
      );

  // ----------------------------------------------------------------- demands

  Future<Paged<Demand>> demands({
    String? bookingId,
    String? projectId,
    String? customerId,
    String? status,
    String? paymentStatus,
    String? from,
    String? to,
    String? q,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/demands',
    Demand.fromJson,
    query: {
      'bookingId': bookingId,
      'projectId': projectId,
      'customerId': customerId,
      'status': status,
      'paymentStatus': paymentStatus,
      'from': from,
      'to': to,
      'q': q,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Demand> demand(String id) async =>
      Demand.fromJson(await _api.getJson('/demands/$id'));

  Future<Demand> cancelDemand(String id, String reason) async =>
      Demand.fromJson(
        await _api.postJson('/demands/$id/cancel', body: {'reason': reason}),
      );
}
