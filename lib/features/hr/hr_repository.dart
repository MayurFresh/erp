import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'hr_models.dart';

/// Bumped after any HR or payroll write so open screens reload.
final hrRevisionProvider = NotifierProvider<HrRevision, int>(HrRevision.new);

class HrRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

extension HrBump on WidgetRef {
  void bumpHr() => read(hrRevisionProvider.notifier).bump();
}

final hrRepositoryProvider = Provider<HrRepository>(
  (ref) => HrRepository(ref.watch(apiClientProvider)),
);

Future<T> _watched<T>(Ref ref, Future<T> Function(HrRepository r) f) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(hrRevisionProvider);
  return f(ref.watch(hrRepositoryProvider));
}

final hrSummaryProvider = FutureProvider.autoDispose<HrSummary>(
  (ref) => _watched(ref, (r) => r.summary()),
);

final employeesProvider = FutureProvider.autoDispose
    .family<List<Employee>, ({String q, String? status})>(
      (ref, k) => _watched(ref, (r) => r.employees(q: k.q, status: k.status)),
    );

final employeeProvider = FutureProvider.autoDispose.family<Employee, String>(
  (ref, id) => _watched(ref, (r) => r.employee(id)),
);

final salaryHistoryProvider = FutureProvider.autoDispose
    .family<List<SalaryRevision>, String>(
      (ref, id) => _watched(ref, (r) => r.salaryHistory(id)),
    );

final componentsProvider = FutureProvider.autoDispose<List<SalaryComponent>>(
  (ref) => _watched(ref, (r) => r.components()),
);

final leaveTypesProvider = FutureProvider.autoDispose<List<LeaveType>>(
  (ref) => _watched(ref, (r) => r.leaveTypes()),
);

final holidaysProvider = FutureProvider.autoDispose<List<Holiday>>(
  (ref) => _watched(ref, (r) => r.holidays()),
);

final leaveListProvider = FutureProvider.autoDispose
    .family<List<LeaveApplication>, ({String? status, bool mine})>(
      (ref, k) =>
          _watched(ref, (r) => r.leaveApplications(status: k.status, mine: k.mine)),
    );

final leaveBalancesProvider = FutureProvider.autoDispose
    .family<List<LeaveBalance>, String>(
      (ref, id) => _watched(ref, (r) => r.leaveBalances(id)),
    );

final runsProvider = FutureProvider.autoDispose<List<PayrollRun>>(
  (ref) => _watched(ref, (r) => r.runs()),
);

final runProvider = FutureProvider.autoDispose.family<PayrollRun, String>(
  (ref, id) => _watched(ref, (r) => r.run(id)),
);

final statutoryProvider = FutureProvider.autoDispose.family<Json, String>(
  (ref, id) => _watched(ref, (r) => r.statutory(id)),
);

final payslipsProvider = FutureProvider.autoDispose
    .family<List<PayslipItem>, ({String? employeeId, bool mine})>(
      (ref, k) =>
          _watched(ref, (r) => r.payslips(employeeId: k.employeeId, mine: k.mine)),
    );

final payslipProvider = FutureProvider.autoDispose.family<Payslip, String>(
  (ref, id) => _watched(ref, (r) => r.payslip(id)),
);

final myEmployeeProvider = FutureProvider.autoDispose<Employee?>(
  (ref) => _watched(ref, (r) => r.me()),
);

class HrRepository {
  HrRepository(this._api);

  final ApiClient _api;

  List<Json> _data(Json j) => asJsonList(j['data']);

  Future<HrSummary> summary() async =>
      HrSummary.fromJson(await _api.getJson('/hr/summary'));

  Future<List<Employee>> employees({String q = '', String? status}) async =>
      _data(await _api.getJson('/employees', query: {
        if (q.isNotEmpty) 'q': q,
        'status': ?status,
        'limit': 200,
      })).map(Employee.fromJson).toList();

  Future<Employee> employee(String id) async =>
      Employee.fromJson(await _api.getJson('/employees/$id'));

  Future<Employee> saveEmployee(String? id, Json body) async => Employee.fromJson(
    id == null
        ? await _api.postJson('/employees', body: body)
        : await _api.patchJson('/employees/$id', body: body),
  );

  Future<Json> settings() => _api.getJson('/payroll/settings');

  /// The API takes PUT; `ApiClient` has no PUT, so the PATCH twin is used.
  Future<void> saveSettings(Json body) => _api.patchJson('/payroll/settings', body: body);

  Future<Employee?> me() async {
    final j = await _api.getJson('/payroll/me');
    final e = asJsonOrNull(j['employee']);
    return e == null ? null : Employee.fromJson(e);
  }

  Future<List<SalaryRevision>> salaryHistory(String id) async =>
      _data(await _api.getJson('/employees/$id/salary')).map(SalaryRevision.fromJson).toList();

  Future<void> addSalary(String id, Json body) =>
      _api.postJson('/employees/$id/salary', body: body);

  Future<List<SalaryComponent>> components() async =>
      _data(await _api.getJson('/payroll/components')).map(SalaryComponent.fromJson).toList();

  Future<void> saveComponent(String? id, Json body) => id == null
      ? _api.postJson('/payroll/components', body: body)
      : _api.patchJson('/payroll/components/$id', body: body);

  Future<List<LeaveType>> leaveTypes() async =>
      _data(await _api.getJson('/leave-types')).map(LeaveType.fromJson).toList();

  Future<void> saveLeaveType(String? id, Json body) => id == null
      ? _api.postJson('/leave-types', body: body)
      : _api.patchJson('/leave-types/$id', body: body);

  Future<List<Holiday>> holidays() async =>
      _data(await _api.getJson('/holidays')).map(Holiday.fromJson).toList();

  Future<void> addHoliday(Json body) => _api.postJson('/holidays', body: body);

  Future<void> deleteHoliday(String id) => _api.delete('/holidays/$id');

  Future<List<LeaveApplication>> leaveApplications({String? status, bool mine = false}) async =>
      _data(await _api.getJson('/leave-applications', query: {
        'status': ?status,
        if (mine) 'mine': 'true',
        'limit': 200,
      })).map(LeaveApplication.fromJson).toList();

  Future<void> applyLeave(Json body) => _api.postJson('/leave-applications', body: body);

  Future<void> decideLeave(String id, String action, {String? note}) =>
      _api.postJson('/leave-applications/$id/$action', body: {'note': ?note});

  Future<List<LeaveBalance>> leaveBalances(String employeeId) async =>
      _data(await _api.getJson('/employees/$employeeId/leave-balances')).map(LeaveBalance.fromJson).toList();

  Future<void> adjustLeave(String employeeId, Json body) =>
      _api.postJson('/employees/$employeeId/leave-adjustments', body: body);

  Future<List<PayrollRun>> runs() async =>
      _data(await _api.getJson('/payroll/runs', query: {'limit': 100})).map(PayrollRun.fromJson).toList();

  Future<PayrollRun> run(String id) async =>
      PayrollRun.fromJson(await _api.getJson('/payroll/runs/$id'));

  Future<PayrollRun> createRun(String month) async =>
      PayrollRun.fromJson(await _api.postJson('/payroll/runs', body: {'month': month}));

  Future<PayrollRun> runAction(String id, String action, {Json? body}) async =>
      PayrollRun.fromJson(await _api.postJson('/payroll/runs/$id/$action', body: body ?? {}));

  Future<PayrollRun> addAdjustment(String id, Json body) async =>
      PayrollRun.fromJson(await _api.postJson('/payroll/runs/$id/adjustments', body: body));

  Future<PayrollRun> addOverride(String id, Json body) async =>
      PayrollRun.fromJson(await _api.postJson('/payroll/runs/$id/overrides', body: body));

  Future<Json> statutory(String id) => _api.getJson('/payroll/runs/$id/statutory');

  Future<List<AttendanceDay>> attendanceDays(String month) async =>
      _data(await _api.getJson('/attendance-days', query: {'month': month})).map(AttendanceDay.fromJson).toList();

  Future<void> saveAttendanceDays(String month, List<Json> rows) async {
    await _api.patchJson('/attendance-days', body: {'month': month, 'rows': rows});
  }

  Future<String> file(String id, String kind) => _api.getText('/payroll/runs/$id/files/$kind');

  Future<List<PayslipItem>> payslips({String? employeeId, bool mine = false}) async =>
      _data(await _api.getJson('/payroll/payslips', query: {
        'employeeId': ?employeeId,
        if (mine) 'mine': 'true',
        'limit': 100,
      })).map(PayslipItem.fromJson).toList();

  Future<Payslip> payslip(String id) async =>
      Payslip(await _api.getJson('/payroll/payslips/$id'));
}
