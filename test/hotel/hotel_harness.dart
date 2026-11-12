import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:progen_erp/core/api_client.dart';
import 'package:progen_erp/core/money.dart';
import 'package:progen_erp/core/providers.dart';
import 'package:progen_erp/core/theme.dart';
import 'package:progen_erp/core/token_store.dart';
import 'package:progen_erp/features/hotel/hotel_routes.dart';

import '../support/fake_backend.dart';

const hotelTestSizes = [Size(320, 700), Size(390, 844), Size(1440, 900)];

final _today = apiDate(DateTime.now());
final _tomorrow = apiDate(DateTime.now().add(const Duration(days: 1)));
final _later = apiDate(DateTime.now().add(const Duration(days: 3)));

Map<String, Object?> roomJson(
  String id,
  String number,
  String status, {
  bool occupied = false,
  String? guest,
}) => {
  'id': id,
  'number': number,
  'floor': '1',
  'type': 'Deluxe',
  'roomTypeId': 't1',
  'status': status,
  'statusReason': null,
  'isActive': true,
  'occupied': occupied,
  'guest': guest,
  'updatedAt': '2026-11-01T10:00:00.000Z',
};

Map<String, Object?> bookedRoom({String? roomId, String? number}) => {
  'id': 'x1',
  'roomTypeId': 't1',
  'typeName': 'Deluxe',
  'roomId': roomId,
  'roomNumber': number,
  'adults': 2,
  'children': 0,
  'guest': null,
};

Map<String, Object?> reservationJson(String status, {bool assigned = true}) => {
  'id': 'r1',
  'number': 'RSV/26-27/00001',
  'status': status,
  'arrival': _today,
  'departure': _later,
  'nights': 3,
  'guest': {'partyId': 'p1', 'name': 'Ravi Shah', 'phone': '9825012345'},
  'overrideTariff': null,
  'source': 'walk_in',
  'sourceName': null,
  'notes': null,
  'advance': 1000,
  'rooms': [bookedRoom(roomId: assigned ? 'ro1' : null, number: assigned ? '101' : null)],
  'updatedAt': '2026-11-12T09:00:00.000Z',
};

Map<String, Object?> folioJson({String status = 'checked_in', double balance = 1861}) => {
  'reservation': reservationJson(status),
  'pricesIncludeTax': false,
  'lines': [
    {
      'id': 'l1',
      'date': _today,
      'kind': 'room',
      'chargeType': 'room',
      'description': 'Room 101 (Deluxe), night of $_today',
      'qty': 1,
      'rate': 2500,
      'amount': 2500,
      'gstRate': 5,
      'voided': false,
    },
    {
      'id': 'l2',
      'date': _today,
      'kind': 'extra',
      'chargeType': 'laundry',
      'description': 'Laundry',
      'qty': 1,
      'rate': 200,
      'amount': 200,
      'gstRate': 18,
      'voided': false,
    },
  ],
  'payments': [
    {'id': 'f1', 'paymentId': 'pay1', 'number': 'RCT/26-27/00001', 'kind': 'advance', 'amount': 1000, 'mode': 'cash', 'status': 'posted'},
  ],
  'totals': {
    'gross': 2700,
    'discount': 0,
    'subtotal': 2700,
    'tax': 161,
    'total': 2861,
    'paid': 1000,
    'balance': balance,
    'estimate': true,
  },
  'invoice': null,
};

Map<String, Object?> deskItem(String id, String guest, String status, {double? balance}) => {
  'id': id,
  'number': 'RSV/26-27/0000$id',
  'status': status,
  'guest': guest,
  'phone': '9800000000',
  'arrival': _today,
  'departure': _tomorrow,
  'rooms': [
    {'id': 'x$id', 'type': 'Deluxe', 'number': '10$id'},
  ],
  'advance': 0,
  'balance': balance,
};

final todayJson = {
  'date': _today,
  'arrivals': [deskItem('1', 'Meena Patel', 'confirmed')],
  'departures': [deskItem('2', 'Kiran Desai', 'checked_in', balance: 1500)],
  'inHouse': [deskItem('2', 'Kiran Desai', 'checked_in'), deskItem('3', 'Suresh Joshi', 'checked_in')],
  'roomCounts': {'clean': 5, 'dirty': 2, 'inspected': 1, 'out_of_order': 1},
  'occupied': 3,
  'totalRooms': 9,
};

Map<String, Object?> boardJson() {
  final dates = [for (var i = 0; i < 14; i++) apiDate(DateTime.now().add(Duration(days: i)))];
  return {
    'from': dates.first,
    'days': 14,
    'dates': dates,
    'rooms': [
      {
        'id': 'ro1',
        'number': '101',
        'floor': '1',
        'type': 'Deluxe',
        'status': 'clean',
        'stays': [
          {
            'id': 'x1',
            'reservationId': 'r1',
            'number': 'RSV/26-27/00001',
            'guest': 'Ravi Shah',
            'arrival': _today,
            'departure': _later,
            'status': 'checked_in',
            'typeName': 'Deluxe',
          },
        ],
      },
      {'id': 'ro2', 'number': '102', 'floor': '1', 'type': 'Deluxe', 'status': 'dirty', 'stays': <Object?>[]},
    ],
    'unassigned': <Object?>[],
  };
}

/// The hotel endpoints; everything else goes to the shared backend.
class HotelFakeBackend implements HttpClientAdapter {
  HotelFakeBackend(Set<String> permissions, {this.reservationStatus = 'checked_in'})
    : _core = FakeBackend(permissions: permissions);

  final FakeBackend _core;
  final String reservationStatus;
  final List<RequestOptions> calls = [];
  List<Map<String, Object?>> rooms = [
    roomJson('ro1', '101', 'clean', occupied: true, guest: 'Ravi Shah'),
    roomJson('ro2', '102', 'dirty'),
    roomJson('ro3', '103', 'inspected'),
  ];

  Map<String, Object?> page(List<Object?> d) => {'data': d, 'total': d.length};

  Map<String, Object?> body(String method, String path) {
    final o = calls.lastWhere((r) => r.method == method && r.path == path);
    final data = o.data;
    return data is Map ? Map<String, Object?>.from(data) : jsonDecode(data as String) as Map<String, Object?>;
  }

  int count(String method, String path) =>
      calls.where((r) => r.method == method && r.path == path).length;

  (int, Object?)? _route(RequestOptions o) {
    final key = '${o.method} ${o.path}';
    return switch (key) {
      'GET /hotel/today' => (200, todayJson),
      'GET /hotel/board' => (200, boardJson()),
      'GET /hotel/rooms' => (200, page(rooms)),
      'GET /hotel/room-types' => (200, page([
        {'id': 't1', 'name': 'Deluxe', 'baseOccupancy': 2, 'maxOccupancy': 3, 'baseTariff': 2500, 'extraPersonCharge': 500, 'isActive': true, 'roomCount': 3, 'updatedAt': '2026-11-01T10:00:00.000Z'},
      ])),
      'GET /hotel/rate-plans' => (200, page([
        {'id': 'rp1', 'roomTypeId': 't1', 'name': 'Deluxe with breakfast', 'meal': 'breakfast', 'weekdayTariff': 2750, 'weekendTariff': 3200, 'isActive': true},
      ])),
      'GET /hotel/availability' => (200, {
        'dates': [_today],
        'types': [
          {'roomTypeId': 't1', 'name': 'Deluxe', 'total': 3, 'byDate': [{'date': _today, 'booked': 1, 'available': 2}]},
        ],
      }),
      'GET /hotel/reservations' => (200, page([reservationJson(reservationStatus)])),
      'GET /hotel/reservations/r1' => (200, reservationJson(reservationStatus)),
      'GET /hotel/reservations/r1/folio' => (200, folioJson(status: reservationStatus)),
      'POST /hotel/reservations' => (201, reservationJson('confirmed')),
      'POST /hotel/reservations/r1/check-out' => (200, {
        'reservation': reservationJson('checked_out'),
        'invoice': {'id': 'inv1', 'number': 'INV/26-27/00007', 'total': 2861},
        'balanceDue': 0,
        'refundDue': 0,
      }),
      'POST /hotel/reservations/r1/check-in' => (200, reservationJson('checked_in')),
      'PATCH /hotel/rooms/ro2/status' => (200, roomJson('ro2', '102', 'clean')),
      'GET /hotel/reports/occupancy' => (200, {
        'rows': [
          {'date': _today, 'available': 9, 'sold': 3, 'revenue': 7500, 'occupancyPct': 33.33, 'adr': 2500, 'revpar': 833.33},
        ],
      }),
      'GET /hotel/reports/guest-register' => (200, {'data': <Object?>[]}),
      _ => null,
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.startsWith('/hotel')) calls.add(options);
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

class HotelHarness {
  HotelHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final HotelFakeBackend backend;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

const frontOfficePermissions = {
  'hotel.view',
  'hotel.front_office',
  'invoices.create',
  'payments.create',
};
const housekeepingPermissions = {'hotel.view', 'hotel.housekeeping'};

Future<HotelHarness> bootHotel(
  WidgetTester tester,
  Size size, {
  Set<String>? permissions,
  String location = '/hotel',
  String reservationStatus = 'checked_in',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final perms = permissions ?? {...FakeBackend.allPermissions, ...frontOfficePermissions, 'hotel.manage', 'hotel.housekeeping'};
  final backend = HotelFakeBackend(perms, reservationStatus: reservationStatus);
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
          appBar: AppBar(title: const Text('Progen')),
          body: child,
        ),
        routes: hotelRoutes(),
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
  return HotelHarness(tester, router, backend);
}
