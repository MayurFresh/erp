import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/business_profile.dart';
import 'package:onematrix/features/job_cards/job_models.dart';
import 'package:onematrix/features/job_cards/job_pdf.dart';
import 'package:onematrix/features/memberships/memberships_models.dart';

import 'services_harness.dart';

void main() {
  group('models', () {
    test('MemWords reads flat and maintenance for a housing society', () {
      final s = MemWords.of(const BusinessProfile(type: 'housing_society'));
      expect(s.society, isTrue);
      expect(s.title, 'Maintenance');
      expect(s.members, 'Flats');
      final g = MemWords.of(const BusinessProfile(type: 'gym'));
      expect(g.title, 'Memberships');
      expect(g.members, 'Members');
      expect(g.plans, 'Plans');
    });

    test('MemberBrief and JobDetail parse the API shape', () {
      final m = MemberBrief.fromJson(
        memberJson('1', 'Aarav Mehta', 'expiring', flat: '101'),
      );
      expect(m.status, 'expiring');
      expect(m.flatLabel, 'A 101');
      expect(memStatusLabel(m.status), 'Expiring soon');
      final j = JobDetail.fromJson(jobJson('j1', 'estimate_sent'));
      expect(j.lines, hasLength(2));
      expect(j.totals.total, 2301);
      expect(j.hasUnissuedParts, isTrue);
      expect(j.nextStatuses, ['approved', 'cancelled']);
      expect(jobActionLabel('approved'), 'Record approval');
    });
  });

  group('job pdfs', () {
    test('intake slip and estimate build', () async {
      final d = JobDetail.fromJson(jobJson('j1', 'estimate_sent'));
      final slip = await buildJobIntakePdf(d);
      final est = await buildJobEstimatePdf(d);
      expect(String.fromCharCodes(slip.take(5)), '%PDF-');
      expect(String.fromCharCodes(est.take(5)), '%PDF-');
      expect(slip.length, greaterThan(1500));
      expect(est.length, greaterThan(1500));
      expect(jobPdfName(d, 'estimate'), startsWith('estimate-JOB-26-27-'));
    });

    test('estimate builds with no lines', () async {
      final d = JobDetail.fromJson({
        ...jobJson('j1', 'received'),
        'lines': <Object?>[],
      });
      expect(await buildJobEstimatePdf(d), isNotEmpty);
    });
  });

  for (final size in servicesTestSizes) {
    testWidgets('memberships home renders at ${size.width.toInt()}px', (
      tester,
    ) async {
      final h = await bootServices(tester, size);
      expect(find.text('Expiring this week'), findsOneWidget);
      expect(find.text('Aarav Mehta', skipOffstage: false), findsOneWidget);
      expect(find.text('Dues'), findsWidgets);
      expect(find.text('New member'), findsOneWidget);
      h.expectClean('home at ${size.width}');
    });

    testWidgets('job board renders at ${size.width.toInt()}px', (tester) async {
      final h = await bootServices(tester, size, location: '/job-cards');
      expect(find.textContaining('GJ01AB1234'), findsWidgets);
      if (size.width >= 900) {
        expect(find.textContaining('Received (1)'), findsOneWidget);
        expect(find.textContaining('Ready (1)'), findsOneWidget);
      } else {
        expect(find.textContaining('All open'), findsOneWidget);
      }
      expect(find.text('New job card'), findsOneWidget);
      h.expectClean('board at ${size.width}');
    });
  }

  testWidgets('a housing society reads flats and maintenance', (tester) async {
    final h = await bootServices(
      tester,
      const Size(390, 844),
      profile: const BusinessProfile(type: 'housing_society'),
    );
    expect(find.text('Add flat'), findsOneWidget);
    expect(find.text('Maintenance bills'), findsOneWidget);
    expect(find.text('Check-in'), findsNothing);
    expect(find.textContaining('Search flats'), findsOneWidget);
    h.expectClean('society home');
  });

  testWidgets('check-in sends the phone and shows the member', (tester) async {
    final h = await bootServices(
      tester,
      const Size(390, 844),
      location: '/memberships/check-in',
    );
    await tester.enterText(find.byType(TextField), '9825011111');
    await tester.tap(find.text('Mark visit'));
    await tester.pumpAndSettle();
    expect(h.backend.count('POST', '/memberships/checkin'), 1);
    expect(
      h.backend.body('POST', '/memberships/checkin')['phone'],
      '9825011111',
    );
    expect(find.text('Welcome, Aarav Mehta'), findsOneWidget);
    expect(find.textContaining('3 days left'), findsOneWidget);
    h.expectClean('checkin ok');
  });

  testWidgets('check-in shows why an expired member is refused', (
    tester,
  ) async {
    final h = await bootServices(
      tester,
      const Size(390, 844),
      location: '/memberships/check-in',
      checkinRefuses: true,
    );
    await tester.enterText(find.byType(TextField), 'MEM/26-27/00003');
    await tester.tap(find.text('Mark visit'));
    await tester.pumpAndSettle();
    expect(
      h.backend.body('POST', '/memberships/checkin')['memberNo'],
      'MEM/26-27/00003',
    );
    expect(find.textContaining('Rohan Shah: not allowed in'), findsOneWidget);
    expect(
      find.textContaining('Membership expired on 2026-10-01'),
      findsOneWidget,
    );
    h.expectClean('checkin refused');
  });

  testWidgets('bill run shows the preview count and generates', (tester) async {
    final h = await bootServices(
      tester,
      const Size(390, 844),
      location: '/memberships/bills',
    );
    expect(find.textContaining('4 bills will be made'), findsOneWidget);
    await tester.tap(find.text('Generate renewal bills'));
    await tester.pumpAndSettle();
    expect(h.backend.count('POST', '/memberships/bills/generate'), 1);
    expect(
      h.backend.body('POST', '/memberships/bills/generate')['kind'],
      'renewals',
    );
    h.expectClean('bills');
  });

  testWidgets('dues lists a reminder to copy', (tester) async {
    final h = await bootServices(
      tester,
      const Size(390, 844),
      location: '/memberships/dues',
    );
    expect(find.text('Aarav Mehta'), findsOneWidget);
    expect(find.text('Copy reminder'), findsOneWidget);
    h.expectClean('dues');
  });

  testWidgets('a job card moves from estimate sent to approved', (
    tester,
  ) async {
    final h = await bootServices(
      tester,
      const Size(1440, 900),
      location: '/job-cards/j1',
    );
    expect(find.text('Estimate sent'), findsOneWidget);
    expect(find.text('Brake pad'), findsOneWidget);
    expect(find.text('Record approval'), findsOneWidget);
    await tester.tap(find.text('Record approval'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Karan on phone');
    await tester.tap(find.text('Approved'));
    await tester.pumpAndSettle();
    expect(h.backend.count('POST', '/job-cards/j1/status'), 1);
    final b = h.backend.body('POST', '/job-cards/j1/status');
    expect(b['status'], 'approved');
    expect(b['approvedBy'], 'Karan on phone');
    h.expectClean('approve');
  });

  testWidgets('a technician sees my jobs and no create button', (tester) async {
    final h = await bootServices(
      tester,
      const Size(390, 844),
      permissions: {...technicianPermissions, 'dashboard.view'},
      location: '/job-cards/mine',
    );
    expect(find.text('My jobs'), findsWidgets);
    expect(find.text('New job card'), findsNothing);
    expect(
      h.backend.calls.any(
        (c) => c.path == '/job-cards' && c.queryParameters['mine'] == 'true',
      ),
      isTrue,
    );
    h.expectClean('my jobs');
  });

  testWidgets('a front desk without manage cannot open plans to edit', (
    tester,
  ) async {
    final h = await bootServices(
      tester,
      const Size(390, 844),
      permissions: {'memberships.view', 'dashboard.view'},
      location: '/memberships',
    );
    expect(find.text('New member'), findsNothing);
    expect(find.text('Plans'), findsNothing);
    expect(find.text('Aarav Mehta'), findsOneWidget);
    h.expectClean('view only');
  });
}
