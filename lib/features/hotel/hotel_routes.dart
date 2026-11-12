/// Routes and menu entries of the hotel front office (API Wave 2, module `hotel`).
///
/// Wired in `router.dart` (`...hotelRoutes()`) and `nav.dart`
/// (`NavGroup('Hotel', hotelNavEntries)`).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'check_in_screen.dart';
import 'folio_screen.dart';
import 'hotel_home_screen.dart';
import 'hotel_reports_screen.dart';
import 'hotel_setup_screen.dart';
import 'housekeeping_screen.dart';
import 'reservation_form_screen.dart';
import 'reservations_screen.dart';
import 'room_board_screen.dart';

const List<NavEntry> hotelNavEntries = [
  NavEntry(
    path: '/hotel',
    label: 'Front office',
    icon: Icons.hotel_outlined,
    selectedIcon: Icons.hotel,
    permission: Perm.hotelView,
  ),
  NavEntry(
    path: '/hotel/board',
    label: 'Room board',
    icon: Icons.grid_view_outlined,
    selectedIcon: Icons.grid_view,
    permission: Perm.hotelView,
  ),
  NavEntry(
    path: '/hotel/reservations',
    label: 'Reservations',
    icon: Icons.event_available_outlined,
    selectedIcon: Icons.event_available,
    permission: Perm.hotelView,
  ),
  NavEntry(
    path: '/hotel/housekeeping',
    label: 'Housekeeping',
    icon: Icons.cleaning_services_outlined,
    selectedIcon: Icons.cleaning_services,
    permission: Perm.hotelView,
  ),
  NavEntry(
    path: '/hotel/reports',
    label: 'Hotel reports',
    icon: Icons.bar_chart_outlined,
    selectedIcon: Icons.bar_chart,
    permission: Perm.hotelView,
  ),
  NavEntry(
    path: '/hotel/setup',
    label: 'Room and rate setup',
    icon: Icons.meeting_room_outlined,
    selectedIcon: Icons.meeting_room,
    permission: Perm.hotelView,
  ),
];

List<RouteBase> hotelRoutes() => [
  GoRoute(
    path: '/hotel',
    pageBuilder: (_, state) => sectionPage(state, const HotelHomeScreen()),
    routes: [
      GoRoute(
        path: 'board',
        pageBuilder: (_, state) => sectionPage(state, const RoomBoardScreen()),
      ),
      GoRoute(
        path: 'housekeeping',
        pageBuilder: (_, state) => sectionPage(state, const HousekeepingScreen()),
      ),
      GoRoute(
        path: 'setup',
        pageBuilder: (_, state) => sectionPage(state, const HotelSetupScreen()),
      ),
      GoRoute(
        path: 'reports',
        pageBuilder: (_, state) => sectionPage(state, const HotelReportsScreen()),
      ),
      GoRoute(
        path: 'reservations',
        pageBuilder: (_, state) => sectionPage(state, const ReservationsScreen()),
        routes: [
          GoRoute(
            path: 'new',
            builder: (_, state) => ReservationFormScreen(
              arrival: state.uri.queryParameters['arrival'],
            ),
          ),
          GoRoute(
            path: ':id',
            builder: (_, state) =>
                FolioScreen(reservationId: state.pathParameters['id']!),
            routes: [
              GoRoute(
                path: 'check-in',
                builder: (_, state) =>
                    CheckInScreen(reservationId: state.pathParameters['id']!),
              ),
            ],
          ),
        ],
      ),
    ],
  ),
];
