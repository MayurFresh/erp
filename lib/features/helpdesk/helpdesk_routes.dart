/// Routes and menu entries of the helpdesk and service contracts (API 055,
/// module `helpdesk`).
///
/// Wire in `router.dart` (`...helpdeskRoutes()`) and `nav.dart`
/// (`NavGroup('Helpdesk', helpdeskNavEntries)`).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'contract_detail_screen.dart';
import 'contract_form_screen.dart';
import 'contract_list_screen.dart';
import 'helpdesk_reports_screen.dart';
import 'helpdesk_settings_screen.dart';
import 'ticket_detail_screen.dart';
import 'ticket_form_screen.dart';
import 'ticket_list_screen.dart';
import 'visit_calendar_screen.dart';

const List<NavEntry> helpdeskNavEntries = [
  NavEntry(
    path: '/helpdesk',
    label: 'Tickets',
    icon: Icons.support_agent_outlined,
    selectedIcon: Icons.support_agent,
    permission: Perm.helpdeskView,
    createPermission: Perm.helpdeskManage,
  ),
  NavEntry(
    path: '/service-contracts',
    label: 'Service contracts',
    icon: Icons.assignment_turned_in_outlined,
    selectedIcon: Icons.assignment_turned_in,
    permission: Perm.serviceContractsView,
    createPermission: Perm.serviceContractsManage,
  ),
];

List<RouteBase> helpdeskRoutes() => [
  GoRoute(
    path: '/helpdesk',
    pageBuilder: (_, state) => sectionPage(state, const TicketListScreen()),
    routes: [
      GoRoute(path: 'new', builder: (_, _) => const TicketFormScreen()),
      GoRoute(
        path: 'reports',
        builder: (_, _) => const HelpdeskReportsScreen(),
      ),
      GoRoute(
        path: 'settings',
        builder: (_, _) => const HelpdeskSettingsScreen(),
      ),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            TicketDetailScreen(ticketId: state.pathParameters['id']!),
      ),
    ],
  ),
  GoRoute(
    path: '/service-contracts',
    pageBuilder: (_, state) => sectionPage(state, const ContractListScreen()),
    routes: [
      GoRoute(path: 'new', builder: (_, _) => const ContractFormScreen()),
      GoRoute(path: 'visits', builder: (_, _) => const VisitCalendarScreen()),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            ContractDetailScreen(contractId: state.pathParameters['id']!),
      ),
    ],
  ),
];
