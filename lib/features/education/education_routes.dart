/// Routes and menu entries of the school and coaching pack (API Wave 2,
/// module `education`).
///
/// Wired in `router.dart` (`...educationRoutes()`) and `nav.dart`
/// (`NavGroup('Students and fees', educationNavEntries)`).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'attendance_screen.dart';
import 'collect_screen.dart';
import 'demands_screen.dart';
import 'dues_screen.dart';
import 'education_home_screen.dart';
import 'exams_screen.dart';
import 'marks_screen.dart';
import 'results_screen.dart';
import 'setup_screen.dart';
import 'student_screen.dart';
import 'students_screen.dart';

const List<NavEntry> educationNavEntries = [
  NavEntry(
    path: '/education',
    label: 'Overview',
    icon: Icons.school_outlined,
    selectedIcon: Icons.school,
    permission: Perm.educationView,
  ),
  NavEntry(
    path: '/education/students',
    label: 'Students',
    icon: Icons.groups_outlined,
    selectedIcon: Icons.groups,
    permission: Perm.educationView,
  ),
  NavEntry(
    path: '/education/collect',
    label: 'Collect fee',
    icon: Icons.payments_outlined,
    selectedIcon: Icons.payments,
    permission: Perm.educationFees,
  ),
  NavEntry(
    path: '/education/dues',
    label: 'Dues',
    icon: Icons.pending_actions_outlined,
    selectedIcon: Icons.pending_actions,
    permission: Perm.educationFees,
  ),
  NavEntry(
    path: '/education/demands',
    label: 'Fee bills',
    icon: Icons.request_quote_outlined,
    selectedIcon: Icons.request_quote,
    permission: Perm.educationFees,
  ),
  NavEntry(
    path: '/education/attendance',
    label: 'Attendance',
    icon: Icons.fact_check_outlined,
    selectedIcon: Icons.fact_check,
    permission: Perm.educationAttendance,
  ),
  NavEntry(
    path: '/education/exams',
    label: 'Exams',
    icon: Icons.assignment_outlined,
    selectedIcon: Icons.assignment,
    permission: Perm.educationExams,
  ),
  NavEntry(
    path: '/education/setup',
    label: 'Classes and fee plans',
    icon: Icons.tune_outlined,
    selectedIcon: Icons.tune,
    permission: Perm.educationManage,
  ),
];

List<RouteBase> educationRoutes() => [
  GoRoute(
    path: '/education',
    pageBuilder: (_, state) => sectionPage(state, const EducationHomeScreen()),
    routes: [
      GoRoute(
        path: 'students',
        pageBuilder: (_, state) => sectionPage(state, const StudentsScreen()),
        routes: [
          GoRoute(
            path: ':id',
            builder: (_, state) =>
                StudentScreen(studentId: state.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(
        path: 'collect',
        pageBuilder: (_, state) => sectionPage(
          state,
          CollectScreen(
            key: ValueKey(state.uri.queryParameters['studentId']),
            studentId: state.uri.queryParameters['studentId'],
          ),
        ),
      ),
      GoRoute(
        path: 'dues',
        pageBuilder: (_, state) => sectionPage(state, const DuesScreen()),
      ),
      GoRoute(
        path: 'demands',
        pageBuilder: (_, state) => sectionPage(state, const DemandsScreen()),
      ),
      GoRoute(
        path: 'exams',
        pageBuilder: (_, state) => sectionPage(state, const ExamsScreen()),
        routes: [
          GoRoute(
            path: ':termId',
            builder: (_, state) =>
                ExamTermScreen(termId: state.pathParameters['termId']!),
            routes: [
              GoRoute(
                path: ':classId/marks',
                builder: (_, state) => MarksScreen(
                  termId: state.pathParameters['termId']!,
                  classId: state.pathParameters['classId']!,
                ),
              ),
              GoRoute(
                path: ':classId/results',
                builder: (_, state) => ResultsScreen(
                  termId: state.pathParameters['termId']!,
                  classId: state.pathParameters['classId']!,
                ),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: 'setup',
        pageBuilder: (_, state) =>
            sectionPage(state, const EducationSetupScreen()),
      ),
      GoRoute(
        path: 'attendance',
        pageBuilder: (_, state) =>
            sectionPage(state, const AttendanceListScreen()),
        routes: [
          GoRoute(
            path: ':classId',
            builder: (_, state) =>
                AttendanceMarkScreen(classId: state.pathParameters['classId']!),
            routes: [
              GoRoute(
                path: 'sheet',
                builder: (_, state) => AttendanceSheetScreen(
                  classId: state.pathParameters['classId']!,
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  ),
];
