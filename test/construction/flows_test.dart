import 'package:dio/dio.dart' show FormData;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/construction_harness.dart';

void main() {
  const phone = Size(360, 740);
  const tablet = Size(768, 1024);
  const desktop = Size(1440, 900);

  Finder inCard(String name, Finder child) => find.descendant(
    of: find.ancestor(of: find.text(name), matching: find.byType(Card)).first,
    matching: child,
  );

  testWidgets('attendance: one-tap marks, mark all, OT, save body, lock', (
    tester,
  ) async {
    final app = await bootConstruction(
      tester,
      phone,
      initial: '/attendance?siteId=l2&date=2026-10-27',
    );
    expect(find.text('Ramesh Kumar'), findsOneWidget);

    await tester.tap(inCard('Suresh Patil', find.text('Absent')));
    await tester.tap(find.text('Mark all present'));
    await tester.pump();
    final moreOt = find.byTooltip(
      'More OT hours for Mohammed Irfan',
      skipOffstage: false,
    );
    await tester.ensureVisible(moreOt);
    await tester.pumpAndSettle();
    await tester.tap(moreOt);
    await tester.pump();
    // Only changed rows are sent: Ramesh was already saved as present.
    await tester.tap(find.text('Save (2)'));
    await tester.pumpAndSettle();

    expect(app.backend.body('PUT', '/attendance'), {
      'siteId': 'l2',
      'date': '2026-10-27',
      'entries': [
        {'workerId': 'w2', 'status': 'absent', 'otHours': 0},
        {'workerId': 'w3', 'status': 'present', 'otHours': 0.5},
      ],
    });
    expect(find.text('Attendance saved for 2 workers'), findsOneWidget);

    // An approved wage sheet locks the date: the screen switches to locked.
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .hideCurrentSnackBar();
    await tester.pumpAndSettle();
    app.backend.attendanceLocked = true;
    final half = inCard('Mohammed Irfan', find.text('Half'));
    await tester.ensureVisible(half);
    await tester.pumpAndSettle();
    await tester.tap(half);
    await tester.pump();
    await tester.tap(find.text('Save (1)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot be changed'), findsOneWidget);
    expect(find.text('Mark all present'), findsNothing);
    app.expectClean('attendance');
  });

  testWidgets('DPR: weather, photo upload (multipart) and one-step submit', (
    tester,
  ) async {
    final photos = FakePhotoSource();
    final app = await bootConstruction(
      tester,
      desktop,
      initial: '/dprs/new?locationId=l2',
      photos: photos,
    );
    await tester.tap(find.text('Rain'));
    await tester.ensureVisible(find.text('Camera'));
    await tester.tap(find.text('Camera'));
    await tester.pumpAndSettle();

    expect(photos.picks, 1);
    final upload = app.backend.last('POST', '/files');
    expect(upload.data, isA<FormData>());
    expect((upload.data as FormData).files.single.key, 'file');
    expect(
      upload.headers['content-type'].toString(),
      startsWith('multipart/form-data'),
    );
    expect(upload.headers['Authorization'], 'Bearer access');

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Caption'),
      'Slab C4 before pour',
    );
    await tester.tap(find.text('Save & submit'));
    await tester.pumpAndSettle();

    final body = app.backend.body('POST', '/dprs');
    expect(body['locationId'], 'l2');
    expect(body['weather'], 'rain');
    expect(body['submit'], isTrue);
    expect(body['photos'], [
      {'fileId': 'f9', 'caption': 'Slab C4 before pour'},
    ]);
    expect(app.backend.count('POST', '/dprs/dpr9/submit'), 0);
    expect(app.router.state.uri.path, '/dprs/dpr9');
    app.expectClean('dpr create');
  });

  testWidgets('DPR: copy yesterday fills work, labour and equipment', (
    tester,
  ) async {
    final app = await bootConstruction(
      tester,
      desktop,
      initial: '/dprs/new?locationId=l2',
    );
    await tester.tap(find.text('Copy yesterday'));
    await tester.pumpAndSettle();
    expect(app.backend.count('GET', '/dprs/previous'), 1);
    expect(find.textContaining('Copied from the report of'), findsOneWidget);
    expect(find.text('JCB'), findsOneWidget);
    app.expectClean('copy yesterday');
  });

  testWidgets('indent approve: edited quantities are validated and sent', (
    tester,
  ) async {
    final app = await bootConstruction(
      tester,
      tablet,
      initial: '/indents/ind1',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await tester.pumpAndSettle();
    final qty = find.widgetWithText(TextField, 'Approved quantity');
    await tester.enterText(qty, '250');
    await tester.tap(find.widgetWithText(FilledButton, 'Approve').last);
    await tester.pump();
    expect(find.text('At most 200'), findsOneWidget);
    expect(app.backend.count('POST', '/indents/ind1/approve'), 0);

    await tester.enterText(qty, '150');
    await tester.tap(find.widgetWithText(FilledButton, 'Approve').last);
    await tester.pumpAndSettle();
    expect(app.backend.body('POST', '/indents/ind1/approve'), {
      'lines': [
        {'lineId': 'ind1l1', 'approvedQty': 150.0},
      ],
    });
    expect(find.text('Approved 150 bag'), findsOneWidget);
    expect(find.text('Close indent'), findsOneWidget);
    app.expectClean('indent approve');
  });

  testWidgets('material issue shows INSUFFICIENT_STOCK clearly', (
    tester,
  ) async {
    final app = await bootConstruction(tester, phone, initial: '/issues/new');
    await tester.ensureVisible(find.text('Add material', skipOffstage: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add material'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Portland Cement 53 Grade 50kg').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantity'),
      '150',
    );
    await tester.tap(find.text('Post issue'));
    await tester.pumpAndSettle();
    expect(app.backend.body('POST', '/issues')['locationId'], 'l2');
    expect(find.text('Not enough stock'), findsOneWidget);
    app.expectClean('issue');
  });
}
