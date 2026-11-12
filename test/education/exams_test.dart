import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/json.dart';
import 'package:progen_erp/features/education/exam_data.dart';
import 'package:progen_erp/features/education/report_card_pdf.dart';

import '../support/fake_backend.dart';
import 'education_harness.dart';
import 'exam_fakes.dart';

const _teacher = {'dashboard.view', 'education.view', 'education.exams'};

void main() {
  group('models and report card pdf', () {
    test('ReportCard reads subjects, absence, rank and scale', () async {
      final c = ReportCard.fromJson(asJson(examCard()));
      expect(c.result.rank, 1);
      expect(c.result.subjects[1].absent, isTrue);
      expect(c.attPresent, 18);
      expect(c.result.remark, 'Bright and regular.');
      expect(c.result.coScholastic.first.grade, 'A');
      expect(c.grades.last.grade, 'E');
      final bytes = await buildReportCardsPdf([c, c]);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(2000));
      expect(
        reportCardFileName('Unit test 1', 'Asha Shah'),
        'report-card-Unit-test-1-Asha-Shah.pdf',
      );
    });

    test('MarkGrid keeps absent apart from empty', () {
      final g = MarkGrid.fromJson(asJson(examGrid()));
      expect(g.students[1].cells['pe']!.absent, isTrue);
      expect(g.students[1].cells['pm']!.empty, isTrue);
      expect(g.students[0].cells['pm']!.marks, 48);
    });
  });

  for (final size in eduTestSizes) {
    testWidgets('exam list and term page at ${size.width.toInt()}px', (
      tester,
    ) async {
      final h = await bootEdu(tester, size, location: '/education/exams');
      expect(find.text('Unit test 1'), findsOneWidget);
      expect(find.text('Marks open'), findsOneWidget);
      await h.go('/education/exams/t1');
      expect(find.text('Publish'), findsOneWidget);
      expect(find.textContaining('2 of 4 marks entered'), findsOneWidget);
      expect(find.byKey(const ValueKey('enter-c1')), findsOneWidget);
      h.expectClean('term at ${size.width}');
    });
  }

  testWidgets(
    'wide screens get a grid; saving sends only the changed cells, A means absent',
    (tester) async {
      final h = await bootEdu(
        tester,
        const Size(1440, 900),
        location: '/education/exams/t1/c1/marks',
      );
      expect(find.text('Mathematics\n(50)'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('m-1-English')), '41');
      await tester.enterText(
        find.byKey(const ValueKey('m-2-Mathematics')),
        'a',
      );
      await tester.pump();
      await tester.tap(find.text('Save 2 changes'));
      await tester.pumpAndSettle();
      final body = h.backend.body(
        'POST',
        '/education/exam-terms/t1/classes/c1/marks',
      );
      final entries = (body['entries'] as List).cast<Map>();
      expect(entries, hasLength(2));
      expect(entries.firstWhere((e) => e['paperId'] == 'pe')['marks'], 41);
      final ab = entries.firstWhere((e) => e['paperId'] == 'pm');
      expect(ab['absent'], isTrue);
      expect(ab['marks'], isNull);
      h.expectClean('grid');
    },
  );

  testWidgets('a mark above the maximum is flagged and not sent', (
    tester,
  ) async {
    final h = await bootEdu(
      tester,
      const Size(1440, 900),
      location: '/education/exams/t1/c1/marks',
    );
    await tester.enterText(find.byKey(const ValueKey('m-1-English')), '51');
    await tester.pump();
    expect(find.text('Max 50'), findsOneWidget);
    await tester.tap(find.text('Save 1 changes'));
    await tester.pumpAndSettle();
    expect(
      h.backend.count('POST', '/education/exam-terms/t1/classes/c1/marks'),
      0,
    );
  });

  for (final size in const [Size(320, 700), Size(390, 844)]) {
    testWidgets(
      'phones enter one student at a time at ${size.width.toInt()}px',
      (tester) async {
        final h = await bootEdu(
          tester,
          size,
          location: '/education/exams/t1/c1/marks',
        );
        expect(find.text('Asha Shah'), findsOneWidget);
        expect(find.text('1 of 2'), findsNothing);
        expect(find.textContaining('1 of 2'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('absent-1-English')));
        await tester.pump();
        await tester.tap(find.byTooltip('Next student'));
        await tester.pump();
        expect(find.text('Bhavin Mehta'), findsOneWidget);
        h.expectClean('phone marks');
      },
    );
  }

  testWidgets('a teacher can enter marks but cannot publish or set up', (
    tester,
  ) async {
    final h = await bootEdu(
      tester,
      const Size(390, 844),
      permissions: {..._teacher, ...FakeBackend.allPermissions}
        ..removeWhere(
          (p) => p.startsWith('education.') && !_teacher.contains(p),
        ),
      location: '/education/exams/t1',
    );
    expect(find.text('Publish'), findsNothing);
    expect(find.byKey(const ValueKey('papers-c1')), findsNothing);
    expect(find.byKey(const ValueKey('enter-c1')), findsOneWidget);
    h.expectClean('teacher');
  });

  testWidgets('results list shows rank and a report card button', (
    tester,
  ) async {
    final h = await bootEdu(
      tester,
      const Size(390, 844),
      location: '/education/exams/t1/c1/results',
    );
    expect(find.text('#1'), findsOneWidget);
    expect(find.textContaining('48.0%'), findsWidgets);
    expect(find.byKey(const ValueKey('card-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('class-cards')), findsOneWidget);
    h.expectClean('results');
  });

  testWidgets('wide: remarks tab saves a remark and a co-scholastic grade', (
    tester,
  ) async {
    final h = await bootEdu(
      tester,
      const Size(1440, 900),
      location: '/education/exams/t1/c1/marks',
    );
    await tester.tap(find.text('Remarks and grades'));
    await tester.pumpAndSettle();
    expect(find.text('Discipline'), findsNWidgets(2));
    await tester.enterText(
      find.byKey(const ValueKey('remark-2')),
      'Needs to focus.',
    );
    await tester.tap(find.byKey(const ValueKey('co-2-Discipline-B')));
    await tester.pump();
    await tester.tap(find.text('Save 1 students'));
    await tester.pumpAndSettle();
    final e =
        (h.backend.body(
                      'POST',
                      '/education/exam-terms/t1/classes/c1/remarks',
                    )['entries']
                    as List)
                .single
            as Map;
    expect(e['studentId'], 'b');
    expect(e['remark'], 'Needs to focus.');
    expect((e['areas'] as Map)['Discipline'], 'B');
    h.expectClean('remarks wide');
  });

  testWidgets('phone: remarks one student at a time', (tester) async {
    final h = await bootEdu(
      tester,
      const Size(320, 700),
      location: '/education/exams/t1/c1/marks',
    );
    await tester.tap(find.text('Remarks and grades'));
    await tester.pumpAndSettle();
    expect(find.text('1. Asha Shah'), findsOneWidget);
    expect(find.text('2. Bhavin Mehta'), findsNothing);
    await tester.tap(find.byTooltip('Next student').last);
    await tester.pumpAndSettle();
    expect(find.text('2. Bhavin Mehta'), findsOneWidget);
    h.expectClean('remarks phone');
  });

  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets(
      'co-scholastic grade scale is editable at ${size.width.toInt()}px',
      (tester) async {
        final h = await bootEdu(tester, size, location: '/education/exams');
        await tester.ensureVisible(find.text('Grading scale'));
        await tester.tap(find.text('Grading scale'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('edit-co-scale')));
        await tester.tap(find.byKey(const ValueKey('edit-co-scale')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('co-label-1')),
          'Fine',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        final g =
            (h.backend.body('PATCH', '/education/exam-settings')['coGrades']
                    as List)
                .cast<Map>();
        expect(g.map((e) => e['grade']), ['A', 'B']);
        expect(g[1]['label'], 'Fine');
        h.expectClean('co scale');
      },
    );

    testWidgets(
      'class areas can be added, reordered and removed at ${size.width.toInt()}px',
      (tester) async {
        final h = await bootEdu(tester, size, location: '/education/exams');
        await tester.ensureVisible(find.text('Co-scholastic areas'));
        await tester.tap(find.text('Co-scholastic areas'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'New area'),
          'Music',
        );
        await tester.tap(find.text('Add'));
        await tester.pump();
        await tester.tap(find.byTooltip('Move up').at(1));
        await tester.pump();
        await tester.tap(find.byTooltip('Remove area').at(0));
        await tester.pump();
        await tester.tap(find.text('Save areas'));
        await tester.pumpAndSettle();
        expect(
          h.backend.body('POST', '/education/classes/c1/co-areas')['areas'],
          ['Discipline', 'Music'],
        );
        h.expectClean('areas');
      },
    );
  }
}
