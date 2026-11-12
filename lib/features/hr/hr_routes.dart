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
  GoRoute(path: '/my-pay', pageBuilder: (_, s) => sectionPage(s, const MyPayScreen())),
];
