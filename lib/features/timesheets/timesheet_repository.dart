import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'timesheet_models.dart';

final timesheetRevisionProvider = NotifierProvider<TimesheetRevision, int>(
  TimesheetRevision.new,
);

class TimesheetRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final timesheetRepositoryProvider = Provider<TimesheetRepository>(
  (ref) => TimesheetRepository(ref.watch(apiClientProvider)),
);

final weekProvider = FutureProvider.autoDispose.family<Week, String>((
  ref,
  weekStart,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(timesheetRevisionProvider);
  return ref.watch(timesheetRepositoryProvider).week(weekStart);
});

final submittedProvider = FutureProvider.autoDispose<List<TsEntry>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(timesheetRevisionProvider);
  return ref.watch(timesheetRepositoryProvider).entries(status: 'submitted');
});

final unbilledProvider = FutureProvider.autoDispose<List<Json>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(timesheetRevisionProvider);
  return ref.watch(timesheetRepositoryProvider).unbilled();
});

final utilisationProvider = FutureProvider.autoDispose<Json>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(timesheetRevisionProvider);
  return ref.watch(timesheetRepositoryProvider).utilisation();
});

final timesheetSettingsProvider = FutureProvider.autoDispose<Json>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(timesheetRevisionProvider);
  return ref.watch(timesheetRepositoryProvider).settings();
});

final ratesProvider = FutureProvider.autoDispose<List<Json>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(timesheetRevisionProvider);
  return ref.watch(timesheetRepositoryProvider).rates();
});

final timesheetStaffProvider =
    FutureProvider.autoDispose<List<({String id, String name})>>((ref) async {
      ref.watch(activeCompanyIdProvider);
      final r = await ref.watch(apiClientProvider).getJson('/timesheets/staff');
      return asJsonList(
        r['data'],
      ).map((j) => (id: asString(j['id']), name: asString(j['name']))).toList();
    });

class TimesheetRepository {
  TimesheetRepository(this._api);

  final ApiClient _api;

  Future<Week> week(String weekStart) async => Week.fromJson(
    await _api.getJson('/timesheets/week', query: {'weekStart': weekStart}),
  );

  Future<Week> saveWeek(String weekStart, List<WeekRow> rows) async =>
      Week.fromJson(
        await _api.patchJson(
          '/timesheets/week',
          body: {
            'weekStart': weekStart,
            'rows': rows.map((r) => r.toJson()).toList(),
          },
        ),
      );

  Future<Json> submit(String weekStart) =>
      _api.postJson('/timesheets/submit', body: {'weekStart': weekStart});

  Future<List<TsEntry>> entries({String? status}) async => asJsonList(
    (await _api.getJson(
      '/timesheets/entries',
      query: {'status': ?status, 'limit': 500},
    ))['data'],
  ).map(TsEntry.fromJson).toList();

  Future<Json> approve(List<String> ids) =>
      _api.postJson('/timesheets/approve', body: {'ids': ids});

  Future<Json> reject(List<String> ids, String reason) =>
      _api.postJson('/timesheets/reject', body: {'ids': ids, 'reason': reason});

  Future<List<Json>> unbilled() async =>
      asJsonList((await _api.getJson('/timesheets/unbilled'))['data']);

  Future<Json> bill(List<String> partyIds) =>
      _api.postJson('/timesheets/bill', body: {'partyIds': partyIds});

  Future<Json> utilisation() => _api.getJson('/timesheets/reports/utilisation');

  Future<Json> settings() => _api.getJson('/timesheets/settings');

  Future<Json> saveSettings(Json body) =>
      _api.patchJson('/timesheets/settings', body: body);

  Future<List<Json>> rates() async =>
      asJsonList((await _api.getJson('/timesheets/rates'))['data']);

  Future<Json> saveRate(Json body) =>
      _api.postJson('/timesheets/rates', body: body);

  Future<void> deleteRate(String id) async {
    await _api.delete('/timesheets/rates/$id');
  }
}
