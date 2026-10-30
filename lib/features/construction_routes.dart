/// Routes and menu entries of the construction pack (API v1.2).
///
/// Wire-up (lead engineer): add `...constructionRoutes()` to the routes of
/// the authenticated `ShellRoute` in `router.dart`, and
/// `NavGroup('Construction', constructionNavEntries)` to `navGroups` in
/// `nav.dart`. Route permissions then follow from the entries: `<path>` and
/// anything under it need [NavEntry.permission], `<path>/new` needs
/// [NavEntry.createPermission]. Screens also check their own finer
/// permissions (e.g. `/projects/:id/edit` needs `projects.manage`).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'construction/common/c_perms.dart';
import 'construction/dprs/dpr_detail_screen.dart';
import 'construction/dprs/dpr_form_screen.dart';
import 'construction/dprs/dprs_screen.dart';
import 'construction/indents/indent_detail_screen.dart';
import 'construction/indents/indent_form_screen.dart';
import 'construction/indents/indents_screen.dart';
import 'construction/labour/advance_detail_screen.dart';
import 'construction/labour/advance_form_screen.dart';
import 'construction/labour/advances_screen.dart';
import 'construction/labour/attendance_screen.dart';
import 'construction/labour/wage_detail_screen.dart';
import 'construction/labour/wage_form_screen.dart';
import 'construction/labour/wages_screen.dart';
import 'construction/labour/worker_detail_screen.dart';
import 'construction/labour/worker_form_screen.dart';
import 'construction/labour/workers_screen.dart';
import 'construction/material/issue_detail_screen.dart';
import 'construction/material/issue_form_screen.dart';
import 'construction/material/issues_screen.dart';
import 'construction/projects/project_detail_screen.dart';
import 'construction/projects/project_form_screen.dart';
import 'construction/projects/projects_screen.dart';
import 'construction/subcontracts/ra_bill_detail_screen.dart';
import 'construction/subcontracts/ra_bill_form_screen.dart';
import 'construction/subcontracts/ra_bills_screen.dart';
import 'construction/subcontracts/work_order_detail_screen.dart';
import 'construction/subcontracts/work_order_form_screen.dart';
import 'construction/subcontracts/work_orders_screen.dart';
import 'shell/nav.dart';
import 'shell/routing.dart';

/// Menu group "Construction", in order.
const List<NavEntry> constructionNavEntries = [
  NavEntry(
    path: '/projects',
    label: 'Projects',
    icon: Icons.apartment_outlined,
    selectedIcon: Icons.apartment,
    permission: CPerm.projectsView,
    createPermission: CPerm.projectsManage,
  ),
  NavEntry(
    path: '/dprs',
    label: 'Progress reports',
    icon: Icons.today_outlined,
    selectedIcon: Icons.today,
    permission: CPerm.dprView,
    createPermission: CPerm.dprCreate,
  ),
  NavEntry(
    path: '/attendance',
    label: 'Attendance',
    icon: Icons.how_to_reg_outlined,
    selectedIcon: Icons.how_to_reg,
    // GET /attendance needs labour.view; saving needs attendance.mark,
    // which the screen checks.
    permission: CPerm.labourView,
  ),
  NavEntry(
    path: '/indents',
    label: 'Indents',
    icon: Icons.playlist_add_check_outlined,
    selectedIcon: Icons.playlist_add_check,
    permission: CPerm.indentsView,
    createPermission: CPerm.indentsCreate,
  ),
  NavEntry(
    path: '/issues',
    label: 'Material issues',
    icon: Icons.outbox_outlined,
    selectedIcon: Icons.outbox,
    permission: CPerm.consumptionView,
    createPermission: CPerm.consumptionCreate,
  ),
  NavEntry(
    path: '/workers',
    label: 'Workers',
    icon: Icons.engineering_outlined,
    selectedIcon: Icons.engineering,
    permission: CPerm.labourView,
    createPermission: CPerm.labourManage,
  ),
  NavEntry(
    path: '/wage-sheets',
    label: 'Wage sheets',
    icon: Icons.payments_outlined,
    selectedIcon: Icons.payments,
    permission: CPerm.wagesView,
    createPermission: CPerm.wagesManage,
  ),
  NavEntry(
    path: '/labour-advances',
    label: 'Labour advances',
    icon: Icons.savings_outlined,
    selectedIcon: Icons.savings,
    permission: CPerm.wagesView,
    createPermission: CPerm.wagesPay,
  ),
  NavEntry(
    path: '/work-orders',
    label: 'Work orders',
    icon: Icons.handyman_outlined,
    selectedIcon: Icons.handyman,
    permission: CPerm.subcontractsView,
    createPermission: CPerm.subcontractsManage,
  ),
  NavEntry(
    path: '/ra-bills',
    label: 'RA bills',
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long,
    permission: CPerm.subcontractsView,
    createPermission: CPerm.subcontractsManage,
  ),
];

/// Routes to add inside the authenticated shell route.
///
/// Query parameters: `/projects/:id?tab=boq|costs|dprs|indents`,
/// `/indents?status=`, `/indents/new?locationId=`, `/issues/new?locationId=`,
/// `/dprs/new?locationId=&date=`, `/attendance?siteId=&date=`,
/// `/wage-sheets/new?siteId=`, `/labour-advances?workerId=`,
/// `/labour-advances/new?workerId=`, `/work-orders?status=`,
/// `/ra-bills/new?workOrderId=`.
List<RouteBase> constructionRoutes() => [
  GoRoute(
    path: '/projects',
    pageBuilder: (_, state) => sectionPage(state, const ProjectsScreen()),
    routes: [
      GoRoute(path: 'new', builder: (_, _) => const ProjectFormScreen()),
      GoRoute(
        path: ':id',
        builder: (_, state) => ProjectDetailScreen(
          key: queryKey(state),
          projectId: state.pathParameters['id']!,
          initialTab: state.uri.queryParameters['tab'],
        ),
        routes: [
          GoRoute(
            path: 'edit',
            builder: (_, state) =>
                ProjectFormScreen(projectId: state.pathParameters['id']),
          ),
        ],
      ),
    ],
  ),
  GoRoute(
    path: '/dprs',
    pageBuilder: (_, state) => sectionPage(state, const DprsScreen()),
    routes: [
      GoRoute(
        path: 'new',
        builder: (_, state) => DprFormScreen(
          key: queryKey(state),
          initialLocationId: state.uri.queryParameters['locationId'],
          initialDate: state.uri.queryParameters['date'],
        ),
      ),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            DprDetailScreen(dprId: state.pathParameters['id']!),
        routes: [
          GoRoute(
            path: 'edit',
            builder: (_, state) =>
                DprFormScreen(dprId: state.pathParameters['id']),
          ),
        ],
      ),
    ],
  ),
  GoRoute(
    path: '/attendance',
    pageBuilder: (_, state) => sectionPage(
      state,
      AttendanceScreen(
        key: queryKey(state),
        initialSiteId: state.uri.queryParameters['siteId'],
        initialDate: state.uri.queryParameters['date'],
      ),
    ),
  ),
  GoRoute(
    path: '/indents',
    pageBuilder: (_, state) => sectionPage(
      state,
      IndentsScreen(
        key: queryKey(state),
        initialStatus: state.uri.queryParameters['status'],
      ),
    ),
    routes: [
      GoRoute(
        path: 'new',
        builder: (_, state) => IndentFormScreen(
          key: queryKey(state),
          initialLocationId: state.uri.queryParameters['locationId'],
        ),
      ),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            IndentDetailScreen(indentId: state.pathParameters['id']!),
        routes: [
          GoRoute(
            path: 'edit',
            builder: (_, state) =>
                IndentFormScreen(indentId: state.pathParameters['id']),
          ),
        ],
      ),
    ],
  ),
  GoRoute(
    path: '/issues',
    pageBuilder: (_, state) => sectionPage(state, const IssuesScreen()),
    routes: [
      GoRoute(
        path: 'new',
        builder: (_, state) => IssueFormScreen(
          key: queryKey(state),
          initialLocationId: state.uri.queryParameters['locationId'],
        ),
      ),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            IssueDetailScreen(issueId: state.pathParameters['id']!),
      ),
    ],
  ),
  GoRoute(
    path: '/workers',
    pageBuilder: (_, state) => sectionPage(state, const WorkersScreen()),
    routes: [
      GoRoute(path: 'new', builder: (_, _) => const WorkerFormScreen()),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            WorkerDetailScreen(workerId: state.pathParameters['id']!),
        routes: [
          GoRoute(
            path: 'edit',
            builder: (_, state) =>
                WorkerFormScreen(workerId: state.pathParameters['id']),
          ),
        ],
      ),
    ],
  ),
  GoRoute(
    path: '/wage-sheets',
    pageBuilder: (_, state) => sectionPage(state, const WagesScreen()),
    routes: [
      GoRoute(
        path: 'new',
        builder: (_, state) => WageFormScreen(
          key: queryKey(state),
          initialSiteId: state.uri.queryParameters['siteId'],
        ),
      ),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            WageDetailScreen(wageSheetId: state.pathParameters['id']!),
      ),
    ],
  ),
  GoRoute(
    path: '/labour-advances',
    pageBuilder: (_, state) => sectionPage(
      state,
      AdvancesScreen(
        key: queryKey(state),
        initialWorkerId: state.uri.queryParameters['workerId'],
      ),
    ),
    routes: [
      GoRoute(
        path: 'new',
        builder: (_, state) => AdvanceFormScreen(
          key: queryKey(state),
          initialWorkerId: state.uri.queryParameters['workerId'],
        ),
      ),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            AdvanceDetailScreen(advanceId: state.pathParameters['id']!),
      ),
    ],
  ),
  GoRoute(
    path: '/work-orders',
    pageBuilder: (_, state) => sectionPage(
      state,
      WorkOrdersScreen(
        key: queryKey(state),
        initialStatus: state.uri.queryParameters['status'],
      ),
    ),
    routes: [
      GoRoute(path: 'new', builder: (_, _) => const WorkOrderFormScreen()),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            WorkOrderDetailScreen(workOrderId: state.pathParameters['id']!),
        routes: [
          GoRoute(
            path: 'edit',
            builder: (_, state) =>
                WorkOrderFormScreen(workOrderId: state.pathParameters['id']),
          ),
        ],
      ),
    ],
  ),
  GoRoute(
    path: '/ra-bills',
    pageBuilder: (_, state) => sectionPage(
      state,
      RaBillsScreen(
        key: queryKey(state),
        initialStatus: state.uri.queryParameters['status'],
      ),
    ),
    routes: [
      GoRoute(
        path: 'new',
        builder: (_, state) => RaBillFormScreen(
          key: queryKey(state),
          initialWorkOrderId: state.uri.queryParameters['workOrderId'],
        ),
      ),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            RaBillDetailScreen(billId: state.pathParameters['id']!),
        routes: [
          GoRoute(
            path: 'edit',
            builder: (_, state) =>
                RaBillFormScreen(billId: state.pathParameters['id']),
          ),
        ],
      ),
    ],
  ),
];
