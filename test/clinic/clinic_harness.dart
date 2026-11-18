import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:onematrix/core/api_client.dart';
import 'package:onematrix/core/money.dart';
import 'package:onematrix/core/providers.dart';
import 'package:onematrix/core/theme.dart';
import 'package:onematrix/core/token_store.dart';
import 'package:onematrix/features/clinic/clinic_routes.dart';

import '../support/fake_backend.dart';

const clinicTestSizes = [Size(320, 700), Size(390, 844), Size(1440, 900)];

final _today = apiDate(DateTime.now());

const doctorJson = {
  'id': 'd1',
  'name': 'Dr Anil Mehta',
  'userId': null,
  'speciality': 'General medicine',
  'registrationNo': 'G-12345',
  'consultFee': 500,
  'followUpFee': 250,
  'followUpDays': 7,
  'slotMinutes': 15,
  'workingHours': [
    {'day': 0, 'from': '09:00', 'to': '13:00'},
    {'day': 1, 'from': '09:00', 'to': '13:00'},
    {'day': 2, 'from': '09:00', 'to': '13:00'},
    {'day': 3, 'from': '09:00', 'to': '13:00'},
    {'day': 4, 'from': '09:00', 'to': '13:00'},
    {'day': 5, 'from': '09:00', 'to': '13:00'},
    {'day': 6, 'from': '09:00', 'to': '13:00'},
  ],
  'isActive': true,
  'updatedAt': '2026-11-01T10:00:00.000Z',
};

const patientBrief = {
  'id': 'pt1',
  'uhid': 'UHID/26-27/00001',
  'name': 'Ravi Shah',
  'sex': 'male',
  'ageYears': 41,
  'phone': '9825012345',
};

Map<String, Object?> apptJson(
  String id,
  String name,
  String status, {
  int? token,
  String? start,
  String? visitId,
}) => {
  'id': id,
  'date': _today,
  'startTime': start,
  'endTime': null,
  'tokenNo': token,
  'kind': start == null ? 'walk_in' : 'booked',
  'status': status,
  'reason': 'Fever',
  'patient': {...patientBrief, 'id': 'pt-$id', 'name': name},
  'doctor': {'id': 'd1', 'name': 'Dr Anil Mehta'},
  'visitId': visitId,
  'billed': false,
};

final visitJson = <String, Object?>{
  'id': 'v1',
  'appointmentId': 'a1',
  'date': _today,
  'status': 'open',
  'feeKind': null,
  'patient': patientBrief,
  'doctor': {'id': 'd1', 'name': 'Dr Anil Mehta'},
  'invoice': null,
  'updatedAt': '2026-11-12T09:00:00.000Z',
  'closedAt': null,
  'clinical': true,
  'allergies': 'Penicillin',
  'vitals': {'pulse': 78},
  'complaints': 'Fever for two days',
  'findings': null,
  'diagnosis': null,
  'testsAdvised': null,
  'advice': null,
  'followupDate': null,
  'rx': [
    {
      'medicine': 'Paracetamol 500 mg',
      'dose': '1 tablet',
      'frequency': 'Three times a day',
      'days': 3,
    },
  ],
};

Map<String, Object?> prescriptionJson() => {
  'clinic': {
    'name': 'Care Clinic',
    'address': '12 Ashram Road, Ahmedabad',
    'phone': '079 5550 1234',
  },
  'doctor': {
    'name': 'Dr Anil Mehta',
    'speciality': 'General medicine',
    'registrationNo': 'G-12345',
  },
  'patient': {...patientBrief, 'allergies': 'Penicillin', 'bloodGroup': 'B+'},
  'visit': {
    'id': 'v1',
    'date': _today,
    'vitals': {
      'bpSys': 130,
      'bpDia': 85,
      'pulse': 78,
      'tempC': 37.3,
      'spo2': 98,
    },
    'complaints': 'Fever for two days',
    'findings': null,
    'diagnosis': 'Viral fever',
    'testsAdvised': 'CBC if fever persists',
    'advice': 'Rest and fluids',
    'followupDate': null,
  },
  'rx': [
    {
      'medicine': 'Paracetamol 500 mg',
      'dose': '1 tablet',
      'frequency': 'Three times a day',
      'days': 3,
      'instructions': 'After food',
    },
    {
      'medicine': 'ORS sachets',
      'dose': null,
      'frequency': 'As needed',
      'days': 3,
      'instructions': null,
    },
  ],
};

const ipdBoardJson = {
  'counts': {
    'total': 3,
    'available': 1,
    'occupied': 1,
    'cleaning': 1,
    'maintenance': 0,
  },
  'admitted': 1,
  'wards': [
    {
      'id': 'w1',
      'name': 'General ward',
      'kind': 'general',
      'beds': [
        {
          'id': 'b1',
          'bedNo': 'G1',
          'dailyRate': 1200,
          'status': 'occupied',
          'admission': {
            'id': 'ad1',
            'number': 'IPD/26-27/00001',
            'patientName': 'Meena Patel',
            'uhid': 'UHID/26-27/00002',
            'doctorName': 'Dr Anil Mehta',
            'admitDate': '2026-11-10',
            'days': 3,
          },
        },
        {'id': 'b2', 'bedNo': 'G2', 'dailyRate': 1200, 'status': 'available'},
        {'id': 'b3', 'bedNo': 'G3', 'dailyRate': 1200, 'status': 'cleaning'},
      ],
    },
  ],
};

Map<String, Object?> admissionJson({String status = 'admitted'}) => {
  'id': 'ad1',
  'number': 'IPD/26-27/00001',
  'status': status,
  'admitDate': '2026-11-10',
  'dischargeDate': status == 'admitted' ? null : '2026-11-13',
  'days': 3,
  'expectedDays': 4,
  'patient': {
    'id': 'pt2',
    'uhid': 'UHID/26-27/00002',
    'name': 'Meena Patel',
    'phone': '9825099999',
  },
  'doctor': {'id': 'd1', 'name': 'Dr Anil Mehta'},
  'bed': {
    'id': 'b1',
    'bedNo': 'G1',
    'wardId': 'w1',
    'wardName': 'General ward',
  },
  'invoiceId': null,
  'updatedAt': '2026-11-12T09:00:00.000Z',
  'clinical': true,
  'provisionalDiagnosis': 'Gastroenteritis',
  'summary': {
    'diagnosis': 'Gastroenteritis',
    'treatment': 'IV fluids',
    'advice': 'Rest',
    'condition': 'Stable',
    'followupDate': null,
  },
  'charges': [
    {
      'id': 'c1',
      'date': '2026-11-10',
      'kind': 'bed',
      'description': 'Bed G1, General ward',
      'qty': 1,
      'rate': 1200,
      'amount': 1200,
      'isVoid': false,
    },
    {
      'id': 'c2',
      'date': '2026-11-11',
      'kind': 'service',
      'description': 'Doctor visit',
      'qty': 1,
      'rate': 600,
      'amount': 600,
      'isVoid': false,
    },
  ],
  'deposits': [
    {
      'id': 'dp1',
      'paymentId': 'pay1',
      'number': 'RCT/26-27/00005',
      'mode': 'cash',
      'date': '2026-11-10',
      'amount': 1000,
      'cancelled': false,
    },
  ],
  'totals': {
    'bed': 1200,
    'service': 600,
    'medicine': 0,
    'total': 1800,
    'deposits': 1000,
    'balance': 800,
  },
  'invoice': null,
  'refundDue': status == 'admitted' ? 0 : 500,
};

Map<String, Object?> dischargeSummaryJson() => {
  'hospital': {'name': 'City Hospital', 'address': '12 Ashram Road'},
  'doctor': {
    'name': 'Dr Anil Mehta',
    'speciality': 'General medicine',
    'registrationNo': 'G-12345',
  },
  'patient': {
    'uhid': 'UHID/26-27/00002',
    'name': 'Meena Patel',
    'sex': 'female',
    'ageYears': 34,
    'bloodGroup': 'O+',
    'allergies': null,
  },
  'admission': {
    'number': 'IPD/26-27/00001',
    'status': 'discharged',
    'admitDate': '2026-11-10',
    'dischargeDate': '2026-11-13',
    'days': 3,
    'ward': 'General ward',
    'bed': 'G1',
  },
  'provisionalDiagnosis': 'Gastroenteritis',
  'summary': {
    'diagnosis': 'Acute gastroenteritis',
    'treatment': 'IV fluids and antibiotics',
    'advice': 'Rest, ORS',
    'condition': 'Stable',
    'followupDate': '2026-11-20',
  },
  'medicines': [
    {'name': 'Inj Ondansetron 4 mg', 'qty': 3},
  ],
};

/// The clinic endpoints; everything else goes to the shared backend.
class ClinicFakeBackend implements HttpClientAdapter {
  ClinicFakeBackend(Set<String> permissions, {this.visit})
    : _core = FakeBackend(permissions: permissions);

  final FakeBackend _core;
  final Map<String, Object?>? visit;
  bool dischargedStay = false;
  final List<RequestOptions> calls = [];

  Map<String, Object?> _page(List<Object?> d) => {'data': d, 'total': d.length};

  Map<String, Object?> body(String method, String path) {
    final o = calls.lastWhere((r) => r.method == method && r.path == path);
    final data = o.data;
    return data is Map
        ? Map<String, Object?>.from(data)
        : jsonDecode(data as String) as Map<String, Object?>;
  }

  int count(String method, String path) =>
      calls.where((r) => r.method == method && r.path == path).length;

  (int, Object?)? _route(RequestOptions o) {
    final key = '${o.method} ${o.path}';
    final v = visit ?? visitJson;
    return switch (key) {
      'GET /clinic/doctors' => (200, _page([doctorJson])),
      'GET /clinic/appointments' => (
        200,
        _page([
          apptJson(
            'a1',
            'Ravi Shah',
            'in_consultation',
            token: 1,
            visitId: 'v1',
          ),
          apptJson('a2', 'Kiran Desai', 'arrived', token: 2),
          apptJson('a3', 'Meena Patel', 'booked', start: '10:00'),
          apptJson(
            'a4',
            'Fatima Sheikh',
            'done',
            start: '09:15',
            visitId: 'v0',
          ),
        ]),
      ),
      'GET /clinic/patients' => (200, _page([patientBrief])),
      'GET /clinic/doctors/d1/slots' => (
        200,
        {
          'date': o.queryParameters['date'],
          'slotMinutes': 15,
          'data': [
            {'startTime': '09:00', 'endTime': '09:15', 'free': true},
            {'startTime': '09:15', 'endTime': '09:30', 'free': false},
            {'startTime': '09:30', 'endTime': '09:45', 'free': true},
          ],
        },
      ),
      'POST /clinic/appointments' => (
        201,
        apptJson('a9', 'Ravi Shah', 'booked', start: '09:30'),
      ),
      'POST /clinic/patients' => (
        201,
        {...patientBrief, 'partyId': 'p9', 'canSee': true},
      ),
      'GET /clinic/visits/v1' => (200, v),
      'PATCH /clinic/visits/v1' => (
        200,
        {...v, 'updatedAt': '2026-11-12T09:05:00.000Z'},
      ),
      'POST /clinic/visits/v1/complete' => (200, {...v, 'status': 'closed'}),
      'GET /clinic/visits/v1/prescription' => (200, prescriptionJson()),
      'GET /clinic/patients/pt1/history' => (
        200,
        {
          'patient': {
            ...patientBrief,
            'bloodGroup': 'B+',
            'allergies': 'Penicillin',
            'address': 'Navrangpura',
          },
          'appointments': [],
          'visits': [
            {
              'id': 'v1',
              'date': _today,
              'status': 'closed',
              'feeKind': 'consultation',
              'doctor': {'id': 'd1', 'name': 'Dr Anil Mehta'},
              'diagnosis': 'Viral fever',
              'rxCount': 2,
              'invoice': {
                'id': 'i1',
                'number': 'INV/26-27/00007',
                'total': 500,
                'amountPaid': 200,
                'status': 'posted',
              },
            },
          ],
        },
      ),
      'GET /clinic/ipd/board' => (200, ipdBoardJson),
      'GET /clinic/ipd/admissions' => (
        200,
        _page([admissionJson(status: 'discharged')]),
      ),
      'GET /clinic/ipd/admissions/ad1' => (
        200,
        admissionJson(status: dischargedStay ? 'discharged' : 'admitted'),
      ),
      'POST /clinic/ipd/admissions/ad1/refund' => (
        201,
        {...admissionJson(status: 'discharged'), 'refundDue': 0},
      ),
      'POST /clinic/ipd/admissions' => (201, admissionJson()),
      'POST /clinic/ipd/admissions/ad1/charges' => (201, admissionJson()),
      'POST /clinic/ipd/admissions/ad1/deposits' => (201, admissionJson()),
      'POST /clinic/ipd/bed-charges/run' => (
        200,
        {'admissions': 1, 'added': 1},
      ),
      'GET /clinic/ipd/admissions/ad1/discharge-summary' => (
        200,
        dischargeSummaryJson(),
      ),
      'POST /clinic/ipd/admissions/ad1/discharge' => (
        200,
        {
          'admission': admissionJson(status: 'discharged'),
          'invoice': {'id': 'i9', 'number': 'INV/26-27/00009', 'total': 1800},
          'depositsApplied': 1000,
          'balanceDue': 0,
          'refundDue': 0,
        },
      ),
      _ => null,
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.startsWith('/clinic')) calls.add(options);
    final r = _route(options);
    if (r == null) return _core.fetch(options, requestStream, cancelFuture);
    return ResponseBody.fromString(
      jsonEncode(r.$2),
      r.$1,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class ClinicHarness {
  ClinicHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final ClinicFakeBackend backend;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

const frontDeskPermissions = {
  'clinic.view',
  'clinic.front_desk',
  'invoices.create',
  'payments.create',
};
const doctorPermissions = {'clinic.view', 'clinic.consult', 'invoices.create'};

Future<ClinicHarness> bootClinic(
  WidgetTester tester,
  Size size, {
  Set<String>? permissions,
  String location = '/clinic',
  Map<String, Object?>? visit,
  void Function(ClinicFakeBackend)? setup,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final perms =
      permissions ??
      {
        ...FakeBackend.allPermissions,
        ...frontDeskPermissions,
        ...doctorPermissions,
        'clinic.manage',
      };
  final backend = ClinicFakeBackend(perms, visit: visit);
  setup?.call(backend);
  final store = InMemoryTokenStore();
  await store.writeRefreshToken('refresh-1');
  final api = ApiClient(
    baseUrl: 'http://fake/api/v1',
    tokenStore: store,
    httpClientAdapter: backend,
  );
  final router = GoRouter(
    initialLocation: location,
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(
          appBar: AppBar(title: const Text('OneMatrix')),
          body: child,
        ),
        routes: clinicRoutes(),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        apiClientProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return ClinicHarness(tester, router, backend);
}
