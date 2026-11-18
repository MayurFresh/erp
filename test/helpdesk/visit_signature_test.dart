import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/helpdesk/helpdesk_models.dart';
import 'package:onematrix/features/helpdesk/helpdesk_routes.dart';
import 'package:onematrix/features/helpdesk/signature_pad.dart';

import 'hd_harness.dart';

const _perms = {
  'helpdesk.view',
  'helpdesk.manage',
  'service_contracts.view',
  'service_contracts.manage',
};

Map<String, Object?> _visit(String status) => {
  'id': 'v1',
  'contractId': 'c1',
  'contractNumber': 'AMC/26-27/00001',
  'partyName': 'Acme Ltd',
  'dueDate': '2027-02-01',
  'status': status,
  'overdue': false,
  'partsUsed': [
    {'name': 'Fan', 'qty': 2},
  ],
  'photoFileIds': ['f1'],
  'signatureFileId': 'f2',
  'signatureName': 'R. Shah',
};

Map<String, Object?> _contract(String visitStatus) => {
  'id': 'c1',
  'number': 'AMC/26-27/00001',
  'partyId': 'p1',
  'partyName': 'Acme Ltd',
  'title': 'Server AMC',
  'startDate': '2026-11-01',
  'endDate': '2027-10-31',
  'value': 12000,
  'billing': 'upfront',
  'visitFrequency': 'quarterly',
  'status': 'active',
  'daysLeft': 349,
  'renewalDue': false,
  'billedAmount': 0,
  'assets': <Object?>[],
  'visits': [_visit(visitStatus)],
  'bills': <Object?>[],
  'links': <Object?>[],
};

(int, Object?)? Function(dynamic) _handler(String visitStatus) => (o) {
  switch ('${o.method} ${o.path}') {
    case 'GET /service-contracts/c1':
      return (200, _contract(visitStatus));
    case 'POST /files':
      return (201, {'id': 'file-1'});
    case 'POST /service-contracts/visits/v1/complete':
      return (200, _visit('done'));
    case 'PATCH /service-contracts/visits/v1/parts':
      return (200, _visit('done'));
    case 'POST /service-contracts/visits/v1/cancel':
      return (200, _visit('cancelled'));
  }
  return null;
};

void main() {
  testWidgets('the pad draws, clears and makes a PNG', (tester) async {
    final c = SignatureController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 280, child: SignaturePad(controller: c)),
        ),
      ),
    );
    expect(c.isEmpty, isTrue);
    await tester.drag(
      find.byKey(const ValueKey('signature-pad')),
      const Offset(80, 30),
    );
    await tester.pump();
    expect(c.isEmpty, isFalse);
    final png = await tester.runAsync(c.toPng);
    expect(png, isNotNull);
    expect(png!.sublist(1, 4), utf8.encode('PNG'));
    c.clear();
    expect(c.isEmpty, isTrue);
  });

  testWidgets('a drawn signature is uploaded and sent with the visit', (
    tester,
  ) async {
    final b = await bootHd(
      tester,
      const Size(320, 900),
      routes: helpdeskRoutes(),
      initial: '/service-contracts/c1',
      extraPermissions: _perms,
      handler: _handler('scheduled'),
    );
    await tester.scrollUntilVisible(
      find.text('Log visit'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Log visit'));
    await tester.pumpAndSettle();
    expect(find.text('Customer signature'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('signature-pad')),
      const Offset(60, 20),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Customer name (signed by)'),
      'R. Shah',
    );
    await tester.tap(find.text('Mark done'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(b.last('POST', '/files'), isNotNull);
    final sent = b.last('POST', '/service-contracts/visits/v1/complete')!;
    final body = sent.data as Map;
    expect(body['signatureFileId'], 'file-1');
    expect(body['signatureName'], 'R. Shah');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'typed name alone still works, and a done visit can be cancelled',
    (tester) async {
      final b = await bootHd(
        tester,
        const Size(320, 900),
        routes: helpdeskRoutes(),
        initial: '/service-contracts/c1',
        extraPermissions: _perms,
        handler: _handler('done'),
      );
      await tester.scrollUntilVisible(
        find.text('Cancel visit'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Signed by R. Shah'), findsOneWidget);
      await tester.tap(find.text('Cancel visit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel visit').last);
      await tester.pumpAndSettle();
      expect(b.last('POST', '/service-contracts/visits/v1/cancel'), isNotNull);
    },
  );

  testWidgets('parts of a done visit can be edited', (tester) async {
    final b = await bootHd(
      tester,
      const Size(320, 900),
      routes: helpdeskRoutes(),
      initial: '/service-contracts/c1',
      extraPermissions: _perms,
      handler: _handler('done'),
    );
    await tester.scrollUntilVisible(
      find.text('Edit parts'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Edit parts'));
    await tester.pumpAndSettle();
    expect(find.text('Fan'), findsOneWidget);
    expect(find.text('Customer signature'), findsNothing);
    await tester.tap(find.byTooltip('Remove part'));
    await tester.pump();
    await tester.tap(find.text('Save parts'));
    await tester.pumpAndSettle();
    final body =
        b.last('PATCH', '/service-contracts/visits/v1/parts')!.data as Map;
    expect(body['partsUsed'], isEmpty);
    expect(tester.takeException(), isNull);
  });

  test('ticket reads the SLA pause flag', () {
    final t = Ticket.fromJson({
      'id': 't',
      'slaPaused': true,
      'status': 'waiting',
    });
    expect(t.slaPaused, isTrue);
  });
}
