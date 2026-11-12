/// Routes and menu entries of the clinic pack (API Wave 2, module `clinic`).
///
/// Wired in `router.dart` (`...clinicRoutes()`) and `nav.dart`
/// (`NavGroup('Patient care', clinicNavEntries)`).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'consultation_screen.dart';
import 'doctor_day_screen.dart';
import 'doctors_screen.dart';
import 'front_desk_screen.dart';
import 'ipd_board_screen.dart';
import 'ipd_setup_screen.dart';
import 'ipd_stay_screen.dart';
import 'patients_screen.dart';

const List<NavEntry> clinicNavEntries = [
  NavEntry(
    path: '/clinic',
    label: 'Front desk',
    icon: Icons.event_note_outlined,
    selectedIcon: Icons.event_note,
    permission: Perm.clinicView,
  ),
  NavEntry(
    path: '/clinic/patients',
    label: 'Patients',
    icon: Icons.groups_outlined,
    selectedIcon: Icons.groups,
    permission: Perm.clinicView,
  ),
  NavEntry(
    path: '/clinic/doctor',
    label: 'My day',
    icon: Icons.medical_services_outlined,
    selectedIcon: Icons.medical_services,
    permission: Perm.clinicConsult,
  ),
  NavEntry(
    path: '/clinic/ipd',
    label: 'Beds and admissions',
    icon: Icons.bed_outlined,
    selectedIcon: Icons.bed,
    permission: Perm.clinicIpd,
  ),
  NavEntry(
    path: '/clinic/doctors',
    label: 'Doctors',
    icon: Icons.badge_outlined,
    selectedIcon: Icons.badge,
    permission: Perm.clinicView,
  ),
];

List<RouteBase> clinicRoutes() => [
  GoRoute(
    path: '/clinic',
    pageBuilder: (_, state) => sectionPage(state, const FrontDeskScreen()),
    routes: [
      GoRoute(
        path: 'patients',
        pageBuilder: (_, state) => sectionPage(state, const PatientsScreen()),
        routes: [
          GoRoute(
            path: ':id',
            builder: (_, state) =>
                PatientScreen(patientId: state.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(
        path: 'doctor',
        pageBuilder: (_, state) => sectionPage(state, const DoctorDayScreen()),
      ),
      GoRoute(
        path: 'doctors',
        pageBuilder: (_, state) => sectionPage(state, const DoctorsScreen()),
      ),
      GoRoute(
        path: 'ipd',
        pageBuilder: (_, state) => sectionPage(state, const IpdBoardScreen()),
        routes: [
          GoRoute(
            path: 'setup',
            pageBuilder: (_, state) =>
                sectionPage(state, const IpdSetupScreen()),
          ),
          GoRoute(
            path: 'stays/:id',
            builder: (_, state) =>
                IpdStayScreen(admissionId: state.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(
        path: 'visits/:id',
        builder: (_, state) =>
            ConsultationScreen(visitId: state.pathParameters['id']!),
      ),
    ],
  ),
];
