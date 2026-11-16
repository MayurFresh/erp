import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'hr_repository.dart';

/// Statutory payroll endpoints (API "Statutory payroll", migration 048).
final statutoryRepositoryProvider = Provider<StatutoryRepository>(
  (ref) => StatutoryRepository(ref.watch(apiClientProvider)),
);

Future<T> _w<T>(Ref ref, Future<T> Function(StatutoryRepository r) f) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(hrRevisionProvider);
  return f(ref.watch(statutoryRepositoryProvider));
}

final statSettingsProvider = FutureProvider.autoDispose<Json>((ref) => _w(ref, (r) => r.settings()));
final statRatesProvider = FutureProvider.autoDispose.family<Json, String>((ref, month) => _w(ref, (r) => r.rates(month)));
final gratuityProvider = FutureProvider.autoDispose.family<Json, String>((ref, month) => _w(ref, (r) => r.gratuity(month)));
final bonusPreviewProvider = FutureProvider.autoDispose.family<Json, int>((ref, fy) => _w(ref, (r) => r.bonusPreview(fy)));
final encTypesProvider = FutureProvider.autoDispose<List<Json>>((ref) => _w(ref, (r) => r.encTypes()));
final encPreviewProvider = FutureProvider.autoDispose.family<Json, int>((ref, fy) => _w(ref, (r) => r.encPreview(fy)));
final fnfListProvider = FutureProvider.autoDispose<List<Json>>((ref) => _w(ref, (r) => r.fnfList()));
final fnfProvider = FutureProvider.autoDispose.family<Json, String>((ref, id) => _w(ref, (r) => r.fnf(id)));
final shiftsProvider = FutureProvider.autoDispose<List<Json>>((ref) => _w(ref, (r) => r.shifts()));
final shiftLogProvider = FutureProvider.autoDispose.family<Json, String>((ref, month) => _w(ref, (r) => r.shiftLog(month)));

class StatutoryRepository {
  StatutoryRepository(this._api);

  final ApiClient _api;

  Future<Json> settings() => _api.getJson('/payroll/statutory/settings');
  Future<void> saveSettings(Json body) => _api.patchJson('/payroll/statutory/settings', body: body);

  Future<Json> rates(String month) => _api.getJson('/payroll/statutory/rates', query: {'month': month});
  Future<void> addRate(Json body) => _api.postJson('/payroll/statutory/rates', body: body);
  Future<void> deleteRate(String id) => _api.delete('/payroll/statutory/rates/$id');

  Future<void> setFixedTerm(String employeeId, bool fixedTerm) =>
      _api.patchJson('/payroll/employees/$employeeId/statutory', body: {'fixedTerm': fixedTerm});
  Future<Json> gratuity(String month) => _api.getJson('/payroll/gratuity/report', query: {'month': month});

  Future<Json> bonusPreview(int fy) => _api.getJson('/payroll/bonus/preview', query: {'fy': fy});
  Future<Json> bonusRun(int fy, String runId) => _api.postJson('/payroll/bonus/run', body: {'fy': fy, 'runId': runId});

  Future<List<Json>> encTypes() async => asJsonList((await _api.getJson('/payroll/leave-encashment/types'))['data']);
  Future<void> saveEncType(String id, bool encashable, num maxDays) =>
      _api.patchJson('/payroll/leave-encashment/types/$id', body: {'encashable': encashable, 'maxDays': maxDays});
  Future<Json> encPreview(int fy) => _api.getJson('/payroll/leave-encashment/preview', query: {'fy': fy});
  Future<Json> encRun(int fy, String runId) => _api.postJson('/payroll/leave-encashment/run', body: {'fy': fy, 'runId': runId});

  Future<List<Json>> fnfList() async => asJsonList((await _api.getJson('/payroll/fnf'))['data']);
  Future<Json> fnf(String id) => _api.getJson('/payroll/fnf/$id');
  Future<Json> fnfCreate(Json body) => _api.postJson('/payroll/fnf', body: body);
  Future<Json> fnfUpdate(String id, Json body) => _api.patchJson('/payroll/fnf/$id', body: body);
  Future<Json> fnfAction(String id, String action, {Json? body}) => _api.postJson('/payroll/fnf/$id/$action', body: body ?? {});

  Future<List<Json>> shifts() async => asJsonList((await _api.getJson('/payroll/shifts'))['data']);
  Future<void> addShift(Json body) => _api.postJson('/payroll/shifts', body: body);
  Future<Json> shiftLog(String month) => _api.getJson('/payroll/shift-log', query: {'month': month});
  Future<void> saveShiftLog(Json body) => _api.patchJson('/payroll/shift-log', body: body);
}
