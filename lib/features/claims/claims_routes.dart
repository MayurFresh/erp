/// Routes and menu entries of employee expense claims, advances and loans.
///
/// Wire-up (lead engineer): add `...claimsRoutes()` to the routes of the
/// authenticated `ShellRoute` in `router.dart`, and [claimsNavEntries] to the
/// HR and payroll group in `nav.dart`. Paths also used by the screens:
/// `/my-claims`, `/my-claims/new`, `/claims/approvals`, `/claims/categories`,
/// `/claims/:id`, `/claims/:id/edit`, `/loans`, `/loans/new`, `/loans/:id`.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'approval_queue_screen.dart';
import 'claim_categories_screen.dart';
import 'claim_detail_screen.dart';
import 'claim_form_screen.dart';
import 'loans_screens.dart';
import 'my_claims_screen.dart';

const List<NavEntry> claimsNavEntries = [
  NavEntry(
    path: '/my-claims',
    label: 'My claims',
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long,
    permission: Perm.payrollSelf,
  ),
  NavEntry(
    path: '/claims/approvals',
    label: 'Claim approvals',
    icon: Icons.fact_check_outlined,
    selectedIcon: Icons.fact_check,
    permission: Perm.claimsApprove,
  ),
  NavEntry(
    path: '/claims/categories',
    label: 'Claim categories',
    icon: Icons.category_outlined,
    selectedIcon: Icons.category,
    permission: Perm.claimsManage,
  ),
  NavEntry(
    path: '/loans',
    label: 'Staff loans',
    icon: Icons.account_balance_wallet_outlined,
    selectedIcon: Icons.account_balance_wallet,
    permission: Perm.loansManage,
    createPermission: Perm.loansManage,
  ),
];

List<RouteBase> claimsRoutes() => [
  GoRoute(path: '/my-claims', pageBuilder: (c, s) => sectionPage(s, const MyClaimsScreen())),
  GoRoute(path: '/my-claims/new', pageBuilder: (c, s) => sectionPage(s, const ClaimFormScreen())),
  // Static segments before ':id'.
  GoRoute(path: '/claims/approvals', pageBuilder: (c, s) => sectionPage(s, const ApprovalQueueScreen())),
  GoRoute(path: '/claims/categories', pageBuilder: (c, s) => sectionPage(s, const ClaimCategoriesScreen())),
  GoRoute(
    path: '/claims/:id',
    pageBuilder: (c, s) => sectionPage(s, ClaimDetailScreen(claimId: s.pathParameters['id']!)),
  ),
  GoRoute(
    path: '/claims/:id/edit',
    pageBuilder: (c, s) => sectionPage(s, ClaimFormScreen(claimId: s.pathParameters['id'])),
  ),
  GoRoute(path: '/loans', pageBuilder: (c, s) => sectionPage(s, const LoansScreen())),
  GoRoute(path: '/loans/new', pageBuilder: (c, s) => sectionPage(s, const LoanFormScreen())),
  GoRoute(
    path: '/loans/:id',
    pageBuilder: (c, s) => sectionPage(s, LoanDetailScreen(loanId: s.pathParameters['id']!)),
  ),
];
