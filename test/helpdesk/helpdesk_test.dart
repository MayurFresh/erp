import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/helpdesk/helpdesk_models.dart';
import 'package:onematrix/features/helpdesk/helpdesk_routes.dart';

import 'hd_harness.dart';

const _perms = {
  'helpdesk.view',
  'helpdesk.manage',
  'helpdesk.settings',
  'service_contracts.view',
  'service_contracts.manage',
};

Map<String, Object?> ticket(String id, {bool breached = false}) => {
  'id': id,
  'number': 'TKT/26-27/0000$id',
  'partyId': 'p1',
  'partyName': 'Acme Ltd',
  'subject': 'Printer is down',
  'description': 'Paper jam every page',
  'channel': 'phone',
  'category': 'Hardware',
  'priority': 'high',
  'status': 'open',
  'serialNo': 'SN-100',
  'contractId': 'c1',
  'contractNumber': 'AMC/26-27/00001',
  'covered': true,
  'assigneeId': null,
  'assigneeName': null,
  'response': {'state': 'met', 'minutesLeft': null},
  'resolution': breached
      ? {'state': 'breached', 'minutesLeft': -135}
      : {'state': 'pending', 'minutesLeft': 130},
  'updatedAt': '2026-11-16T10:00:00.000Z',
  'messages': [
    {
      'id': 'm1',
      'kind': 'reply',
      'body': 'We are on it',
      'author': {'id': 'u1', 'name': 'Asha'},
      'createdAt': '2026-11-16T10:05:00.000Z',
    },
    {
      'id': 'm2',
      'kind': 'note',
      'body': 'Spare roller in stock',
      'author': {'id': 'u1', 'name': 'Asha'},
      'createdAt': '2026-11-16T10:06:00.000Z',
    },
  ],
};

Map<String, Object?> contract({String status = 'active'}) => {
  'id': 'c1',
  'number': 'AMC/26-27/00001',
  'partyName': 'Acme Ltd',
  'title': 'Server AMC',
  'startDate': '2026-11-01',
  'endDate': '2027-10-31',
  'value': 12000,
  'billing': 'periodic',
  'billFrequency': 'quarterly',
  'visitFrequency': 'quarterly',
  'status': status,
  'daysLeft': 349,
  'renewalDue': false,
  'billedAmount': 3000,
  'assets': [
    {'serialNo': 'SN-100', 'description': 'Rack server'},
  ],
  'visits': [
    {
      'id': 'v1',
      'contractId': 'c1',
      'contractNumber': 'AMC/26-27/00001',
      'partyName': 'Acme Ltd',
      'dueDate': '2027-02-01',
      'status': 'scheduled',
      'overdue': false,
    },
  ],
  'bills': [
    {
      'period': '2026-11-01',
      'invoiceId': 'i1',
      'number': 'INV/26-27/00001',
      'amount': 3000,
    },
  ],
  'links': <Object?>[],
};

(int, Object?)? _handle(dynamic o) {
  final key = '${o.method} ${o.path}';
  switch (key) {
    case 'GET /helpdesk/tickets':
      return (
        200,
        {
          'data': [ticket('1'), ticket('2', breached: true)],
          'total': 2,
        },
      );
    case 'GET /helpdesk/tickets/1':
      return (200, ticket('1'));
    case 'GET /helpdesk/staff':
      return (
        200,
        {
          'data': [
            {'id': 'u1', 'name': 'Asha'},
          ],
        },
      );
    case 'POST /helpdesk/tickets/1/messages':
      return (201, ticket('1'));
    case 'POST /helpdesk/tickets/1/status':
      return (200, ticket('1'));
    case 'GET /service-contracts':
      return (
        200,
        {
          'data': [contract()],
          'total': 1,
        },
      );
    case 'GET /service-contracts/c1':
      return (200, contract());
    case 'GET /service-contracts/visits':
      return (
        200,
        {
          'data': [(contract()['visits'] as List).first],
        },
      );
  }
  return null;
}

void main() {
  group('models', () {
    test('countdown text', () {
      expect(slaText(const SlaState('pending', 130)), '2h 10m left');
      expect(slaText(const SlaState('pending', 45)), '45m left');
      expect(slaText(const SlaState('breached', -1530)), '1d 1h late');
      expect(slaText(const SlaState('met', null)), 'Met');
    });

    test('ticket and contract parse', () {
      final t = Ticket.fromJson(ticket('1', breached: true));
      expect(t.breached, isTrue);
      expect(t.isOpen, isTrue);
      expect(t.covered, isTrue);
      expect(t.messages.map((m) => m.kind), ['reply', 'note']);
      final c = Contract.fromJson(contract());
      expect(c.assets.single.label, 'S/N SN-100, Rack server');
      expect(c.visits.single.status, 'scheduled');
      expect(c.bills, hasLength(1));
    });
  });

  for (final w in [320.0, 1200.0]) {
    final size = Size(w, 900);
    testWidgets('ticket list at ${w.toInt()}px', (tester) async {
      await bootHd(
        tester,
        size,
        routes: helpdeskRoutes(),
        initial: '/helpdesk',
        extraPermissions: _perms,
        handler: _handle,
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Printer is down'), findsNWidgets(2));
      expect(find.text('Resolve: 2h 10m left'), findsOneWidget);
      expect(find.text('Resolve: 2h 15m late'), findsOneWidget);
      expect(find.text('New ticket'), findsOneWidget);
    });
  }

  testWidgets('ticket detail shows the conversation and sends a reply', (
    tester,
  ) async {
    final b = await bootHd(
      tester,
      const Size(390, 900),
      routes: helpdeskRoutes(),
      initial: '/helpdesk/1',
      extraPermissions: _perms,
      handler: _handle,
    );
    expect(find.text('Paper jam every page'), findsOneWidget);
    expect(find.text('We are on it'), findsOneWidget);
    expect(find.textContaining('Internal note'), findsWidgets);
    expect(find.text('Covered by contract AMC/26-27/00001'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField).last,
      'Engineer visits today',
    );
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    final sent = b.last('POST', '/helpdesk/tickets/1/messages')!;
    expect(sent.data, {'kind': 'reply', 'body': 'Engineer visits today'});
    await tester.tap(find.text('Mark resolved'));
    await tester.pumpAndSettle();
    expect(b.last('POST', '/helpdesk/tickets/1/status')!.data, {
      'status': 'resolved',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('view-only user cannot write', (tester) async {
    await bootHd(
      tester,
      const Size(390, 900),
      routes: helpdeskRoutes(),
      initial: '/helpdesk/1',
      extraPermissions: {'helpdesk.view'},
      handler: _handle,
    );
    expect(find.text('Send'), findsNothing);
    expect(find.text('Mark resolved'), findsNothing);
  });

  testWidgets('contract list and detail', (tester) async {
    final b = await bootHd(
      tester,
      const Size(320, 900),
      routes: helpdeskRoutes(),
      initial: '/service-contracts',
      extraPermissions: _perms,
      handler: _handle,
    );
    expect(find.textContaining('Server AMC'), findsOneWidget);
    await tester.tap(find.textContaining('Server AMC'));
    await tester.pumpAndSettle();
    expect(find.text('Covered items'), findsOneWidget);
    expect(find.text('S/N SN-100, Rack server'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Log visit'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Log visit'), findsOneWidget);
    await tester.tap(find.text('Log visit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark done'));
    await tester.pumpAndSettle();
    expect(b.last('POST', '/service-contracts/visits/v1/complete'), isNotNull);
  });

  testWidgets('visit calendar lists the month', (tester) async {
    await bootHd(
      tester,
      const Size(390, 900),
      routes: helpdeskRoutes(),
      initial: '/service-contracts/visits',
      extraPermissions: _perms,
      handler: _handle,
    );
    expect(find.textContaining('Acme Ltd'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
