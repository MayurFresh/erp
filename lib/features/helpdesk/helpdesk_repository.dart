import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'helpdesk_models.dart';

/// Bumped after any helpdesk or contract write so lists and details reload.
final helpdeskRevisionProvider = NotifierProvider<HelpdeskRevision, int>(
  HelpdeskRevision.new,
);

class HelpdeskRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final helpdeskRepositoryProvider = Provider<HelpdeskRepository>(
  (ref) => HelpdeskRepository(ref.watch(apiClientProvider)),
);

typedef TicketFilter = ({String status, bool mine, String q});

final ticketListProvider = FutureProvider.autoDispose
    .family<List<Ticket>, TicketFilter>((ref, f) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(helpdeskRevisionProvider);
      return ref.watch(helpdeskRepositoryProvider).tickets(f);
    });

final ticketDetailProvider = FutureProvider.autoDispose.family<Ticket, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(helpdeskRevisionProvider);
  return ref.watch(helpdeskRepositoryProvider).ticket(id);
});

final contractListProvider = FutureProvider.autoDispose
    .family<List<Contract>, String>((ref, status) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(helpdeskRevisionProvider);
      return ref.watch(helpdeskRepositoryProvider).contracts(status);
    });

final contractDetailProvider = FutureProvider.autoDispose
    .family<Contract, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(helpdeskRevisionProvider);
      return ref.watch(helpdeskRepositoryProvider).contract(id);
    });

final helpdeskStaffProvider =
    FutureProvider.autoDispose<List<({String id, String name})>>((ref) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(helpdeskRepositoryProvider).staff();
    });

final helpdeskSummaryProvider = FutureProvider.autoDispose<Json>((ref) {
  ref.watch(activeCompanyIdProvider);
  return ref.watch(helpdeskRepositoryProvider).summary();
});

final helpdeskSettingsProvider = FutureProvider.autoDispose<Json>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(helpdeskRevisionProvider);
  return ref.watch(helpdeskRepositoryProvider).settings();
});

class HelpdeskRepository {
  HelpdeskRepository(this._api);

  final ApiClient _api;

  Future<List<Ticket>> tickets(TicketFilter f) async => asJsonList(
    (await _api.getJson(
      '/helpdesk/tickets',
      query: {
        if (f.status == 'open') 'open': 'true',
        if (f.status == 'breached') 'breached': 'true',
        if (f.status == 'resolved') 'status': 'resolved',
        if (f.mine) 'mine': 'true',
        if (f.q.isNotEmpty) 'q': f.q,
        'limit': 200,
      },
    ))['data'],
  ).map(Ticket.fromJson).toList();

  Future<Ticket> ticket(String id) async =>
      Ticket.fromJson(await _api.getJson('/helpdesk/tickets/$id'));

  Future<Ticket> createTicket(Json body) async =>
      Ticket.fromJson(await _api.postJson('/helpdesk/tickets', body: body));

  Future<Ticket> updateTicket(String id, Json body) async => Ticket.fromJson(
    await _api.patchJson('/helpdesk/tickets/$id', body: body),
  );

  Future<Ticket> addMessage(String id, Json body) async => Ticket.fromJson(
    await _api.postJson('/helpdesk/tickets/$id/messages', body: body),
  );

  Future<Ticket> setStatus(String id, String status) async => Ticket.fromJson(
    await _api.postJson(
      '/helpdesk/tickets/$id/status',
      body: {'status': status},
    ),
  );

  Future<List<({String id, String name})>> staff() async => asJsonList(
    (await _api.getJson('/helpdesk/staff'))['data'],
  ).map((j) => (id: asString(j['id']), name: asString(j['name']))).toList();

  Future<Json> summary() => _api.getJson('/helpdesk/reports/summary');

  Future<Json> settings() => _api.getJson('/helpdesk/settings');

  Future<Json> saveSettings(Json body) =>
      _api.patchJson('/helpdesk/settings', body: body);

  Future<List<Contract>> contracts(String status) async => asJsonList(
    (await _api.getJson(
      '/service-contracts',
      query: {if (status.isNotEmpty) 'status': status, 'limit': 200},
    ))['data'],
  ).map(Contract.fromJson).toList();

  Future<Contract> contract(String id) async =>
      Contract.fromJson(await _api.getJson('/service-contracts/$id'));

  Future<Contract> createContract(Json body) async =>
      Contract.fromJson(await _api.postJson('/service-contracts', body: body));

  Future<Json> billContract(String id) =>
      _api.postJson('/service-contracts/$id/bill', body: {});

  Future<Contract> renewContract(String id) async => Contract.fromJson(
    await _api.postJson('/service-contracts/$id/renew', body: {}),
  );

  Future<Contract> cancelContract(String id, String reason) async =>
      Contract.fromJson(
        await _api.postJson(
          '/service-contracts/$id/cancel',
          body: {'reason': reason},
        ),
      );

  Future<Json> completeVisit(String visitId, Json body) =>
      _api.postJson('/service-contracts/visits/$visitId/complete', body: body);

  Future<Json> skipVisit(String visitId, String reason) => _api.postJson(
    '/service-contracts/visits/$visitId/skip',
    body: {'reason': reason},
  );

  Future<List<Visit>> visits({String? from, String? to}) async => asJsonList(
    (await _api.getJson(
      '/service-contracts/visits',
      query: {'from': ?from, 'to': ?to},
    ))['data'],
  ).map(Visit.fromJson).toList();
}
