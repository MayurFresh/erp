/// Routes and menu entries of the GST compliance updates (API "GST compliance updates").
///
/// Wire-up (lead engineer): add `...gstComplianceRoutes()` to the shell routes
/// in `router.dart` and `gstComplianceNavEntries` to the Compliance group in
/// `nav.dart`.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../compliance/tax_perms.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'ims_screen.dart';
import 'msme_43bh_screen.dart';
import 'slab_review_screen.dart';
import 'unreported_einvoice_screen.dart';

const List<NavEntry> gstComplianceNavEntries = [
  NavEntry(
    path: '/ims',
    label: 'IMS actions',
    icon: Icons.fact_check_outlined,
    selectedIcon: Icons.fact_check,
    permission: TaxPerm.gstView,
  ),
  NavEntry(
    path: '/einvoice-unreported',
    label: 'Unreported e-invoices',
    icon: Icons.pending_actions_outlined,
    selectedIcon: Icons.pending_actions,
    permission: TaxPerm.gstView,
  ),
  NavEntry(
    path: '/gst-slab-review',
    label: 'GST slab review',
    icon: Icons.rule_outlined,
    selectedIcon: Icons.rule,
    permission: TaxPerm.gstView,
  ),
  NavEntry(
    path: '/msme-43bh',
    label: 'MSME year-end dues',
    icon: Icons.event_busy_outlined,
    selectedIcon: Icons.event_busy,
    permission: Perm.reportsView,
  ),
];

List<RouteBase> gstComplianceRoutes() => [
  GoRoute(
    path: '/ims',
    pageBuilder: (_, state) => sectionPage(state, const ImsScreen()),
  ),
  GoRoute(
    path: '/einvoice-unreported',
    pageBuilder: (_, state) =>
        sectionPage(state, const UnreportedEinvoiceScreen()),
  ),
  GoRoute(
    path: '/gst-slab-review',
    pageBuilder: (_, state) => sectionPage(state, const SlabReviewScreen()),
  ),
  GoRoute(
    path: '/msme-43bh',
    pageBuilder: (_, state) => sectionPage(state, const Msme43bhScreen()),
  ),
];
