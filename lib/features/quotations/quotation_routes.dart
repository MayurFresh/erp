/// Routes and the menu entry of quotations and proforma invoices.
///
/// Wire-up (lead engineer): add `...quotationRoutes()` to the authenticated
/// `ShellRoute` in `router.dart` and [quotationNavEntry] to the Sales group
/// in `nav.dart`.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'quotation_detail_screen.dart';
import 'quotation_form_screen.dart';
import 'quotations_screen.dart';

const NavEntry quotationNavEntry = NavEntry(
  path: '/quotations',
  label: 'Quotations',
  icon: Icons.request_quote_outlined,
  selectedIcon: Icons.request_quote,
  permission: Perm.quotationsView,
  createPermission: Perm.quotationsManage,
);

List<RouteBase> quotationRoutes() => [
  GoRoute(
    path: '/quotations',
    pageBuilder: (c, s) => sectionPage(
      s,
      QuotationsScreen(
        partyId: s.uri.queryParameters['partyId'],
        dealId: s.uri.queryParameters['dealId'],
      ),
    ),
  ),
  // Static segments before ':id' so "new" is not read as an id.
  GoRoute(
    path: '/quotations/new',
    pageBuilder: (c, s) => sectionPage(
      s,
      QuotationFormScreen(
        partyId: s.uri.queryParameters['partyId'],
        dealId: s.uri.queryParameters['dealId'],
        contactId: s.uri.queryParameters['contactId'],
      ),
    ),
  ),
  GoRoute(
    path: '/quotations/:id',
    pageBuilder: (c, s) => sectionPage(
      s,
      QuotationDetailScreen(quotationId: s.pathParameters['id']!),
    ),
  ),
  GoRoute(
    path: '/quotations/:id/edit',
    pageBuilder: (c, s) => sectionPage(
      s,
      QuotationFormScreen(quotationId: s.pathParameters['id']),
    ),
  ),
];
