import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/features/crm/crm_models.dart';

import '../support/fake_backend.dart';
import 'crm_harness.dart';

const _phone = Size(390, 844);
const _narrow = Size(320, 800);
const _desktop = Size(1440, 900);

Finder _scroll() => find
    .descendant(
      of: find.byType(ListView).first,
      matching: find.byType(Scrollable),
    )
    .first;

void main() {
  group('models', () {
    test('today parses counts, groups, balance and month', () {
      final t = TodayData.fromJson(todayJson);
      expect(t.dueToday, 6);
      expect(t.overdueCount, 2);
      expect(t.newLeads, 3);
      expect(t.overdue, hasLength(2));
      final a = t.overdue.first;
      expect(a.title, 'Shree Ganesh Hardware');
      expect(a.value, 184500);
      expect(a.dealId, 'd1');
      expect(a.path, '/crm/deals/d1');
      expect(owesText(a.partyBalance, (n) => '₹${n.toInt()}'), 'owes ₹42000, 12 days late');
      expect(t.today.single.hasPhone, isFalse);
      expect(t.month.target, 600000);
      expect(t.month.weightedValue, 790000);
    });

    test('lead, deal, stats and overview parse', () {
      final l = CrmLead.fromJson(leadJson('l1', 'Arjun'));
      expect(l.estimatedValue, 74250);
      expect(l.nextFollowUp, isNull);
      expect(l.isClosed, isFalse);
      final d = CrmDeal.fromJson(deal('d1', 'T', 's3', 'Quotation sent', 1000, overdue: true));
      expect(d.followUpOverdue, isTrue);
      expect(d.nextFollowUp?.subject, 'Call back about Q-0031');
      expect(d.effectiveProbability, 50);
      final s = CrmStats.fromJson(statsJson);
      expect(s.winRate, 62.5);
      expect(s.byOwner?.single.name, 'Sunil Patil');
      expect(s.lostReasons.single, ('Price too high', 2));
      final o = PartyOverview.fromJson(overviewJson);
      expect(o.sales12m, 680000);
      expect(o.timeline.single.kind, 'quotation');
      expect(o.avgDaysToPay, 21);
    });

    test('stats without byOwner leaves it null', () {
      final s = CrmStats.fromJson({...statsJson}..remove('byOwner'));
      expect(s.byOwner, isNull);
    });

    test('isoWithOffset keeps the wall clock and adds an offset', () {
      final s = isoWithOffset(DateTime(2026, 11, 14, 11));
      expect(s, matches(RegExp(r'^2026-11-14T11:00:00[+-]\d\d:\d\d$')));
    });
  });

  for (final size in [_phone, _desktop]) {
    final w = size.width.toInt();

    testWidgets('today screen at ${w}px', (tester) async {
      final h = await bootCrm(tester, size);
      expect(find.text('6'), findsOneWidget);
      expect(find.text('follow-ups today'), findsOneWidget);
      expect(find.text('2 overdue'), findsOneWidget);
      expect(find.text('3 new enquiries since yesterday'), findsOneWidget);
      expect(find.text('Overdue'), findsOneWidget);
      expect(find.text('Today'), findsWidgets);
      expect(find.text('Shree Ganesh Hardware'), findsOneWidget);
      expect(find.text('₹1,84,500'), findsOneWidget);
      expect(find.textContaining('owes ₹42,000, 12 days late'), findsOneWidget);
      expect(find.text('IndiaMART'), findsOneWidget);
      expect(find.text('Quotations'), findsOneWidget);
      // Only tiles with a phone get Call, so two of three.
      expect(find.text('Call'), findsNWidgets(2));
      expect(find.text('Log outcome'), findsNWidgets(3));
      await tester.scrollUntilVisible(
        find.text('Likely to close (weighted)'),
        200,
        scrollable: _scroll(),
      );
      expect(find.text('₹4,20,000 of ₹6,00,000'), findsOneWidget);
      expect(find.text('14 · ₹18,40,000'), findsOneWidget);
      expect(find.text('₹7,90,000'), findsOneWidget);
      h.expectClean('today at $w');
    });

    testWidgets('deals list at ${w}px', (tester) async {
      final h = await bootCrm(tester, size, initial: '/crm/deals');
      expect(find.text('Open pipeline, 14 deals'), findsOneWidget);
      expect(find.text('₹18,40,000'), findsWidgets);
      expect(find.textContaining('Quotation sent'), findsWidgets);
      expect(find.text('Follow-up overdue'), findsOneWidget);
      expect(find.text('Owes ₹42,000, 12 days late'), findsOneWidget);
      expect(find.text('15 days in this stage'), findsOneWidget);
      h.expectClean('deals at $w');
    });
  }

  testWidgets('read-only user sees no write actions', (tester) async {
    final h = await bootCrm(
      tester,
      _phone,
      permissions: {...FakeBackend.allPermissions, 'crm.view'},
    );
    expect(find.text('Log outcome'), findsNothing);
    expect(find.text('Call'), findsNWidgets(2));
    expect(find.text('Quotations'), findsNothing);
    h.expectClean('read only');
  });

  testWidgets('log outcome sends outcome and next follow-up', (tester) async {
    final h = await bootCrm(tester, _phone);
    await tester.tap(find.text('Log outcome').first);
    await tester.pumpAndSettle();
    expect(find.text('Interested'), findsOneWidget);
    expect(find.text('Not reachable'), findsOneWidget);
    await tester.tap(find.text('Call back'));
    await tester.tap(find.text('Tomorrow 11 am'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'What to do'), 'Call about 3% off');
    await tester.enterText(find.widgetWithText(TextField, 'Notes (optional)'), 'Wants 40 bags');
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final body = h.backend.last('POST', '/crm/activities/a1/done').data as Map;
    expect(body['outcome'], 'Call back');
    expect(body['notes'], 'Wants 40 bags');
    final next = body['next'] as Map;
    expect(next['kind'], 'call');
    expect(next['subject'], 'Call about 3% off');
    final due = DateTime.parse(next['dueAt'] as String).toLocal();
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    expect(due.hour, 11);
    expect(due.day, tomorrow.day);
    // Reloaded after the write.
    expect(h.backend.count('GET', '/crm/today'), greaterThan(1));
    h.expectClean('log outcome');
  });

  testWidgets('log outcome without a next follow-up omits next', (tester) async {
    final h = await bootCrm(tester, _phone);
    await tester.tap(find.text('Log outcome').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not interested'));
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final body = h.backend.last('POST', '/crm/activities/a1/done').data as Map;
    expect(body['outcome'], 'Not interested');
    expect(body.containsKey('next'), isFalse);
    h.expectClean('no next');
  });

  testWidgets('log outcome needs an outcome', (tester) async {
    final h = await bootCrm(tester, _phone);
    await tester.tap(find.text('Log outcome').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Say what happened'), findsOneWidget);
    expect(h.backend.count('POST', '/crm/activities/a1/done'), 0);
  });

  testWidgets('duplicate lead shows the existing one and can add anyway', (tester) async {
    final h = await bootCrm(
      tester,
      _phone,
      initial: '/crm/leads',
      setup: (b) => b.duplicate = true,
    );
    expect(find.text('Arjun Traders'), findsOneWidget);
    await tester.tap(find.text('Add lead').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Arjun Traders');
    await tester.enterText(find.widgetWithText(TextFormField, 'Phone'), '9000011111');
    await tester.tap(find.text('Save lead'));
    await tester.pumpAndSettle();
    expect(find.text('This phone or email is already an open lead.'), findsOneWidget);
    expect(find.text('Arjun Traders, contacted'), findsOneWidget);
    expect((h.backend.last('POST', '/crm/leads').data as Map).containsKey('force'), isFalse);
    await tester.tap(find.text('Add anyway'));
    await tester.pumpAndSettle();
    expect(h.backend.count('POST', '/crm/leads'), 2);
    expect((h.backend.last('POST', '/crm/leads').data as Map)['force'], true);
    h.expectClean('duplicate');
  });

  testWidgets('lead form asks for a phone or an email', (tester) async {
    final h = await bootCrm(tester, _phone, initial: '/crm/leads');
    await tester.tap(find.text('Add lead').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Asha');
    await tester.tap(find.text('Save lead'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a phone or an email'), findsOneWidget);
    expect(h.backend.count('POST', '/crm/leads'), 0);
  });

  testWidgets('lead detail converts to customer and deal', (tester) async {
    final h = await bootCrm(tester, _phone, initial: '/crm/leads/l1');
    expect(find.text('Matching customers'), findsOneWidget);
    expect(find.text('Mark lost', skipOffstage: false), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Convert to customer and deal'),
      300,
      scrollable: _scroll(),
    );
    await tester.ensureVisible(find.text('Convert to customer and deal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Convert to customer and deal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use Arjun Traders Pvt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Convert'));
    await tester.pumpAndSettle();
    final body = h.backend.last('POST', '/crm/leads/l1/convert').data as Map;
    expect(body['partyId'], 'p1');
    expect((body['deal'] as Map)['title'], 'PVC pipes, 200 m');
    expect((body['deal'] as Map)['value'], 74250);
    // Lands on the new deal.
    expect(h.router.state.uri.path, '/crm/deals/d1');
    h.expectClean('convert');
  });

  testWidgets('deal page: summary, steps and stage change', (tester) async {
    final h = await bootCrm(tester, _phone, initial: '/crm/deals/d1');
    expect(find.text('NEXT STEP · OVERDUE YESTERDAY 5 PM', skipOffstage: false), findsNothing);
    expect(find.textContaining('NEXT STEP · OVERDUE'), findsOneWidget);
    expect(find.text('Owes now'), findsOneWidget);
    expect(find.text('₹42,000 · 12 days late'), findsOneWidget);
    expect(find.text('₹2,00,000'), findsOneWidget);
    expect(find.text('₹6,80,000'), findsOneWidget);
    expect(find.text('21 days'), findsOneWidget);
    expect(find.text('Usually pays in'), findsOneWidget);
    await tester.tap(find.text('Negotiation'));
    await tester.pumpAndSettle();
    final body = h.backend.last('POST', '/crm/deals/d1/stage').data as Map;
    expect(body['stageId'], 's4');
    h.expectClean('stage change');
  });

  testWidgets('deal page: won asks for the final value', (tester) async {
    final h = await bootCrm(tester, _phone, initial: '/crm/deals/d1');
    await tester.scrollUntilVisible(
      find.text('Won / lost'),
      300,
      scrollable: _scroll(),
    );
    await tester.ensureVisible(find.text('Won / lost'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Won / lost'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark won'));
    await tester.pumpAndSettle();
    expect(find.text('Final value'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Final value'), '175000');
    await tester.tap(find.text('Mark won').last);
    await tester.pumpAndSettle();
    final body = h.backend.last('POST', '/crm/deals/d1/won').data as Map;
    expect(body['value'], 175000);
    h.expectClean('won');
  });

  testWidgets('deal page: lost asks for a reason from settings', (tester) async {
    final h = await bootCrm(tester, _phone, initial: '/crm/deals/d1');
    await tester.scrollUntilVisible(
      find.text('Won / lost'),
      300,
      scrollable: _scroll(),
    );
    await tester.ensureVisible(find.text('Won / lost'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Won / lost'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark lost'));
    await tester.pumpAndSettle();
    expect(find.text('Why was it lost?'), findsOneWidget);
    expect(find.text('Chose a competitor'), findsOneWidget);
    final confirm = find.widgetWithText(FilledButton, 'Mark lost');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.tap(find.text('Price too high'));
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    final body = h.backend.last('POST', '/crm/deals/d1/lost').data as Map;
    expect(body['reason'], 'Price too high');
    h.expectClean('lost');
  });

  testWidgets('customer page shows the summary and timeline', (tester) async {
    final h = await bootCrm(tester, _phone, initial: '/crm/customers/p1');
    expect(find.text('Shree Ganesh Hardware'), findsOneWidget);
    expect(find.text('Bought in 12 months'), findsOneWidget);
    expect(find.textContaining('Quotation: Q-0031 sent'), findsOneWidget);
    h.expectClean('customer');
  });

  for (final size in [_phone, _desktop]) {
    testWidgets('numbers page at ${size.width.toInt()}px', (tester) async {
      final h = await bootCrm(tester, size, initial: '/crm/numbers');
      expect(find.text('Win rate'), findsOneWidget);
      expect(find.text('62.5%'), findsOneWidget);
      expect(find.text('5 won, 3 lost'), findsOneWidget);
      expect(find.text('Average deal size'), findsOneWidget);
      expect(find.text('₹84,000'), findsOneWidget);
      expect(find.text('Response time'), findsOneWidget);
      expect(find.text('2.5 h'), findsOneWidget);
      expect(find.text('Target achievement'), findsOneWidget);
      expect(find.text('70%'), findsOneWidget);
      expect(find.text('Coverage'), findsOneWidget);
      expect(find.text('10.2x'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Why deals were lost'),
        300,
        scrollable: _scroll(),
      );
    await tester.ensureVisible(find.text('Why deals were lost'));
    await tester.pumpAndSettle();
      expect(find.text('Price too high'), findsOneWidget);
      h.expectClean('numbers');
    });
  }

  testWidgets('settings: fetch enquiries now reports added and skipped', (tester) async {
    final h = await bootCrm(tester, _phone, initial: '/crm/settings');
    expect(find.text('Stages'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Fetch enquiries now'),
      300,
      scrollable: _scroll(),
    );
    await tester.ensureVisible(find.text('Fetch enquiries now'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fetch enquiries now'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Added 3 enquiries, skipped 2'), findsOneWidget);
    h.expectClean('settings');
  });

  testWidgets('settings: saving the key sends it and clears the field', (tester) async {
    final h = await bootCrm(tester, _phone, initial: '/crm/settings');
    await tester.scrollUntilVisible(
      find.text('Save key'),
      300,
      scrollable: _scroll(),
    );
    await tester.ensureVisible(find.text('Save key'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'New key'), 'abc123');
    await tester.pump();
    await tester.tap(find.text('Save key'));
    await tester.pumpAndSettle();
    expect((h.backend.last('PATCH', '/crm/settings').data as Map)['indiamartKey'], 'abc123');
  });

  group('no overflow at 320px', () {
    for (final path in [
      '/crm',
      '/crm/deals',
      '/crm/deals/d1',
      '/crm/leads',
      '/crm/leads/l1',
      '/crm/numbers',
      '/crm/settings',
      '/crm/customers/p1',
    ]) {
      testWidgets(path, (tester) async {
        final h = await bootCrm(tester, _narrow, initial: path);
        h.expectClean(path);
        // Scroll to the end to lay out every child.
        final scroll = find.byType(ListView);
        if (scroll.evaluate().isNotEmpty) {
          await tester.drag(scroll.first, const Offset(0, -3000));
          await tester.pumpAndSettle();
        }
        h.expectClean('$path scrolled');
      });
    }

    testWidgets('log outcome sheet', (tester) async {
      final h = await bootCrm(tester, _narrow);
      await tester.tap(find.text('Log outcome').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('In 3 days'));
      await tester.pumpAndSettle();
      h.expectClean('sheet');
    });
  });
}
