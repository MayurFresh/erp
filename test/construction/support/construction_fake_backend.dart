import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:onematrix/features/construction/common/c_perms.dart';

import '../../support/fake_backend.dart';

/// The v1.2 construction endpoints, in process, with small mutable state.
/// Everything else (auth, /me, items, parties, locations, users, stock) is
/// delegated to the shared [FakeBackend], unchanged.
class ConstructionFakeBackend implements HttpClientAdapter {
  ConstructionFakeBackend({Set<String>? permissions})
    : permissions = permissions ?? allPermissions,
      _core = FakeBackend(permissions: permissions ?? allPermissions);

  static final allPermissions = {...FakeBackend.allPermissions, ...CPerm.all};

  final Set<String> permissions;
  final FakeBackend _core;
  final List<RequestOptions> requests = [];

  /// `'METHOD /path'` → (status, body), checked first.
  final Map<String, (int, Object?)> overrides = {};

  int count(String method, String path) =>
      requests.where((r) => r.method == method && r.path == path).length;

  RequestOptions last(String method, String path) =>
      requests.lastWhere((r) => r.method == method && r.path == path);

  /// JSON body of the last [method] [path] request.
  Map<String, dynamic> body(String method, String path) =>
      Map<String, dynamic>.from(last(method, path).data as Map);

  // ------------------------------------------------------------- fixtures

  static const site = {'id': 'l2', 'name': 'Site A — Tower 1'};
  static const user = {'id': 'u1', 'name': 'Asha Rao'};

  static Map<String, Object?> project() => {
    'id': 'pr1',
    'companyId': 'c1',
    'code': 'PRJ-001',
    'name': 'Tower Heights Residency',
    'clientPartyId': 'p1',
    'clientName': 'Mumbai Infra Projects LLP',
    'managerUserId': 'u2',
    'managerName': 'Ravi Kumar',
    'status': 'active',
    'startDate': '2026-04-01',
    'endDate': null,
    'contractValue': 125000000,
    'address': 'Whitefield, Bengaluru',
    'sites': [site],
    'budgetTotal': 304000,
    'progressPct': 37.5,
    'createdAt': '2026-04-01T09:30:00.000Z',
  };

  static Map<String, Object?> boqLine(
    String id,
    String code,
    String description, {
    double qty = 120,
    double rate = 450,
    double executed = 45,
  }) => {
    'id': id,
    'projectId': 'pr1',
    'code': code,
    'description': description,
    'unit': 'cum',
    'qty': qty,
    'rate': rate,
    'amount': qty * rate,
    'materialBudget': 20000,
    'labourBudget': 15000,
    'otherBudget': 0,
    'executedQty': executed,
    'progressPct': executed / qty * 100,
    'sortOrder': 1,
  };

  final List<Map<String, Object?>> boq = [
    boqLine('b1', '1.1', 'Excavation in ordinary soil'),
    boqLine('b2', '2.1', 'PCC 1:4:8 in foundation', qty: 35, rate: 5200),
  ];

  static Map<String, Object?> costs() => {
    'projectId': 'pr1',
    'from': '2026-04-01',
    'to': '2026-10-28',
    'budget': {'material': 40000, 'labour': 30000, 'other': 0, 'total': 70000},
    'actual': {
      'material': 46000,
      'labour': 12000,
      'expenses': 2500,
      'total': 60500,
    },
    'byBoqLine': [
      {
        'boqLineId': 'b1',
        'code': '1.1',
        'description': 'Excavation in ordinary soil',
        'qty': 120,
        'executedQty': 45,
        'progressPct': 37.5,
        'materialBudget': 20000,
        'materialActual': 26000,
      },
    ],
  };

  late final Map<String, Map<String, Object?>> indents = {
    'ind1': indent('ind1', 'IND/26-27/00001', 'submitted'),
    'ind2': indent('ind2', 'IND/26-27/00002', 'draft'),
  };

  static Map<String, Object?> indent(String id, String number, String status) =>
      {
        'id': id,
        'number': number,
        'projectId': 'pr1',
        'locationId': 'l2',
        'locationName': 'Site A — Tower 1',
        'requiredBy': '2026-10-30',
        'status': status,
        'notes': 'Needed for the 3rd floor slab',
        'createdAt': '2026-10-27T09:30:00.000Z',
        'createdBy': user,
        'approvedAt': null,
        'approvedBy': null,
        'rejectedAt': null,
        'rejectedBy': null,
        'rejectReason': null,
        'isFulfilled': false,
        'lines': [
          {
            'id': '${id}l1',
            'itemId': 'i1',
            'itemName': 'Portland Cement 53 Grade 50kg',
            'unit': 'bag',
            'qty': 200,
            'approvedQty': null,
            'fulfilledQty': 0,
            'boqLineId': 'b2',
          },
        ],
      };

  static Map<String, Object?> issue() => {
    'id': 'iss1',
    'number': 'ISS/26-27/00001',
    'locationId': 'l2',
    'locationName': 'Site A — Tower 1',
    'projectId': 'pr1',
    'boqLineId': 'b2',
    'boqCode': '2.1',
    'date': '2026-10-27',
    'notes': 'Foundation PCC',
    'status': 'posted',
    'createdAt': '2026-10-27T09:30:00.000Z',
    'createdBy': user,
    'cancelledAt': null,
    'cancelReason': null,
    'totalValue': 15100,
    'lines': [
      {
        'itemId': 'i1',
        'itemName': 'Portland Cement 53 Grade 50kg',
        'unit': 'bag',
        'qty': 40,
        'costRate': 377.5,
        'value': 15100,
      },
    ],
  };

  static Map<String, Object?> dpr({
    String id = 'dpr1',
    String status = 'draft',
  }) => {
    'id': id,
    'locationId': 'l2',
    'locationName': 'Site A — Tower 1',
    'projectId': 'pr1',
    'date': '2026-10-27',
    'weather': 'sunny',
    'status': status,
    'summary': 'Slab shuttering on the 3rd floor',
    'hindrances': 'Cement delivery late by 2 hours',
    'workDone': [
      {
        'id': 'wd1',
        'boqLineId': 'b1',
        'boqCode': '1.1',
        'description': 'Excavation in ordinary soil',
        'qty': 12.5,
        'unit': 'cum',
      },
    ],
    'labour': [
      {'trade': 'mason', 'count': 6},
      {'trade': 'helper', 'count': 10},
    ],
    'equipment': [
      {'name': 'JCB', 'hours': 6.5},
    ],
    'photos': [
      {'fileId': 'f1', 'url': '/api/v1/files/f1', 'caption': 'Column C4'},
    ],
    'createdAt': '2026-10-27T09:30:00.000Z',
    'createdBy': user,
    'submittedAt': null,
    'approvedAt': null,
    'approvedBy': null,
    'rejectedAt': null,
    'rejectedBy': null,
    'rejectReason': null,
  };

  static Map<String, Object?> worker(
    String id,
    String name, {
    String trade = 'mason',
  }) => {
    'id': id,
    'name': name,
    'phone': '9845012345',
    'trade': trade,
    'skill': 'skilled',
    'dailyRate': 800,
    'contractorPartyId': 'p2',
    'contractorName': 'Bengaluru Steel Suppliers',
    'siteId': 'l2',
    'siteName': 'Site A — Tower 1',
    'aadhaarLast4': '1234',
    'bocwRegNo': 'KA/BOCW/2026/0042',
    'photoFileId': null,
    'joinedOn': '2026-05-02',
    'isActive': true,
    'createdAt': '2026-05-02T09:30:00.000Z',
  };

  final List<Map<String, Object?>> workers = [
    worker('w1', 'Ramesh Kumar'),
    worker('w2', 'Suresh Patil', trade: 'helper'),
    worker('w3', 'Mohammed Irfan', trade: 'bar_bender'),
  ];

  /// workerId → (status, otHours) for the attendance sheet.
  final Map<String, (String?, double)> attendance = {
    'w1': ('present', 1),
    'w2': (null, 0),
    'w3': (null, 0),
  };
  bool attendanceLocked = false;

  Map<String, Object?> attendanceSheet(String date) => {
    'siteId': 'l2',
    'date': date,
    'locked': attendanceLocked,
    'rows': [
      for (final w in workers)
        {
          'workerId': w['id'],
          'workerName': w['name'],
          'trade': w['trade'],
          'contractorName': w['contractorName'],
          'status': attendance[w['id']]?.$1,
          'otHours': attendance[w['id']]?.$2 ?? 0,
        },
    ],
  };

  static Map<String, Object?> wageSheet({String status = 'draft'}) => {
    'id': 'wg1',
    'number': 'WG/26-27/00001',
    'siteId': 'l2',
    'siteName': 'Site A — Tower 1',
    'from': '2026-10-19',
    'to': '2026-10-25',
    'status': status,
    'totalGross': 5200,
    'totalDeductions': 500,
    'totalNet': 4700,
    'paidFromAccountId': null,
    'paidAt': null,
    'createdAt': '2026-10-26T09:30:00.000Z',
    'createdBy': user,
    'rows': [
      {
        'workerId': 'w1',
        'workerName': 'Ramesh Kumar',
        'trade': 'mason',
        'contractorName': 'Bengaluru Steel Suppliers',
        'dailyRate': 800,
        'presentDays': 5.5,
        'otHours': 4,
        'basic': 4400,
        'otAmount': 800,
        'gross': 5200,
        'advance': 500,
        'net': 4700,
      },
    ],
  };

  String wageStatus = 'draft';

  static const cash = {
    'id': 'a1',
    'code': '1000',
    'name': 'Cash in Hand',
    'type': 'asset',
    'subtype': 'cash',
    'systemKey': 'cash',
    'isSystem': true,
    'isActive': true,
    'balance': 0,
  };
  static final bank = {
    ...cash,
    'id': 'a2',
    'code': '1010',
    'name': 'Bank Account',
    'subtype': 'bank',
    'systemKey': 'bank',
  };

  /// A valid 1 × 1 PNG.
  static final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );

  // -------------------------------------------------------------- routing

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final key = '${options.method} ${options.path}';
    final override = overrides[key];
    final routed = override ?? _route(options);
    if (routed == null) {
      _core.requests.clear();
      return _core.fetch(options, requestStream, cancelFuture);
    }
    final (status, body) = routed;
    if (body is Uint8List) {
      return ResponseBody.fromBytes(
        body,
        status,
        headers: {
          Headers.contentTypeHeader: ['image/png'],
        },
      );
    }
    return ResponseBody.fromString(
      body == null ? '' : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  static (int, Object?) error(int status, String code, String message) => (
    status,
    {
      'error': {'code': code, 'message': message, 'details': {}},
    },
  );

  Map<String, Object?> _page(List<Object?> data) => {
    'data': data,
    'total': data.length,
  };

  Map<String, dynamic> _json(RequestOptions o) =>
      o.data is Map ? Map<String, dynamic>.from(o.data as Map) : {};

  /// `null` = not a construction endpoint (delegated).
  (int, Object?)? _route(RequestOptions o) {
    final m = o.method;
    final p = o.path;
    final q = o.queryParameters;
    final seg = p.split('/').where((s) => s.isNotEmpty).toList();
    switch (seg.firstOrNull) {
      case 'accounts':
        return (
          200,
          _page([
            if (q['subtype'] != 'bank') cash,
            if (q['subtype'] != 'cash') bank,
          ]),
        );
      case 'projects':
        if (seg.length == 1) {
          return m == 'POST' ? (201, project()) : (200, _page([project()]));
        }
        if (seg.length == 2) return (200, project());
        if (seg[2] == 'costs') return (200, costs());
        if (seg[2] == 'boq' && m == 'GET') return (200, _page(boq));
        if (seg[2] == 'boq') {
          final b = _json(o);
          if (b['lines'] is List) {
            final added = <Map<String, Object?>>[
              for (final (i, l) in (b['lines'] as List).indexed)
                {
                  ...boqLine('nb$i', 'x', 'x'),
                  ...Map<String, Object?>.from(l as Map),
                },
            ];
            boq.addAll(added);
            return (201, _page(added));
          }
          final line = {...boqLine('nb', 'x', 'x'), ...b};
          boq.add(line);
          return (201, line);
        }
      case 'boq':
        if (m == 'DELETE') return (204, null);
        return (200, {...boq.first, ..._json(o)});
      case 'indents':
        if (seg.length == 1 && m == 'GET') {
          return (200, _page(indents.values.toList()));
        }
        if (seg.length == 1) {
          final b = _json(o);
          final created = indent(
            'ind9',
            'IND/26-27/00009',
            b['submit'] == true ? 'submitted' : 'draft',
          );
          indents['ind9'] = created;
          return (201, created);
        }
        final current = indents[seg[1]];
        if (current == null) return error(404, 'NOT_FOUND', 'Indent not found');
        if (seg.length == 2 && m == 'PUT') return (200, current);
        if (seg.length == 2) return (200, current);
        final action = seg[2];
        if (action == 'approve') {
          final approved = {
            for (final l in (_json(o)['lines'] as List? ?? const []))
              (l as Map)['lineId']: l['approvedQty'],
          };
          current['status'] = 'approved';
          current['approvedBy'] = user;
          current['lines'] = [
            for (final l in current['lines'] as List)
              {...l as Map, 'approvedQty': approved[l['id']] ?? l['qty']},
          ];
        } else {
          current['status'] = switch (action) {
            'submit' => 'submitted',
            'reject' => 'rejected',
            'close' => 'closed',
            _ => current['status'],
          };
          if (action == 'reject') current['rejectReason'] = _json(o)['reason'];
        }
        return (200, current);
      case 'issues':
        if (seg.length == 1 && m == 'GET') return (200, _page([issue()]));
        if (seg.length == 1) {
          final lines = _json(o)['lines'] as List;
          if (lines.any((l) => ((l as Map)['qty'] as num) > 100)) {
            return error(
              409,
              'INSUFFICIENT_STOCK',
              'Only 40 bag of Portland Cement 53 Grade 50kg at Site A.',
            );
          }
          return (201, issue());
        }
        if (seg.length == 3 && seg[2] == 'cancel') {
          return (
            200,
            {
              ...issue(),
              'status': 'cancelled',
              'cancelReason': _json(o)['reason'],
            },
          );
        }
        return (200, issue());
      case 'files':
        if (m == 'POST') {
          return (
            201,
            {
              'id': 'f9',
              'name': 'site.jpg',
              'mimeType': 'image/jpeg',
              'size': 2048,
              'url': '/api/v1/files/f9',
            },
          );
        }
        return (200, png);
      case 'dprs':
        if (seg.length == 1 && m == 'GET') {
          return (200, _page([dpr(), dpr(id: 'dpr2', status: 'submitted')]));
        }
        if (seg.length == 1) {
          final b = _json(o);
          return (
            201,
            {
              ...dpr(id: 'dpr9'),
              ...b,
              'status': b['submit'] == true ? 'submitted' : 'draft',
            },
          );
        }
        if (seg[1] == 'previous') return (200, dpr());
        if (seg.length == 2 && m == 'PATCH') return (200, dpr(id: seg[1]));
        if (seg.length == 2) {
          return (
            200,
            dpr(id: seg[1], status: seg[1] == 'dpr2' ? 'submitted' : 'draft'),
          );
        }
        return (
          200,
          dpr(
            id: seg[1],
            status: switch (seg[2]) {
              'approve' => 'approved',
              'reject' => 'rejected',
              _ => 'submitted',
            },
          ),
        );
      case 'workers':
        if (seg.length == 1 && m == 'GET') return (200, _page(workers));
        if (seg.length == 1) return (201, {...workers.first, ..._json(o)});
        return (200, workers.firstWhere((w) => w['id'] == seg[1]));
      case 'attendance':
        if (m == 'PUT') {
          if (attendanceLocked) {
            return error(
              409,
              'LOCKED',
              'Attendance is locked by an approved wage sheet.',
            );
          }
          final b = _json(o);
          for (final e in b['entries'] as List) {
            final entry = e as Map;
            attendance[entry['workerId'] as String] = (
              entry['status'] as String,
              (entry['otHours'] as num? ?? 0).toDouble(),
            );
          }
          return (200, attendanceSheet(b['date'] as String));
        }
        return (200, attendanceSheet(q['date']?.toString() ?? '2026-10-28'));
      case 'wage-sheets':
        if (seg.length == 1 && m == 'GET') {
          return (200, _page([Map.of(wageSheet())..remove('rows')]));
        }
        if (seg.length == 1) return (201, wageSheet());
        if (seg.length == 3) {
          wageStatus = switch (seg[2]) {
            'approve' => 'approved',
            'pay' => 'paid',
            'cancel' => 'cancelled',
            _ => wageStatus,
          };
        }
        return (200, wageSheet(status: wageStatus));
    }
    return null;
  }

  @override
  void close({bool force = false}) {}
}
