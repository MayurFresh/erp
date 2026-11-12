import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/features/company/company_model.dart';
import 'package:progen_erp/features/manufacturing/bom_screen.dart'
    show PickerFieldBox;
import 'package:progen_erp/features/manufacturing/mfg_models.dart';
import 'package:progen_erp/features/manufacturing/mfg_pdf.dart';

import '../support/fake_backend.dart';
import 'mfg_harness.dart';

const _sizes = [Size(320, 700), Size(390, 844), Size(1440, 900)];

void main() {
  group('home', () {
    for (final size in _sizes) {
      testWidgets('shows counts and output at ${size.width.toInt()}px', (
        tester,
      ) async {
        final h = await bootMfg(tester, size);
        expect(find.text('Production'), findsWidgets);
        expect(find.text('In progress'), findsOneWidget);
        expect(find.text('7'), findsOneWidget);
        expect(find.text('Material short'), findsOneWidget);
        expect(find.textContaining('4 nos good'), findsOneWidget);
        h.expectClean('home at ${size.width}');
      });
    }
  });

  group('orders', () {
    for (final size in _sizes) {
      testWidgets('list opens an order at ${size.width.toInt()}px', (
        tester,
      ) async {
        final h = await bootMfg(tester, size, initial: '/manufacturing/orders');
        expect(find.textContaining('MO/26-27/0001'), findsOneWidget);
        await tester.tap(find.textContaining('MO/26-27/0001'));
        await tester.pumpAndSettle();
        expect(h.router.state.uri.path, '/manufacturing/orders/o1');
        expect(find.text('MS Sheet 18G'), findsWidgets);
        expect(find.text('Record output'), findsOneWidget);
        h.expectClean('order at ${size.width}');
      });
    }

    testWidgets('new order picks the item through the picker and posts', (
      tester,
    ) async {
      final h = await bootMfg(
        tester,
        const Size(390, 844),
        initial: '/manufacturing/orders',
      );
      await tester.tap(find.text('New order'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
      expect(
        h.backend.count('POST', '/manufacturing/orders'),
        0,
        reason: 'nothing chosen',
      );
      await tester.tap(find.byType(PickerFieldBox));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MS Sheet 18G'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Quantity'),
        '25',
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownMenuItem<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
      final body = h.backend.last('POST', '/manufacturing/orders').data as Map;
      expect(body['itemId'], 'i3');
      expect(body['qty'], 25.0);
      expect(body['locationId'], isNotNull);
      expect(h.router.state.uri.path, '/manufacturing/orders/o1');
      h.expectClean('new order');
    });

    testWidgets('issue and output send the right bodies', (tester) async {
      final h = await bootMfg(
        tester,
        const Size(1440, 900),
        initial: '/manufacturing/orders/o1',
      );
      expect(find.textContaining('Cost per nos'), findsOneWidget);
      expect(find.text('Material used against plan'), findsOneWidget);

      await tester.tap(find.text('Issue material'));
      await tester.pumpAndSettle();
      // The first line is prefilled with what is still to issue (100 kg).
      await tester.tap(find.widgetWithText(FilledButton, 'Issue'));
      await tester.pumpAndSettle();
      final issue =
          h.backend.last('POST', '/manufacturing/orders/o1/issue').data as Map;
      expect(issue['lines'], [
        {'itemId': 'r1', 'qty': 100.0},
      ]);

      await tester.tap(find.text('Record output'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save output'));
      await tester.pumpAndSettle();
      expect(
        h.backend.count('POST', '/manufacturing/orders/o1/output'),
        0,
        reason: 'empty quantity is refused',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Good quantity'),
        '3',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save output'));
      await tester.pumpAndSettle();
      expect(
        (h.backend.last('POST', '/manufacturing/orders/o1/output').data
            as Map)['goodQty'],
        3.0,
      );
      h.expectClean('order actions');
    });

    testWidgets('a viewer sees no action buttons', (tester) async {
      final h = await bootMfg(
        tester,
        const Size(390, 844),
        initial: '/manufacturing/orders/o1',
        permissions: {...FakeBackend.allPermissions, 'manufacturing.view'},
      );
      expect(find.text('MS Sheet 18G'), findsWidgets);
      expect(find.text('Record output'), findsNothing);
      expect(find.text('Issue material'), findsNothing);
      expect(find.text('Close order'), findsNothing);
      expect(find.text('Job sheet'), findsOneWidget);
      h.expectClean('viewer');
    });
  });

  group('bills of materials', () {
    testWidgets('new BOM picks the item, adds a component and saves', (
      tester,
    ) async {
      final h = await bootMfg(
        tester,
        const Size(1440, 900),
        initial: '/manufacturing/boms/new',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(
        h.backend.count('POST', '/manufacturing/boms'),
        0,
        reason: 'no item chosen',
      );
      await tester.tap(find.byType(PickerFieldBox).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Portland Cement 53 Grade 50kg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PickerFieldBox).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('MS Sheet 18G'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Quantity'),
        '5',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      final body = h.backend.last('POST', '/manufacturing/boms').data as Map;
      expect(body['itemId'], 'i1');
      expect(body['outputQty'], 1.0);
      expect((body['lines'] as List).single['itemId'], 'i3');
      expect((body['lines'] as List).single['qty'], 5.0);
      h.expectClean('new bom');
    });

    testWidgets('list shows versions', (tester) async {
      final h = await bootMfg(
        tester,
        const Size(390, 844),
        initial: '/manufacturing/boms',
      );
      expect(find.text('Steel Almirah'), findsOneWidget);
      expect(find.textContaining('Version 2'), findsOneWidget);
      h.expectClean('bom list');
    });

    for (final size in [const Size(390, 844), const Size(1440, 900)]) {
      testWidgets(
        'draft saves with the stale-edit stamp and explodes at ${size.width.toInt()}px',
        (tester) async {
          final h = await bootMfg(
            tester,
            size,
            initial: '/manufacturing/boms/b1',
          );
          expect(find.text('Components'), findsOneWidget);
          expect(find.text('By-products'), findsOneWidget);
          expect(find.textContaining('Standard cost'), findsOneWidget);

          await tester.tap(find.widgetWithText(FilledButton, 'Save'));
          await tester.pumpAndSettle();
          final body =
              h.backend.last('PATCH', '/manufacturing/boms/b1').data as Map;
          expect(body['expectedUpdatedAt'], '2026-11-12T09:00:00.000Z');
          expect((body['lines'] as List), hasLength(2));

          await tester.drag(
            find.byType(ListView).first,
            const Offset(0, -3000),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(OutlinedButton, 'Explode'));
          await tester.pumpAndSettle();
          expect(find.textContaining('40 in stock'), findsOneWidget);
          expect(find.textContaining('Short: MS Sheet 18G'), findsOneWidget);
          h.expectClean('bom');
        },
      );
    }
  });

  group('planning and job work', () {
    testWidgets('shortages can be selected for a purchase order', (
      tester,
    ) async {
      final h = await bootMfg(
        tester,
        const Size(390, 844),
        initial: '/manufacturing/planning',
      );
      expect(find.textContaining('Short 360'), findsOneWidget);
      final button = find.widgetWithText(
        FilledButton,
        'Create purchase order (0)',
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Create purchase order (1)'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Create purchase order'), findsOneWidget);
      h.expectClean('planning');
    });

    testWidgets('create-PO dialog posts vendor, location and quantity', (
      tester,
    ) async {
      final h = await bootMfg(
        tester,
        const Size(390, 844),
        initial: '/manufacturing/planning',
      );
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Create purchase order (1)'),
      );
      await tester.pumpAndSettle();
      // No vendor yet: nothing is sent.
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
      expect(h.backend.count('POST', '/manufacturing/mrp/purchase-order'), 0);
      await tester.tap(find.byType(PickerFieldBox));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bengaluru Steel Suppliers'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownMenuItem<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
      final body =
          h.backend.last('POST', '/manufacturing/mrp/purchase-order').data
              as Map;
      expect(body['partyId'], 'p2');
      expect(body['locationId'], isNotNull);
      expect(body['lines'], [
        {'itemId': 'r1', 'qty': 360.0},
      ]);
      h.expectClean('po dialog');
    });

    testWidgets('new challan can name a different item that comes back', (
      tester,
    ) async {
      final h = await bootMfg(
        tester,
        const Size(390, 844),
        initial: '/manufacturing/jobwork',
      );
      await tester.tap(find.text('New challan'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PickerFieldBox));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bengaluru Steel Suppliers'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownMenuItem<String>).first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(
          TextFormField,
          'Process (for example, powder coating)',
        ),
        'Coating',
      );
      await tester.tap(find.text('Add item'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Portland Cement 53 Grade 50kg'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Portland Cement 53 Grade 50kg'),
        '10',
      );
      await tester.tap(find.text('Comes back as the same item (change)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MS Sheet 18G'));
      await tester.pumpAndSettle();
      expect(find.text('Comes back as MS Sheet 18G (change)'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();
      final body = h.backend.last('POST', '/manufacturing/jobwork').data as Map;
      expect(body['lines'], [
        {'itemId': 'i1', 'qty': 10.0, 'returnItemId': 'i3'},
      ]);
      h.expectClean('challan');
    });

    testWidgets('challan list, receipt and the with-job-workers summary', (
      tester,
    ) async {
      final h = await bootMfg(
        tester,
        const Size(1440, 900),
        initial: '/manufacturing/jobwork',
      );
      expect(find.textContaining('Shree Coaters'), findsOneWidget);
      await tester.tap(find.text('With job workers'));
      await tester.pumpAndSettle();
      expect(find.text('Over a year'), findsOneWidget);
      await tester.tap(find.text('Challans'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('JWC/26-27/0001'));
      await tester.pumpAndSettle();
      expect(h.router.state.uri.path, '/manufacturing/jobwork/j1');
      await tester.tap(find.text('Receive goods'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      final body =
          h.backend.last('POST', '/manufacturing/jobwork/j1/receive').data
              as Map;
      expect(body['lines'], [
        {'lineId': 'jl1', 'qtyReceived': 10.0},
      ]);
      h.expectClean('job work');
    });

    testWidgets('setup saves overhead with PATCH', (tester) async {
      final h = await bootMfg(
        tester,
        const Size(1440, 900),
        initial: '/manufacturing/setup',
      );
      expect(find.text('Shear line'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Overhead'),
        '12',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(
        (h.backend.last('PATCH', '/manufacturing/settings').data
            as Map)['overheadPct'],
        12.0,
      );
      h.expectClean('setup');
    });
  });

  test('job sheet and challan PDFs build', () async {
    final order = MfgOrder.fromJson(mfgOrderJson());
    const company = Company(id: 'c1', name: 'Demo Works', stateCode: '27');
    final sheet = await buildJobSheetPdf(order, company);
    expect(String.fromCharCodes(sheet.take(4)), '%PDF');
    final challan = Challan.fromJson({
      'id': 'j1',
      'number': 'JWC/1',
      'status': 'open',
      'partyName': 'Shree Coaters',
      'locationName': 'Factory',
      'challanDate': '2026-11-01',
      'process': 'Powder coating',
      'ageDays': 3,
      'lines': [
        {
          'id': 'l',
          'name': 'Body',
          'unit': 'nos',
          'returnName': 'Coated body',
          'qtySent': 10,
          'qtyReceived': 0,
          'qtyScrap': 0,
          'qtyPending': 10,
        },
      ],
    });
    expect(challan.canReceive, isTrue);
    final pdf = await buildChallanPdf(challan, company);
    expect(String.fromCharCodes(pdf.take(4)), '%PDF');
  });
}
