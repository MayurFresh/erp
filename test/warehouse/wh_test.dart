import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_backend.dart';
import 'wh_harness.dart';

const _sizes = [Size(390, 844), Size(1440, 900)];

void main() {
  for (final size in _sizes) {
    final w = size.width.toInt();

    testWidgets('stock by bin and batch at ${w}px', (tester) async {
      final h = await bootWh(tester, size);
      expect(find.text('Warehouse stock'), findsWidgets);
      expect(find.textContaining('B-101'), findsWidgets);
      expect(find.textContaining('xpired'), findsWidgets);
      expect(
        h.backend.last('GET', '/warehouse/stock').queryParameters['locationId'],
        'l1',
      );
      h.expectClean('stock at $w');
    });

    testWidgets('bins list shows capacity and quarantine at ${w}px', (
      tester,
    ) async {
      final h = await bootWh(tester, size, initial: '/warehouse/bins');
      expect(find.textContaining('A-01'), findsWidgets);
      expect(find.textContaining('40 of 100'), findsOneWidget);
      expect(find.textContaining('Quarantine'), findsWidgets);
      h.expectClean('bins at $w');
    });

    testWidgets('serials list at ${w}px', (tester) async {
      final h = await bootWh(tester, size, initial: '/warehouse/serials');
      expect(find.text('MG-0001'), findsOneWidget);
      expect(find.textContaining('Bin A-01'), findsOneWidget);
      expect(find.textContaining('Issued'), findsWidgets);
      h.expectClean('serials at $w');
    });

    testWidgets('expiry report at ${w}px', (tester) async {
      final h = await bootWh(tester, size, initial: '/warehouse/expiry');
      expect(find.text('Due in 60 days'), findsOneWidget);
      expect(find.textContaining('B-099'), findsWidgets);
      await tester.tap(find.text('Due in 90 days'));
      await tester.pumpAndSettle();
      expect(
        h.backend.last('GET', '/warehouse/expiry').queryParameters['days'],
        90,
      );
      h.expectClean('expiry at $w');
    });

    testWidgets('pick list suggests and confirms at ${w}px', (tester) async {
      final h = await bootWh(tester, size, initial: '/warehouse/pick');
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Portland Cement').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Quantity needed'),
        '12',
      );
      await tester.tap(find.text('Suggest pick'));
      await tester.pumpAndSettle();
      expect(find.text('Take in this order'), findsOneWidget);
      expect(
        h.backend.last('GET', '/warehouse/fefo').queryParameters['qty'],
        12,
      );
      await tester.ensureVisible(find.text('Confirm pick'));
      await tester.tap(find.text('Confirm pick'));
      await tester.pumpAndSettle();
      final body = h.backend.last('POST', '/warehouse/picks').data as Map;
      expect((body['lines'] as List).first['qty'], 12.0);
      await tester.ensureVisible(find.text('Make invoice'));
      await tester.tap(find.text('Make invoice'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Mumbai Infra').first);
      await tester.pumpAndSettle();
      expect(
        (h.backend.last('POST', '/warehouse/picks/r1/invoice').data
            as Map)['partyId'],
        isNotNull,
      );
      expect(find.text('Invoice INV-26-0001'), findsOneWidget);
      expect(find.text('Make invoice'), findsNothing);
      h.expectClean('pick at $w');
    });

    testWidgets('settings save at ${w}px', (tester) async {
      final h = await bootWh(tester, size, initial: '/warehouse/settings');
      await tester.tap(find.text('Block expired stock'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      final body = h.backend.last('PATCH', '/warehouse/settings').data as Map;
      expect(body['blockExpired'], false);
      expect(body['expiryWarnDays'], 90);
      h.expectClean('settings at $w');
    });
  }

  testWidgets('item rule saves tracking and default bin', (tester) async {
    final h = await bootWh(
      tester,
      const Size(390, 800),
      initial: '/warehouse/rules',
    );
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Portland Cement').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not tracked'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Track by batch and expiry').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Shelf life in days (optional)'),
      '365',
    );
    await tester.tap(find.text('None'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('A-01').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save rule'));
    await tester.tap(find.text('Save rule'));
    await tester.pumpAndSettle();
    final req = h.backend.calls.lastWhere(
      (r) => r.method == 'PATCH' && r.path.startsWith('/warehouse/items/'),
    );
    final body = req.data as Map;
    expect(body['tracking'], 'batch');
    expect(body['shelfLifeDays'], 365);
    expect(body['defaultBinId'], 'b1');
    h.expectClean('item rule');
  });

  testWidgets('new bin sends the right body', (tester) async {
    final h = await bootWh(
      tester,
      const Size(1440, 900),
      initial: '/warehouse/bins',
    );
    await tester.tap(find.text('New bin'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(
      h.backend.count('POST', '/warehouse/bins'),
      0,
      reason: 'code is required',
    );
    await tester.enterText(find.widgetWithText(TextFormField, 'Code'), 'C-07');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Capacity (optional)'),
      '250',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    final body = h.backend.last('POST', '/warehouse/bins').data as Map;
    expect(body['code'], 'C-07');
    expect(body['capacityQty'], 250.0);
    expect(body['locationId'], 'l1');
    h.expectClean('new bin');
  });

  testWidgets('put away moves unassigned stock into a bin', (tester) async {
    final h = await bootWh(tester, const Size(1440, 900));
    await tester.tap(find.widgetWithText(FilledButton, 'Put away'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Portland Cement').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('To bin'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('A-01').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantity'),
      '15',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Put away').last);
    await tester.pumpAndSettle();
    final body = h.backend.last('POST', '/warehouse/putaway').data as Map;
    expect(body['toBinId'], 'b1');
    expect(body['qty'], 15.0);
    expect(body.containsKey('fromBinId'), false);
    h.expectClean('putaway');
  });

  testWidgets('read-only user sees no write buttons', (tester) async {
    await bootWh(
      tester,
      const Size(390, 844),
      permissions: {...FakeBackend.allPermissions}
        ..removeAll({'warehouse.pick', 'warehouse.manage'}),
    );
    expect(find.text('Receive'), findsNothing);
    expect(find.text('Put away'), findsNothing);
  });
}
