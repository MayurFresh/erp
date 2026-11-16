/// Routes and menu entries of the CRM module (API v1.14: leads, deals and
/// follow-ups).
///
/// Wire-up (lead engineer): add `...crmRoutes()` to the routes of the
/// authenticated `ShellRoute` in `router.dart`, and `crmNavEntries` to a
/// group in `nav.dart`. Entries need module `crm` to be enabled.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'crm_settings_screen.dart';
import 'customer_timeline_screen.dart';
import 'deal_detail_screen.dart';
import 'deals_screen.dart';
import 'lead_detail_screen.dart';
import 'leads_screen.dart';
import 'numbers_screen.dart';
import 'today_screen.dart';

const List<NavEntry> crmNavEntries = [
  NavEntry(
    path: '/crm',
    label: 'Today',
    icon: Icons.today_outlined,
    selectedIcon: Icons.today,
    permission: Perm.crmView,
  ),
  NavEntry(
    path: '/crm/leads',
    label: 'Leads',
    icon: Icons.person_search_outlined,
    selectedIcon: Icons.person_search,
    permission: Perm.crmView,
    createPermission: Perm.crmManage,
  ),
  NavEntry(
    path: '/crm/deals',
    label: 'Deals',
    icon: Icons.handshake_outlined,
    selectedIcon: Icons.handshake,
    permission: Perm.crmView,
  ),
  NavEntry(
    path: '/crm/numbers',
    label: 'Numbers',
    icon: Icons.insights_outlined,
    selectedIcon: Icons.insights,
    permission: Perm.crmView,
  ),
  NavEntry(
    path: '/crm/settings',
    label: 'Sales settings',
    icon: Icons.tune_outlined,
    selectedIcon: Icons.tune,
    permission: Perm.crmSettings,
  ),
];

List<RouteBase> crmRoutes() => [
  GoRoute(
    path: '/crm',
    pageBuilder: (c, s) => sectionPage(s, const CrmTodayScreen()),
  ),
  GoRoute(
    path: '/crm/leads',
    pageBuilder: (c, s) => sectionPage(s, const CrmLeadsScreen()),
  ),
  GoRoute(
    path: '/crm/leads/:id',
    pageBuilder: (c, s) => sectionPage(
      s,
      CrmLeadDetailScreen(leadId: s.pathParameters['id']!),
    ),
  ),
  GoRoute(
    path: '/crm/deals',
    pageBuilder: (c, s) => sectionPage(s, const CrmDealsScreen()),
  ),
  GoRoute(
    path: '/crm/deals/:id',
    pageBuilder: (c, s) => sectionPage(
      s,
      CrmDealDetailScreen(dealId: s.pathParameters['id']!),
    ),
  ),
  GoRoute(
    path: '/crm/customers/:partyId',
    pageBuilder: (c, s) => sectionPage(
      s,
      CrmCustomerScreen(partyId: s.pathParameters['partyId']!),
    ),
  ),
  GoRoute(
    path: '/crm/numbers',
    pageBuilder: (c, s) => sectionPage(s, const CrmNumbersScreen()),
  ),
  GoRoute(
    path: '/crm/settings',
    pageBuilder: (c, s) => sectionPage(s, const CrmSettingsScreen()),
  ),
];
