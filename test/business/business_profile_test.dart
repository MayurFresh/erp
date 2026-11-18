import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/business_profile.dart';
import 'package:onematrix/core/money.dart';
import 'package:onematrix/core/permissions.dart';
import 'package:onematrix/features/settings/role_matrix.dart';
import 'package:onematrix/features/shell/nav.dart';

PermissionSet _everything() => PermissionSet({
  for (final g in navGroups)
    for (final e in g.entries) ...[e.permission, ?e.createPermission],
});

Set<String> _paths(BusinessProfile profile) => {
  for (final g in visibleNavGroups(_everything(), profile: profile))
    for (final e in g.entries) e.path,
};

void main() {
  tearDown(configureMoney);

  group('module filtering', () {
    test('no profile keeps every section', () {
      final all = _paths(BusinessProfile.standard);
      expect(all, contains('/invoices'));
      expect(all, contains('/stock'));
    });

    test('a disabled module vanishes from the menu and its routes', () {
      const profile = BusinessProfile(
        enabledModules: ['sales', 'accounting', 'reports'],
      );
      final paths = _paths(profile);
      expect(paths, contains('/invoices'));
      expect(paths.any((p) => p.startsWith('/purchases')), isFalse);
      expect(moduleAllows('/invoices', profile), isTrue);
      expect(moduleAllows('/purchases', profile), isFalse);
      expect(moduleAllows('/items', profile), isTrue);
    });

    test('India-only modules are off outside India', () {
      const profile = BusinessProfile(country: 'US', currency: 'USD');
      expect(profile.hasModule('gst'), isFalse);
      expect(profile.hasModule('tds'), isFalse);
      expect(profile.hasModule('sales'), isTrue);
    });

    test('solo hides the menu extras', () {
      const profile = BusinessProfile(plan: 'solo');
      expect(profile.simplifiedMenu, isTrue);
      final paths = _paths(profile);
      expect(paths, isNot(contains('/roles')));
      expect(paths, isNot(contains('/users')));
    });
  });

  group('terms', () {
    test('defaults and custom words', () {
      const profile = BusinessProfile(terms: {'customer': 'Patient'});
      expect(profile.term('customer'), 'Patient');
      expect(profile.term('customer', plural: true), 'Patients');
      expect(profile.termLower('customer'), 'patient');
      expect(profile.term('vendor'), 'Vendor');
    });

    test('pluralize', () {
      expect(pluralize('Delivery'), 'Deliveries');
      expect(pluralize('Day'), 'Days');
      expect(pluralize('Branch'), 'Branches');
      expect(pluralize('Class'), 'Classes');
      expect(pluralize('Sales'), 'Sales');
      expect(pluralize('Service or medicine'), 'Services or medicines');
      expect(pluralize('Item or process'), 'Items or processes');
      expect(menuWord('Services or medicines'), 'Services');
      expect(menuWord('Patients'), 'Patients');
      expect(pluralize(''), '');
    });
  });

  group('money', () {
    test('USD and INR', () {
      configureMoney(currency: 'USD', locale: 'en_US');
      expect(formatMoney(1234567.5), r'$1,234,567.50');
      configureMoney();
      expect(formatMoney(1234567.5), '₹12,34,567.50');
      expect(moneyCurrency, 'INR');
    });
  });

  group('permission matrix', () {
    test('classifies keys into columns', () {
      expect(matrixColumnOf('invoices.view'), 0);
      expect(matrixColumnOf('items.view_cost'), 0);
      expect(matrixColumnOf('invoices.create'), 1);
      expect(matrixColumnOf('items.edit'), 2);
      expect(matrixColumnOf('payments.cancel'), 3);
      expect(matrixColumnOf('roles.manage'), 4);
    });
  });
}
