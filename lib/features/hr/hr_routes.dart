/// Routes and menu entries of HR and payroll (API v1.12).
///
/// Wired in `router.dart` (`...hrRoutes()`) and `nav.dart`
/// (`NavGroup('HR and payroll', hrNavEntries)`, module `payroll`).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'attendance_screen.dart';
import 'employees_screen.dart';
import 'hr_home_screen.dart';
import 'hr_setup_screen.dart';
import 'leave_screen.dart';
import 'my_pay_screen.dart';
import 'payroll_screen.dart';
import 'payslip_screen.dart';
import 'bonus_screen.dart';
import 'encashment_screen.dart';
import 'fnf_screen.dart';
import 'gratuity_provision_screen.dart';
import 'gratuity_screen.dart';
import 'shifts_screen.dart';
import 'statutory_settings_screen.dart';

const List<NavEntry> hrNavEntries = [
  NavEntry(
    path: '/hr/employees',
    label: 'Employees',
    icon: Icons.badge_outlined,
    selectedIcon: Icons.badge,
    permission: Perm.payrollEmployees,
  ),
  NavEntry(
    path: '/hr/setup',
    label: 'HR setup',
    icon: Icons.tune_outlined,
    selectedIcon: Icons.tune,
    permission: Perm.payrollEmployees,
  ),
  NavEntry(
    path: '/hr',
    label: 'HR overview',
    icon: Icons.groups_outlined,
    selectedIcon: Icons.groups,
    permission: Perm.payrollEmployees,
  ),
  NavEntry(
    path: '/leave',
    label: 'Leave',
    icon: Icons.event_available_outlined,
    selectedIcon: Icons.event_available,
    permission: Perm.payrollLeaveApprove,
  ),
  NavEntry(
    path: '/hr/attendance',
    label: 'Attendance',
    icon: Icons.fact_check_outlined,
    selectedIcon: Icons.fact_check,
    permission: Perm.payrollEmployees,
  ),
  NavEntry(
    path: '/payroll',
    label: 'Payroll',
    icon: Icons.payments_outlined,
    selectedIcon: Icons.payments,
    permission: Perm.payrollView,
  ),
  NavEntry(
    path: '/hr/statutory',
    label: 'Statutory settings',
    icon: Icons.gavel_outlined,
    selectedIcon: Icons.gavel,
    permission: Perm.payrollEmployees,
  ),
  NavEntry(
    path: '/hr/gratuity',
    label: 'Gratuity',
    icon: Icons.savings_outlined,
    selectedIcon: Icons.savings,
    permission: Perm.payrollView,
  ),
  NavEntry(
    path: '/hr/gratuity-provision',
    label: 'Gratuity provision',
    icon: Icons.account_balance_outlined,
    selectedIcon: Icons.account_balance,
    permission: Perm.payrollView,
  ),
  NavEntry(
    path: '/hr/bonus',
    label: 'Statutory bonus',
    icon: Icons.card_giftcard_outlined,
    selectedIcon: Icons.card_giftcard,
    permission: Perm.payrollView,
  ),
  NavEntry(
    path: '/hr/encashment',
    label: 'Leave encashment',
    icon: Icons.event_busy_outlined,
    selectedIcon: Icons.event_busy,
    permission: Perm.payrollView,
  ),
  NavEntry(
    path: '/hr/shifts',
    label: 'Shifts and overtime',
    icon: Icons.schedule_outlined,
    selectedIcon: Icons.schedule,
    permission: Perm.payrollView,
  ),
  NavEntry(
    path: '/hr/fnf',
    label: 'Full and final',
    icon: Icons.exit_to_app_outlined,
    selectedIcon: Icons.exit_to_app,
    permission: Perm.payrollView,
  ),
  NavEntry(
    path: '/my-pay',
    label: 'My pay and leave',
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long,
    permission: Perm.payrollSelf,
  ),
];

List<RouteBase> hrRoutes() => [
  GoRoute(path: '/hr', pageBuilder: (_, s) => sectionPage(s, const HrHomeScreen())),
  GoRoute(path: '/hr/employees', pageBuilder: (_, s) => sectionPage(s, const EmployeesScreen())),
  GoRoute(
    path: '/hr/employees/:id',
    builder: (_, s) => EmployeeFileScreen(
      key: ValueKey(s.pathParameters['id']),
      employeeId: s.pathParameters['id']!,
    ),
  ),
  GoRoute(path: '/hr/setup', pageBuilder: (_, s) => sectionPage(s, const HrSetupScreen())),
  GoRoute(path: '/hr/attendance', pageBuilder: (_, s) => sectionPage(s, const AttendanceScreen())),
  GoRoute(path: '/leave', pageBuilder: (_, s) => sectionPage(s, const LeaveScreen())),
  GoRoute(path: '/payroll', pageBuilder: (_, s) => sectionPage(s, const PayrollScreen())),
  GoRoute(
    path: '/payroll/:id',
    builder: (_, s) => PayrollRunScreen(
      key: ValueKey(s.pathParameters['id']),
      runId: s.pathParameters['id']!,
    ),
  ),
  GoRoute(
    path: '/payslip/:id',
    builder: (_, s) => PayslipScreen(
      key: ValueKey(s.pathParameters['id']),
      payslipId: s.pathParameters['id']!,
    ),
  ),
  GoRoute(path: '/hr/statutory', pageBuilder: (_, s) => sectionPage(s, const StatutorySettingsScreen())),
  GoRoute(path: '/hr/gratuity', pageBuilder: (_, s) => sectionPage(s, const GratuityScreen())),
  GoRoute(path: '/hr/gratuity-provision', pageBuilder: (_, s) => sectionPage(s, const GratuityProvisionScreen())),
  GoRoute(path: '/hr/bonus', pageBuilder: (_, s) => sectionPage(s, const BonusScreen())),
  GoRoute(path: '/hr/encashment', pageBuilder: (_, s) => sectionPage(s, const EncashmentScreen())),
  GoRoute(path: '/hr/shifts', pageBuilder: (_, s) => sectionPage(s, const ShiftsScreen())),
  GoRoute(path: '/hr/fnf', pageBuilder: (_, s) => sectionPage(s, const FnfListScreen())),
  GoRoute(
    path: '/hr/fnf/:id',
    builder: (_, s) => FnfScreen(key: ValueKey(s.pathParameters['id']), id: s.pathParameters['id']!),
  ),
  GoRoute(path: '/my-pay', pageBuilder: (_, s) => sectionPage(s, const MyPayScreen())),
];
