import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/api_exception.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'education_models.dart';

/// Education data whose lists reload after a write.
enum EduKind { students, setup, fees, attendance }

final eduRevisionProvider = NotifierProvider.family<EduRevision, int, EduKind>(
  EduRevision.new,
);

class EduRevision extends Notifier<int> {
  EduRevision(this.kind);

  final EduKind kind;

  @override
  int build() => 0;

  void bump() => state++;
}

extension EduWatch on Ref {
  void watchEdu(Iterable<EduKind> kinds) {
    for (final k in kinds) {
      watch(eduRevisionProvider(k));
    }
  }
}

extension EduBump on WidgetRef {
  void bumpEdu(Iterable<EduKind> kinds, {bool money = false}) {
    for (final k in kinds) {
      read(eduRevisionProvider(k).notifier).bump();
    }
    if (money) {
      bump(const [DataKind.invoices, DataKind.payments, DataKind.parties]);
    }
  }
}

final eduRepositoryProvider = Provider<EduRepository>(
  (ref) => EduRepository(ref.watch(apiClientProvider)),
);

final eduHomeProvider = FutureProvider.autoDispose<EduHome>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watchEdu(EduKind.values);
  ref.watchRevisions(const [DataKind.invoices, DataKind.payments]);
  return ref.watch(eduRepositoryProvider).home();
});

final eduYearsProvider = FutureProvider.autoDispose<List<EduYear>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watchEdu(const [EduKind.setup]);
  return ref.watch(eduRepositoryProvider).years();
});

final eduClassesProvider = FutureProvider.autoDispose<List<EduClass>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watchEdu(const [EduKind.setup, EduKind.students]);
  return ref.watch(eduRepositoryProvider).classes();
});

final eduStaffProvider =
    FutureProvider.autoDispose<List<({String id, String name})>>((ref) async {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(eduRepositoryProvider).staff();
    });

final eduHeadsProvider = FutureProvider.autoDispose<List<FeeHead>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watchEdu(const [EduKind.setup]);
  return ref.watch(eduRepositoryProvider).heads();
});

final eduPlanProvider = FutureProvider.autoDispose.family<FeePlan?, String>((
  ref,
  classId,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchEdu(const [EduKind.setup]);
  return ref.watch(eduRepositoryProvider).plan(classId);
});

final eduStudentProvider = FutureProvider.autoDispose.family<Student, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchEdu(const [EduKind.students, EduKind.fees]);
  ref.watchRevisions(const [DataKind.invoices, DataKind.payments]);
  return ref.watch(eduRepositoryProvider).student(id);
});

final eduLedgerProvider = FutureProvider.autoDispose.family<Ledger, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchEdu(const [EduKind.fees]);
  ref.watchRevisions(const [DataKind.invoices, DataKind.payments]);
  return ref.watch(eduRepositoryProvider).ledger(id);
});

final eduStudentAttendanceProvider = FutureProvider.autoDispose
    .family<StudentAttendance, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watchEdu(const [EduKind.attendance]);
      return ref.watch(eduRepositoryProvider).studentAttendance(id);
    });

final eduSheetProvider = FutureProvider.autoDispose
    .family<AttendanceSheet, ({String classId, String month})>((ref, key) {
      ref.watch(activeCompanyIdProvider);
      ref.watchEdu(const [EduKind.attendance]);
      return ref.watch(eduRepositoryProvider).sheet(key.classId, key.month);
    });

class EduRepository {
  EduRepository(this._api);

  final ApiClient _api;

  Future<EduHome> home() async =>
      EduHome.fromJson(await _api.getJson('/education/home'));

  Future<List<({String id, String name})>> staff() async => [
    for (final j in asJsonList(
      (await _api.getJson('/education/staff'))['data'],
    ))
      (id: asString(j['id']), name: asString(j['name'])),
  ];

  Future<List<EduYear>> years() async =>
      (await _api.getPage('/education/years', EduYear.fromJson)).data;

  Future<EduYear> saveYear(String? id, Json body) async => EduYear.fromJson(
    id == null
        ? await _api.postJson('/education/years', body: body)
        : await _api.patchJson('/education/years/$id', body: body),
  );

  Future<List<EduClass>> classes() async =>
      (await _api.getPage('/education/classes', EduClass.fromJson)).data;

  Future<EduClass> saveClass(String? id, Json body) async => EduClass.fromJson(
    id == null
        ? await _api.postJson('/education/classes', body: body)
        : await _api.patchJson('/education/classes/$id', body: body),
  );

  Future<List<FeeHead>> heads() async =>
      (await _api.getPage('/education/fee-heads', FeeHead.fromJson)).data;

  Future<FeeHead> saveHead(String? id, Json body) async => FeeHead.fromJson(
    id == null
        ? await _api.postJson('/education/fee-heads', body: body)
        : await _api.patchJson('/education/fee-heads/$id', body: body),
  );

  /// `null` when the class has no plan yet.
  Future<FeePlan?> plan(String classId) async {
    try {
      return FeePlan.fromJson(
        await _api.getJson('/education/classes/$classId/fee-plan'),
      );
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// The server accepts POST as well as PUT for this write.
  Future<FeePlan> savePlan(String classId, Json body) async => FeePlan.fromJson(
    await _api.postJson('/education/classes/$classId/fee-plan', body: body),
  );

  Future<Paged<StudentBrief>> students({
    String? q,
    String? classId,
    String? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/education/students',
    StudentBrief.fromJson,
    query: {
      'q': q,
      'classId': classId,
      'status': status,
      'offset': offset,
      'limit': limit,
    },
  );

  /// Throws an `ApiException` with code `DUPLICATE_STUDENT` unless forced.
  Future<Student> admit(Json body) async =>
      Student.fromJson(await _api.postJson('/education/students', body: body));

  Future<Student> updateStudent(String id, Json body) async => Student.fromJson(
    await _api.patchJson('/education/students/$id', body: body),
  );

  Future<Student> student(String id) async =>
      Student.fromJson(await _api.getJson('/education/students/$id'));

  Future<void> addConcession(String studentId, Json body) =>
      _api.postJson('/education/students/$studentId/concessions', body: body);

  Future<void> removeConcession(String id) =>
      _api.delete('/education/concessions/$id');

  Future<int> promote(Json body) async =>
      asInt((await _api.postJson('/education/promote', body: body))['moved']);

  Future<DemandResult> generate(Json body) async => DemandResult.fromJson(
    await _api.postJson('/education/demands/generate', body: body),
  );

  Future<DuesPage> dues({
    String? q,
    String? classId,
    bool overdueOnly = false,
    int limit = 200,
  }) async => DuesPage.fromJson(
    await _api.getJson(
      '/education/dues',
      query: {
        'q': q,
        'classId': classId,
        'overdue': overdueOnly ? 'true' : null,
        'limit': limit,
      },
    ),
  );

  Future<Ledger> ledger(String studentId) async => Ledger.fromJson(
    await _api.getJson('/education/students/$studentId/ledger'),
  );

  Future<CollectResult> collect(String studentId, Json body) async =>
      CollectResult.fromJson(
        await _api.postJson(
          '/education/students/$studentId/collect',
          body: body,
        ),
      );

  Future<ReceiptData> receipt(String paymentId) async => ReceiptData.fromJson(
    await _api.getJson('/education/receipts/$paymentId'),
  );

  Future<Roster> roster(String classId, {String? date}) async =>
      Roster.fromJson(
        await _api.getJson(
          '/education/classes/$classId/attendance',
          query: {'date': date},
        ),
      );

  Future<Roster> saveAttendance(
    String classId,
    String date,
    List<RosterEntry> marks,
  ) async => Roster.fromJson(
    await _api.postJson(
      '/education/classes/$classId/attendance',
      body: {
        'date': date,
        'marks': [
          for (final m in marks) {'studentId': m.studentId, 'status': m.status},
        ],
      },
    ),
  );

  Future<AttendanceSheet> sheet(String classId, String month) async =>
      AttendanceSheet.fromJson(
        await _api.getJson(
          '/education/classes/$classId/attendance/sheet',
          query: {'month': month},
        ),
      );

  Future<StudentAttendance> studentAttendance(String id) async =>
      StudentAttendance.fromJson(
        await _api.getJson('/education/students/$id/attendance'),
      );
}
