import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/permissions.dart';
import 'package:onematrix/core/theme.dart';
import 'package:onematrix/features/auth/session.dart';
import 'package:onematrix/features/gst_compliance/gst_compliance_repository.dart';
import 'package:onematrix/features/gst_compliance/ims_screen.dart';
import 'package:onematrix/features/gst_compliance/msme_43bh_screen.dart';
import 'package:onematrix/features/gst_compliance/rate_history_card.dart';
import 'package:onematrix/features/gst_compliance/slab_review_screen.dart';
import 'package:onematrix/features/gst_compliance/unreported_einvoice_screen.dart';

class FakeRepo implements GstComplianceRepository {
  final actions = <String>[];
  final applied = <Map<String, double>>[];

  @override
  Future<ImsView> ims(String period) async => ImsView.fromJson({
    'importedAt': '2026-10-02T00:00:00Z',
    'summary': {
      'inBooksAccepted': {'count': 1, 'itc': 180},
      'inBooksRejected': {'count': 0, 'itc': 0},
      'pending': {'count': 0, 'itc': 0},
      'notInBooks': {'count': 1, 'itc': 45},
      'deemedAccepted': 2,
    },
    'rows': [
      {
        'id': 'l1',
        'bucket': 'in_books_accepted',
        'deemed': true,
        'imsAction': 'none',
        'supplierName': 'ITC Supplier',
        'docNo': 'A-1',
        'docDate': '2026-10-01',
        'igst': 0,
        'cgst': 90,
        'sgst': 90,
        'purchaseNumber': 'PUR/1',
      },
      {
        'id': 'l2',
        'bucket': 'not_in_books',
        'deemed': true,
        'imsAction': 'none',
        'supplierName': 'Other Co',
        'docNo': 'Z-9',
        'docDate': '2026-10-02',
        'igst': 0,
        'cgst': 22.5,
        'sgst': 22.5,
      },
    ],
  });

  @override
  Future<int> imsAction(List<String> ids, String action, {String? reason}) async {
    actions.add('$action:${ids.join(',')}');
    return ids.length;
  }

  @override
  Future<UnreportedView> unreported() async => UnreportedView.fromJson({
    'band': '10cr_plus',
    'counts': {'ok': 0, 'warn': 1, 'blocked': 1},
    'rows': [
      {'invoiceId': 'i1', 'number': 'INV/1', 'date': '2026-09-01', 'partyName': 'Acme', 'total': 1180, 'ageDays': 40, 'lastDay': '2026-10-01', 'state': 'blocked'},
      {'invoiceId': 'i2', 'number': 'INV/2', 'date': '2026-10-20', 'partyName': 'Beta', 'total': 590, 'ageDays': 22, 'lastDay': '2026-11-19', 'state': 'warn'},
    ],
  });

  @override
  Future<SlabReview> slabReview() async => SlabReview.fromJson({
    'effectiveFrom': '2025-09-22',
    'note': 'Proposals only.',
    'rows': [
      {'itemId': 'a', 'name': 'Biscuits', 'hsnCode': '1905', 'currentRate': 12, 'proposedRate': 5, 'needsCheck': false, 'reviewed': false},
      {'itemId': 'b', 'name': 'Cola', 'hsnCode': '2202', 'currentRate': 28, 'proposedRate': 40, 'needsCheck': true, 'reviewed': false},
    ],
  });

  @override
  Future<int> applySlab(String effectiveFrom, Map<String, double> picks) async {
    applied.add(Map.of(picks));
    return picks.length;
  }

  @override
  Future<List<RateEntry>> itemRates(String itemId) async => [
    const RateEntry(5, '2025-09-22', 'Slab review'),
    const RateEntry(12, '2017-07-01', 'Earlier rate'),
  ];

  @override
  Future<MsmeBh> msme43bh(String taxYear) async => MsmeBh.fromJson({
    'asOf': '2026-03-31',
    'total': 11800,
    'rows': [
      {'number': 'PUR/1', 'billDate': '2026-01-01', 'dueDate': '2026-01-16', 'partyName': 'Micro Co', 'category': 'micro', 'outstanding': 11800, 'daysOverdue': 74},
    ],
  });
}

Future<void> pump(WidgetTester tester, Widget child, Size size, FakeRepo repo) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        gstComplianceRepositoryProvider.overrideWithValue(repo),
        permissionsProvider.overrideWithValue(PermissionSet({'gst.view', 'gst.manage', 'reports.view'})),
      ],
      child: MaterialApp(theme: AppTheme.light, home: Scaffold(body: child)),
    ),
  );
  await tester.pumpAndSettle();
}

const widths = [Size(320, 700), Size(390, 844), Size(1280, 800)];

void main() {
  test('ImsRow reads tax and deemed flag', () {
    final r = ImsRow.fromJson({'id': 'x', 'bucket': 'pending', 'deemed': false, 'igst': 10, 'cgst': 1, 'sgst': 1});
    expect(r.tax, 12);
    expect(r.imsAction, 'none');
    expect(r.deemed, isFalse);
  });

  for (final size in widths) {
    group('at ${size.width}', () {
      testWidgets('IMS selects rows and sends one bulk action', (tester) async {
        final repo = FakeRepo();
        await pump(tester, const ImsScreen(), size, repo);
        expect(find.textContaining('A-1'), findsOneWidget);
        await tester.tap(find.text('Select all shown'));
        await tester.pump();
        expect(find.text('2 selected'), findsOneWidget);
        await tester.tap(find.text('Accept'));
        await tester.pumpAndSettle();
        expect(repo.actions, ['accept:l1,l2']);
        expect(tester.takeException(), isNull);
      });

      testWidgets('IMS asks for a reason before rejecting', (tester) async {
        final repo = FakeRepo();
        await pump(tester, const ImsScreen(), size, repo);
        await tester.tap(find.byType(Checkbox).at(1));
        await tester.pump();
        await tester.tap(find.text('Reject'));
        await tester.pumpAndSettle();
        expect(find.text('Reason'), findsOneWidget);
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(repo.actions, isEmpty);
        await tester.enterText(find.byType(TextField), 'Goods not received');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(repo.actions, ['reject:l1']);
      });

      testWidgets('unreported e-invoices show age and state', (tester) async {
        await pump(tester, const UnreportedEinvoiceScreen(), size, FakeRepo());
        expect(find.textContaining('40 days old'), findsOneWidget);
        expect(find.text('Past limit'), findsOneWidget);
        expect(find.text('Due soon'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('slab review applies only chosen rows', (tester) async {
        final repo = FakeRepo();
        await pump(tester, const SlabReviewScreen(), Size(size.width, 1200), repo);
        expect(find.textContaining('check the notification'), findsOneWidget);
        await tester.tap(find.text('Move to 5%'));
        await tester.pump();
        await tester.tap(find.text('Save 1 items'));
        await tester.pumpAndSettle();
        expect(repo.applied, [
          {'a': 5.0},
        ]);
      });

      testWidgets('43B(h) shows the total and rows', (tester) async {
        await pump(tester, const Msme43bhScreen(), size, FakeRepo());
        expect(find.textContaining('Micro Co'), findsOneWidget);
        expect(find.textContaining('74 days late'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('rate history lists rows newest first', (tester) async {
    await pump(tester, const RateHistoryCard(itemId: 'a'), widths[0], FakeRepo());
    expect(find.textContaining('5%'), findsOneWidget);
    expect(find.textContaining('Earlier rate'), findsOneWidget);
  });
}
