import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'hotel_models.dart';

/// Hotel data whose lists reload after a write.
enum HotelKind { setup, rooms, reservations }

final hotelRevisionProvider =
    NotifierProvider.family<HotelRevisionNotifier, int, HotelKind>(
      HotelRevisionNotifier.new,
    );

class HotelRevisionNotifier extends Notifier<int> {
  HotelRevisionNotifier(this.kind);

  final HotelKind kind;

  @override
  int build() => 0;

  void bump() => state++;
}

extension HotelWatch on Ref {
  void watchHotel() {
    for (final k in HotelKind.values) {
      watch(hotelRevisionProvider(k));
    }
  }
}

extension HotelBump on WidgetRef {
  /// Reloads every hotel list; [money] also reloads invoices and payments.
  void bumpHotel({bool money = false}) {
    for (final k in HotelKind.values) {
      read(hotelRevisionProvider(k).notifier).bump();
    }
    if (money) {
      bump(const [DataKind.invoices, DataKind.payments, DataKind.parties]);
    }
  }
}

final hotelRepositoryProvider = Provider<HotelRepository>(
  (ref) => HotelRepository(ref.watch(apiClientProvider)),
);

final hotelTodayProvider = FutureProvider.autoDispose<TodayData>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watchHotel();
  return ref.watch(hotelRepositoryProvider).today();
});

final hotelRoomsProvider = FutureProvider.autoDispose<List<Room>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watchHotel();
  return ref.watch(hotelRepositoryProvider).rooms();
});

final hotelRoomTypesProvider = FutureProvider.autoDispose<List<RoomType>>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchHotel();
  return ref.watch(hotelRepositoryProvider).roomTypes();
});

final hotelRatePlansProvider = FutureProvider.autoDispose<List<RatePlan>>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchHotel();
  return ref.watch(hotelRepositoryProvider).ratePlans();
});

final hotelBoardProvider = FutureProvider.autoDispose.family<Board, String>((
  ref,
  from,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchHotel();
  return ref.watch(hotelRepositoryProvider).board(from);
});

final hotelFolioProvider = FutureProvider.autoDispose.family<Folio, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchHotel();
  return ref.watch(hotelRepositoryProvider).folio(id);
});

final hotelReservationProvider = FutureProvider.autoDispose
    .family<Reservation, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watchHotel();
      return ref.watch(hotelRepositoryProvider).reservation(id);
    });

/// `status|query` → reservations.
final hotelReservationsProvider = FutureProvider.autoDispose
    .family<List<Reservation>, ({String? status, String? q})>((ref, key) {
      ref.watch(activeCompanyIdProvider);
      ref.watchHotel();
      return ref
          .watch(hotelRepositoryProvider)
          .reservations(status: key.status, q: key.q);
    });

class HotelRepository {
  HotelRepository(this._api);

  final ApiClient _api;

  Future<TodayData> today() async =>
      TodayData.fromJson(await _api.getJson('/hotel/today'));

  Future<List<Room>> rooms() async =>
      (await _api.getPage('/hotel/rooms', Room.fromJson, query: {'all': true}))
          .data;

  Future<Room> setRoomStatus(String id, String status, {String? reason}) async =>
      Room.fromJson(
        await _api.patchJson(
          '/hotel/rooms/$id/status',
          body: {'status': status, 'reason': reason},
        ),
      );

  Future<Room> saveRoom(String? id, Json body) async => Room.fromJson(
    id == null
        ? await _api.postJson('/hotel/rooms', body: body)
        : await _api.patchJson('/hotel/rooms/$id', body: body),
  );

  Future<List<RoomType>> roomTypes() async =>
      (await _api.getPage('/hotel/room-types', RoomType.fromJson)).data;

  Future<RoomType> saveRoomType(String? id, Json body) async =>
      RoomType.fromJson(
        id == null
            ? await _api.postJson('/hotel/room-types', body: body)
            : await _api.patchJson('/hotel/room-types/$id', body: body),
      );

  Future<List<RatePlan>> ratePlans() async =>
      (await _api.getPage('/hotel/rate-plans', RatePlan.fromJson)).data;

  Future<RatePlan> saveRatePlan(String? id, Json body) async =>
      RatePlan.fromJson(
        id == null
            ? await _api.postJson('/hotel/rate-plans', body: body)
            : await _api.patchJson('/hotel/rate-plans/$id', body: body),
      );

  Future<Board> board(String from, {int days = 14}) async => Board.fromJson(
    await _api.getJson('/hotel/board', query: {'from': from, 'days': days}),
  );

  Future<List<TypeAvailability>> availability(String from, String to) async =>
      asJsonList(
        (await _api.getJson(
          '/hotel/availability',
          query: {'from': from, 'to': to},
        ))['types'],
      ).map(TypeAvailability.fromJson).toList();

  Future<List<Reservation>> reservations({String? status, String? q}) async =>
      (await _api.getPage(
        '/hotel/reservations',
        Reservation.fromJson,
        query: {'status': status, 'q': q, 'limit': 100},
      )).data;

  Future<Reservation> reservation(String id) async =>
      Reservation.fromJson(await _api.getJson('/hotel/reservations/$id'));

  Future<Reservation> createReservation(Json body) async =>
      Reservation.fromJson(await _api.postJson('/hotel/reservations', body: body));

  Future<Reservation> action(String id, String action, {Json? body}) async =>
      Reservation.fromJson(
        await _api.postJson('/hotel/reservations/$id/$action', body: body ?? const {}),
      );

  Future<Reservation> checkIn(String id, Json body) async => Reservation.fromJson(
    await _api.postJson('/hotel/reservations/$id/check-in', body: body),
  );

  Future<Folio> folio(String id) async =>
      Folio.fromJson(await _api.getJson('/hotel/reservations/$id/folio'));

  Future<Folio> addCharge(String id, Json body) async => Folio.fromJson(
    await _api.postJson('/hotel/reservations/$id/charges', body: body),
  );

  Future<Folio> voidCharge(String id, String lineId, String reason) async =>
      Folio.fromJson(
        await _api.postJson(
          '/hotel/reservations/$id/charges/$lineId/void',
          body: {'reason': reason},
        ),
      );

  Future<Folio> addPayment(String id, Json body) async => Folio.fromJson(
    await _api.postJson('/hotel/reservations/$id/payments', body: body),
  );

  Future<int> postNights() async => asInt(
    (await _api.postJson('/hotel/night-charges', body: const {}))['posted'],
  );

  Future<CheckOutResult> checkOut(String id, Json body) async =>
      CheckOutResult.fromJson(
        await _api.postJson('/hotel/reservations/$id/check-out', body: body),
      );

  Future<List<OccupancyRow>> occupancy(String from, String to) async =>
      asJsonList(
        (await _api.getJson(
          '/hotel/reports/occupancy',
          query: {'from': from, 'to': to},
        ))['rows'],
      ).map(OccupancyRow.fromJson).toList();

  Future<List<RegisterRow>> guestRegister(String from, String to) async =>
      asJsonList(
        (await _api.getJson(
          '/hotel/reports/guest-register',
          query: {'from': from, 'to': to},
        ))['data'],
      ).map(RegisterRow.fromJson).toList();
}
