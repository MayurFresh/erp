import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/permissions.dart';
import 'package:progen_erp/features/auth/session.dart';
import 'package:progen_erp/features/shell/nav.dart';
import 'package:progen_erp/router.dart';

import '../support/fixtures.dart';

void main() {
  group('PermissionSet', () {
    const perms = PermissionSet({Perm.itemsView, Perm.invoicesCreate});

    test('can / canAny', () {
      expect(perms.can(Perm.itemsView), isTrue);
      expect(perms.can(Perm.itemsViewCost), isFalse);
      expect(perms.canAny([Perm.auditView, Perm.invoicesCreate]), isTrue);
      expect(PermissionSet.none.can(Perm.itemsView), isFalse);
    });

    test('equality ignores order', () {
      expect(
        const PermissionSet({'a', 'b'}),
        equals(const PermissionSet({'b', 'a'})),
      );
      expect(
        const PermissionSet({'a'}),
        isNot(equals(const PermissionSet({'b'}))),
      );
    });
  });

  group('SessionState', () {
    test('permissions come from the active company', () {
      final session = SessionState(
        me: signedIn(
          {Perm.itemsView},
          extra: [
            membership(
              {Perm.stockView},
              id: 'c2',
              name: 'Other',
              locationIds: ['l1'],
            ),
          ],
        ).me,
        activeCompanyId: 'c2',
      );
      expect(session.company!.name, 'Other');
      expect(session.can(Perm.stockView), isTrue);
      expect(session.can(Perm.itemsView), isFalse);
      expect(session.locationIds, ['l1']);
    });

    test('falls back to the first company and to no permissions', () {
      final session = SessionState(
        me: signedIn({Perm.itemsView}).me,
        activeCompanyId: 'gone',
      );
      expect(session.company!.id, 'c1');
      expect(session.locationIds, isNull);
      expect(SessionState.signedOut.can(Perm.itemsView), isFalse);
      expect(SessionState.signedOut.isSignedIn, isFalse);
    });
  });

  group('navigation', () {
    test('menu shows only permitted sections', () {
      final labels = visibleNavEntries(
        const PermissionSet({Perm.itemsView, Perm.stockView}),
      ).map((e) => e.label);
      expect(labels, ['Items', 'Stock']);
    });

    test('groups hide when empty and keep their order', () {
      final groups = visibleNavGroups(
        const PermissionSet({
          Perm.auditView,
          Perm.paymentsView,
          Perm.itemsView,
        }),
      );
      expect(groups.map((g) => g.label), [
        'Sales',
        'Purchases',
        'Inventory',
        'Administration',
      ]);
      // payments.view opens both Receipts (Sales) and Payments (Purchases).
      expect(groups.first.entries.single.label, 'Receipts');
      expect(groups[1].entries.single.label, 'Payments');
      expect(visibleNavGroups(PermissionSet.none), isEmpty);
    });

    test('every entry path is unique', () {
      final paths = [
        for (final g in navGroups)
          for (final e in g.entries) e.path,
      ];
      expect(paths.toSet(), hasLength(paths.length));
    });

    test('home is the first permitted section', () {
      expect(
        homePath(const PermissionSet({Perm.dashboardView, Perm.itemsView})),
        '/dashboard',
      );
      expect(homePath(const PermissionSet({Perm.stockView})), '/stock');
      expect(homePath(PermissionSet.none), '/no-access');
    });

    test('route permissions', () {
      expect(requiredPermission('/items'), Perm.itemsView);
      expect(requiredPermission('/items/abc'), Perm.itemsView);
      expect(requiredPermission('/items/new'), Perm.itemsCreate);
      expect(requiredPermission('/invoices/new'), Perm.invoicesCreate);
      expect(requiredPermission('/users/new'), Perm.usersManage);
      expect(requiredPermission('/no-access'), isNull);
      expect(requiredPermission('/stock/moves'), Perm.stockView);
      expect(requiredPermission('/purchases/new'), Perm.purchasesCreate);
      expect(requiredPermission('/purchases/p1'), Perm.purchasesView);
      expect(requiredPermission('/receipts/new'), Perm.paymentsCreate);
      expect(requiredPermission('/payments/x'), Perm.paymentsView);
      expect(requiredPermission('/credit-notes/new'), Perm.creditNotesCreate);
      expect(requiredPermission('/transfers/t1'), Perm.transfersView);
      expect(requiredPermission('/expenses/new'), Perm.expensesCreate);
      expect(requiredPermission('/parties/p1/edit'), Perm.partiesView);
    });
  });

  group('sessionRedirect', () {
    final owner = AsyncData(signedIn({Perm.dashboardView, Perm.itemsView}));
    const signedOut = AsyncData(SessionState.signedOut);

    String? go(AsyncValue<SessionState> s, String location) =>
        sessionRedirect(s, Uri.parse(location));

    test('shows the splash while restoring', () {
      expect(go(const AsyncLoading(), '/'), '/splash');
      expect(
        go(const AsyncLoading(), '/items/1'),
        '/splash?from=${Uri.encodeComponent('/items/1')}',
      );
      expect(go(const AsyncLoading(), '/splash'), isNull);
    });

    test('signed out users go to login', () {
      expect(go(signedOut, '/'), '/login');
      expect(go(signedOut, '/login'), isNull);
      expect(go(signedOut, '/signup'), isNull);
      expect(
        go(signedOut, '/items'),
        '/login?from=${Uri.encodeComponent('/items')}',
      );
    });

    test('signed in users leave auth pages and blocked routes', () {
      expect(go(owner, '/login'), '/dashboard');
      expect(go(owner, '/'), '/dashboard');
      expect(go(owner, '/login?from=%2Fitems'), '/items');
      expect(go(owner, '/items'), isNull);
      expect(go(owner, '/users'), '/dashboard');
      expect(go(owner, '/items/new'), '/dashboard');
    });
  });
}
