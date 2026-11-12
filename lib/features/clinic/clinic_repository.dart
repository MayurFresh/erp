import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'clinic_models.dart';
import 'ipd_models.dart';

/// Clinic data whose lists reload after a write.
enum ClinicKind { patients, doctors, appointments, visits, ipd }

final clinicRevisionProvider =
    NotifierProvider.family<ClinicRevisionNotifier, int, ClinicKind>(
      ClinicRevisionNotifier.new,
    );

class ClinicRevisionNotifier extends Notifier<int> {
  ClinicRevisionNotifier(this.kind);

  final ClinicKind kind;

  @override
  int build() => 0;

  void bump() => state++;
}

extension ClinicWatch on Ref {
  void watchClinic(Iterable<ClinicKind> kinds) {
    for (final k in kinds) {
      watch(clinicRevisionProvider(k));
    }
  }
}

extension ClinicBump on WidgetRef {
  void bumpClinic(Iterable<ClinicKind> kinds, {bool money = false}) {
    for (final k in kinds) {
      read(clinicRevisionProvider(k).notifier).bump();
    }
    if (money) {
      bump(const [DataKind.invoices, DataKind.payments, DataKind.parties]);
    }
  }
}

final clinicRepositoryProvider = Provider<ClinicRepository>(
  (ref) => ClinicRepository(ref.watch(apiClientProvider)),
);

final clinicDoctorsProvider = FutureProvider.autoDispose<List<Doctor>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watchClinic(const [ClinicKind.doctors]);
  return ref.watch(clinicRepositoryProvider).doctors();
});

/// `date|doctorId` → that day's appointments (the queue).
final clinicQueueProvider = FutureProvider.autoDispose
    .family<List<Appointment>, ({String date, String? doctorId})>((ref, key) {
      ref.watch(activeCompanyIdProvider);
      ref.watchClinic(const [ClinicKind.appointments, ClinicKind.visits]);
      return ref
          .watch(clinicRepositoryProvider)
          .appointments(date: key.date, doctorId: key.doctorId);
    });

final clinicPatientProvider = FutureProvider.autoDispose
    .family<PatientHistory, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watchClinic(const [
        ClinicKind.patients,
        ClinicKind.visits,
        ClinicKind.appointments,
      ]);
      ref.watchRevisions(const [DataKind.invoices, DataKind.payments]);
      return ref.watch(clinicRepositoryProvider).history(id);
    });

final clinicVisitProvider = FutureProvider.autoDispose.family<Visit, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchClinic(const [ClinicKind.visits]);
  return ref.watch(clinicRepositoryProvider).visit(id);
});

class ClinicRepository {
  ClinicRepository(this._api);

  final ApiClient _api;

  Future<Paged<PatientBrief>> patients({
    String? q,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/clinic/patients',
    PatientBrief.fromJson,
    query: {'q': q, 'offset': offset, 'limit': limit},
  );

  /// Throws an `ApiException` with code `DUPLICATE_PATIENT` unless [force].
  Future<Patient> createPatient(Json body) async =>
      Patient.fromJson(await _api.postJson('/clinic/patients', body: body));

  Future<Patient> updatePatient(String id, Json body) async => Patient.fromJson(
    await _api.patchJson('/clinic/patients/$id', body: body),
  );

  Future<PatientHistory> history(String id) async => PatientHistory.fromJson(
    await _api.getJson('/clinic/patients/$id/history'),
  );

  Future<List<Doctor>> doctors() async =>
      (await _api.getPage('/clinic/doctors', Doctor.fromJson)).data;

  Future<Doctor> saveDoctor(String? id, Json body) async => Doctor.fromJson(
    id == null
        ? await _api.postJson('/clinic/doctors', body: body)
        : await _api.patchJson('/clinic/doctors/$id', body: body),
  );

  Future<List<Slot>> slots(String doctorId, String date) async {
    final j = await _api.getJson(
      '/clinic/doctors/$doctorId/slots',
      query: {'date': date},
    );
    return asJsonList(
      j['data'],
    ).map((s) => Slot(asString(s['startTime']), asBool(s['free']))).toList();
  }

  Future<List<Appointment>> appointments({
    required String date,
    String? doctorId,
  }) async => (await _api.getPage(
    '/clinic/appointments',
    Appointment.fromJson,
    query: {'date': date, 'doctorId': doctorId},
  )).data;

  Future<Appointment> book(Json body) async => Appointment.fromJson(
    await _api.postJson('/clinic/appointments', body: body),
  );

  Future<Appointment> setStatus(
    String id,
    String status, {
    String? reason,
  }) async => Appointment.fromJson(
    await _api.postJson(
      '/clinic/appointments/$id/status',
      body: {'status': status, 'reason': reason},
    ),
  );

  Future<Appointment> reschedule(String id, Json body) async =>
      Appointment.fromJson(
        await _api.postJson('/clinic/appointments/$id/reschedule', body: body),
      );

  Future<Visit> startVisit({
    String? appointmentId,
    String? patientId,
    String? doctorId,
  }) async => Visit.fromJson(
    await _api.postJson(
      '/clinic/visits',
      body: appointmentId != null
          ? {'appointmentId': appointmentId}
          : {'patientId': patientId, 'doctorId': doctorId},
    ),
  );

  Future<Visit> visit(String id) async =>
      Visit.fromJson(await _api.getJson('/clinic/visits/$id'));

  Future<Visit> saveVisit(String id, Json body) async =>
      Visit.fromJson(await _api.patchJson('/clinic/visits/$id', body: body));

  Future<Visit> complete(String id) async => Visit.fromJson(
    await _api.postJson('/clinic/visits/$id/complete', body: const {}),
  );

  Future<PrescriptionData> prescription(String id) async =>
      PrescriptionData.fromJson(
        await _api.getJson('/clinic/visits/$id/prescription'),
      );

  Future<BillResult> bill(String id, Json body) async => BillResult.fromJson(
    await _api.postJson('/clinic/visits/$id/bill', body: body),
  );

  // In-patient care ---------------------------------------------------------

  Future<IpdBoard> ipdBoard() async =>
      IpdBoard.fromJson(await _api.getJson('/clinic/ipd/board'));

  Future<List<AdmissionBrief>> admissions({String? status, String? q}) async =>
      (await _api.getPage(
        '/clinic/ipd/admissions',
        AdmissionBrief.fromJson,
        query: {'status': status, 'q': q, 'limit': 100},
      )).data;

  Future<Admission> admission(String id) async =>
      Admission.fromJson(await _api.getJson('/clinic/ipd/admissions/$id'));

  Future<Admission> admit(Json body) async => Admission.fromJson(
    await _api.postJson('/clinic/ipd/admissions', body: body),
  );

  Future<Admission> _post(String id, String path, Json body) async =>
      Admission.fromJson(
        await _api.postJson('/clinic/ipd/admissions/$id/$path', body: body),
      );

  Future<Admission> transfer(String id, String bedId, String? reason) =>
      _post(id, 'transfer', {'bedId': bedId, 'reason': reason});

  Future<Admission> deposit(String id, Json body) =>
      _post(id, 'deposits', body);

  Future<Admission> refund(String id, Json body) => _post(id, 'refund', body);

  Future<Admission> addCharge(String id, Json body) =>
      _post(id, 'charges', body);

  Future<Admission> voidCharge(String id, String chargeId, String reason) =>
      _post(id, 'charges/$chargeId/void', {'reason': reason});

  Future<void> postBedCharges(String id) async =>
      _api.postJson('/clinic/ipd/admissions/$id/bed-charges', body: const {});

  Future<int> runBedCharges() async => asInt(
    (await _api.postJson(
      '/clinic/ipd/bed-charges/run',
      body: const {},
    ))['added'],
  );

  Future<Admission> saveSummary(String id, Json body) async =>
      Admission.fromJson(
        await _api.patchJson('/clinic/ipd/admissions/$id/summary', body: body),
      );

  Future<DischargeResult> discharge(String id, Json body) async =>
      DischargeResult.fromJson(
        await _api.postJson('/clinic/ipd/admissions/$id/discharge', body: body),
      );

  Future<DischargeSummaryData> dischargeSummary(String id) async =>
      DischargeSummaryData.fromJson(
        await _api.getJson('/clinic/ipd/admissions/$id/discharge-summary'),
      );

  Future<List<IpdWard>> wards() async => asJsonList(
    (await _api.getJson('/clinic/ipd/wards'))['data'],
  ).map(IpdWard.fromJson).toList();

  Future<void> saveWard(String? id, Json body) async => id == null
      ? _api.postJson('/clinic/ipd/wards', body: body)
      : _api.patchJson('/clinic/ipd/wards/$id', body: body);

  Future<void> saveBed(String? id, Json body) async => id == null
      ? _api.postJson('/clinic/ipd/beds', body: body)
      : _api.patchJson('/clinic/ipd/beds/$id', body: body);
}

final ipdBoardProvider = FutureProvider.autoDispose<IpdBoard>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watchClinic(const [ClinicKind.ipd]);
  return ref.watch(clinicRepositoryProvider).ipdBoard();
});

final ipdAdmissionProvider = FutureProvider.autoDispose
    .family<Admission, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watchClinic(const [ClinicKind.ipd]);
      ref.watchRevisions(const [DataKind.invoices, DataKind.payments]);
      return ref.watch(clinicRepositoryProvider).admission(id);
    });

final ipdDischargedProvider = FutureProvider.autoDispose<List<AdmissionBrief>>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchClinic(const [ClinicKind.ipd]);
  return ref.watch(clinicRepositoryProvider).admissions(status: 'discharged');
});

final ipdWardsProvider = FutureProvider.autoDispose<List<IpdWard>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watchClinic(const [ClinicKind.ipd]);
  return ref.watch(clinicRepositoryProvider).wards();
});
