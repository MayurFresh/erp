import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/parties/contact_model.dart';
import 'package:onematrix/features/parties/contacts_section.dart';

import 'quotation_fixtures.dart';

void main() {
  test('contact JSON parses', () {
    final c = ContactPerson.fromJson(contactJson());
    expect(c.name, 'Meera Shah');
    expect(c.isPrimary, isTrue);
    expect(c.phone, '9876543210');
  });

  for (final size in [narrow, wide]) {
    final tag = '${size.width.toInt()}px';

    testWidgets('contacts list shows primary badge and buttons at $tag', (
      tester,
    ) async {
      final b = FakeControlsBackend()
        ..on('GET /parties/p1/contacts', {
          'data': [
            contactJson(),
            contactJson(id: 'c2', name: 'Anil Rao', primary: false),
          ],
        });
      await pumpRouted(
        tester,
        const ContactsSection(partyId: 'p1'),
        b,
        size: size,
      );
      expect(find.text('Meera Shah'), findsOneWidget);
      expect(find.text('Primary'), findsOneWidget);
      expect(find.byTooltip('Call Meera Shah'), findsOneWidget);
      expect(find.byTooltip('WhatsApp Anil Rao'), findsOneWidget);
      // A labelled button on wide screens, an icon button with the same tooltip on phones.
      expect(
        find.text('Add contact').evaluate().length +
            find.byTooltip('Add contact').evaluate().length,
        1,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('read-only users see no edit controls', (tester) async {
    final b = FakeControlsBackend()
      ..on('GET /parties/p1/contacts', {
        'data': [contactJson()],
      });
    await pumpRouted(
      tester,
      const ContactsSection(partyId: 'p1'),
      b,
      permissions: {'parties.view'},
    );
    expect(find.text('Add contact'), findsNothing);
    expect(find.byTooltip('Add contact'), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
  });

  testWidgets('add posts the contact with isPrimary', (tester) async {
    final b = FakeControlsBackend()
      ..on('GET /parties/p1/contacts', {'data': <Object?>[]})
      ..on('POST /parties/p1/contacts', contactJson(), status: 201);
    await pumpRouted(tester, const ContactsSection(partyId: 'p1'), b);
    expect(find.text('No contact persons yet.'), findsOneWidget);
    await tester.tap(find.text('Add contact'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Meera Shah',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Phone (optional)'),
      '9876543210',
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    final body = b.last('POST', '/parties/p1/contacts')!.data as Map;
    expect(body['name'], 'Meera Shah');
    expect(body['phone'], '9876543210');
    expect(body['isPrimary'], isTrue);
    expect(body.containsKey('designation'), isTrue);
  });

  testWidgets('edit patches and delete calls the API', (tester) async {
    final b = FakeControlsBackend()
      ..on('GET /parties/p1/contacts', {
        'data': [contactJson(primary: false)],
      })
      ..on('PATCH /parties/p1/contacts/c1', contactJson())
      ..on('DELETE /parties/p1/contacts/c1', {'ok': true});
    await pumpRouted(tester, const ContactsSection(partyId: 'p1'), b);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit contact'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(
      (b.last('PATCH', '/parties/p1/contacts/c1')!.data as Map)['isPrimary'],
      isTrue,
    );

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(b.last('DELETE', '/parties/p1/contacts/c1'), isNotNull);
  });
}
