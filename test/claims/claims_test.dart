import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/claims/approval_queue_screen.dart';
import 'package:onematrix/features/claims/claim_categories_screen.dart';
import 'package:onematrix/features/claims/claim_detail_screen.dart';
import 'package:onematrix/features/claims/claim_form_screen.dart';
import 'package:onematrix/features/claims/loans_screens.dart';
import 'package:onematrix/features/claims/my_claims_screen.dart';

import '../controls/controls_harness.dart';

const narrow = Size(320, 640);

Map<String, Object?> claim({String status = 'submitted', bool canApprove = false}) => {
  'id': 'c1',
  'number': 'CLM/26-27/00001',
  'employeeName': 'Meera Rao',
  'purpose': 'Client visit',
  'claimDate': '2026-10-05',
  'status': status,
  'total': 1180,
  'gstTotal': 180,
  'canApprove': canApprove,
  'lines': [
    {
      'categoryId': 'k1',
      'categoryName': 'Travel',
      'expenseDate': '2026-10-05',
      'description': 'Cab to client',
      'amount': 1180,
      'gstAmount': 180,
      'itcEligible': false,
    },
  ],
};

Map<String, Object?> loan() => {
  'id': 'l1',
  'number': 'LON/26-27/00001',
  'employeeName': 'Meera Rao',
  'kind': 'loan',
  'purpose': 'Bike',
  'amount': 30000,
  'interestRate': 12,
  'instalment': 2000,
  'status': 'active',
  'outstanding': 31000,
  'caReview': true,
  'perquisiteNote': 'Tax treatment not confirmed; mark for CA review.',
  'nextDueMonth': '2026-10',
  'schedule': [
    {'seq': 1, 'dueMonth': '2026-10', 'principal': 1700, 'interest': 300, 'amount': 2000, 'status': 'due'},
    {'seq': 2, 'dueMonth': '2026-11', 'principal': 1717, 'interest': 283, 'amount': 2000, 'status': 'due'},
  ],
};

void main() {
  testWidgets('my claims lists claims at 320 px', (t) async {
    final b = FakeControlsBackend()..on('GET /claims', pageOf([claim(status: 'draft')]));
    await pumpControls(t, const MyClaimsScreen(), b, size: narrow, permissions: {'payroll.self'});
    expect(find.text('Client visit'), findsOneWidget);
    expect(find.text('New claim'), findsOneWidget);
    expect(t.takeException(), isNull);
    expect(b.last('GET', '/claims')!.queryParameters['mine'], 'true');
  });

  testWidgets('my claims shows an empty state', (t) async {
    final b = FakeControlsBackend()..on('GET /claims', pageOf([]));
    await pumpControls(t, const MyClaimsScreen(), b, size: narrow, permissions: {'payroll.self'});
    expect(find.textContaining('no claims yet'), findsOneWidget);
  });

  testWidgets('approver approves a submitted claim', (t) async {
    final b = FakeControlsBackend()
      ..on('GET /claims/c1', claim(canApprove: true))
      ..on('POST /claims/c1/approve', claim(status: 'approved'));
    await pumpControls(t, const ClaimDetailScreen(claimId: 'c1'), b, size: narrow, permissions: {'claims.approve'});
    expect(find.text('Cab to client'), findsNothing); // line title holds the category too
    expect(find.textContaining('Travel: Cab to client'), findsOneWidget);
    await t.tap(find.text('Approve'));
    await t.pumpAndSettle();
    await t.tap(find.text('Approve only'));
    await t.pumpAndSettle();
    expect(b.last('POST', '/claims/c1/approve'), isNotNull);
  });

  testWidgets('claimant cannot approve their own claim', (t) async {
    final b = FakeControlsBackend()..on('GET /claims/c1', claim());
    await pumpControls(t, const ClaimDetailScreen(claimId: 'c1'), b, size: narrow, permissions: {'claims.approve'});
    expect(find.text('Approve'), findsNothing);
  });

  testWidgets('reject needs a reason', (t) async {
    final b = FakeControlsBackend()
      ..on('GET /claims/c1', claim(canApprove: true))
      ..on('POST /claims/c1/reject', claim(status: 'rejected'));
    await pumpControls(t, const ClaimDetailScreen(claimId: 'c1'), b, size: narrow, permissions: {'claims.approve'});
    await t.tap(find.text('Reject'));
    await t.pumpAndSettle();
    await t.tap(find.text('Reject').last);
    await t.pumpAndSettle();
    expect(b.last('POST', '/claims/c1/reject'), isNull);
    await t.enterText(find.byType(TextField), 'Not a business expense');
    await t.tap(find.text('Reject').last);
    await t.pumpAndSettle();
    expect(b.last('POST', '/claims/c1/reject')!.data, {'note': 'Not a business expense'});
  });

  testWidgets('approved claim can be sent to payroll by a manager', (t) async {
    final b = FakeControlsBackend()
      ..on('GET /claims/c1', claim(status: 'approved'))
      ..on('POST /claims/c1/settle', claim(status: 'approved'));
    await pumpControls(t, const ClaimDetailScreen(claimId: 'c1'), b, size: narrow, permissions: {'claims.manage'});
    await t.tap(find.text('Add to payroll'));
    await t.pumpAndSettle();
    expect(b.last('POST', '/claims/c1/settle')!.data, {'mode': 'payroll'});
  });

  testWidgets('claim form validates before sending', (t) async {
    final b = FakeControlsBackend()
      ..on('GET /claims/categories', {'data': [{'id': 'k1', 'name': 'Travel', 'isActive': true}]});
    await pumpControls(t, const ClaimFormScreen(), b, size: narrow, permissions: {'payroll.self'});
    await t.tap(find.text('Submit claim'));
    await t.pumpAndSettle();
    expect(find.text('Say what the claim is for.'), findsOneWidget);
    expect(b.last('POST', '/claims'), isNull);
  });

  testWidgets('approval queue lists claims and a summary', (t) async {
    final b = FakeControlsBackend()
      ..on('GET /claims', pageOf([claim()]))
      ..on('GET /claims/summary', pageOf([{'key': 'e1', 'label': 'Meera Rao', 'count': 2, 'total': 2360}]));
    await pumpControls(t, const ApprovalQueueScreen(), b, size: narrow, permissions: {'claims.approve', 'claims.manage'});
    expect(find.text('Client visit'), findsOneWidget);
    expect(find.text('2 claims'), findsOneWidget);
  });

  testWidgets('categories show limits', (t) async {
    final b = FakeControlsBackend()
      ..on('GET /claims/categories', {'data': [{'id': 'k1', 'name': 'Travel', 'isActive': true, 'perClaimLimit': 1000, 'monthlyLimit': null, 'requiresReceipt': true}]});
    await pumpControls(t, const ClaimCategoriesScreen(), b, size: narrow, permissions: {'claims.manage'});
    expect(find.text('Travel'), findsOneWidget);
    expect(find.textContaining('Receipt needed'), findsOneWidget);
  });

  testWidgets('loan detail shows schedule, CA note and pause', (t) async {
    final b = FakeControlsBackend()
      ..on('GET /loans/l1', loan())
      ..on('POST /loans/l1/pause', {'id': 'l1'});
    await pumpControls(t, const LoanDetailScreen(loanId: 'l1'), b, size: const Size(320, 1600), permissions: {'loans.manage'});
    expect(find.textContaining('CA review'), findsOneWidget);
    expect(find.text('1. 2026-10'), findsOneWidget);
    await t.tap(find.text('Pause recovery'));
    await t.pumpAndSettle();
    expect(b.last('POST', '/loans/l1/pause'), isNotNull);
  });

  testWidgets('loans list at 1280 px', (t) async {
    final b = FakeControlsBackend()..on('GET /loans', pageOf([loan()]));
    await pumpControls(t, const LoansScreen(), b, permissions: {'loans.manage'});
    expect(find.textContaining('LON/26-27/00001'), findsOneWidget);
    expect(find.text('New advance or loan'), findsOneWidget);
  });

  testWidgets('loan form asks for the required fields', (t) async {
    final b = FakeControlsBackend()
      ..on('GET /employees', pageOf([]))
      ..on('GET /accounts', pageOf([]));
    await pumpControls(t, const LoanFormScreen(), b, size: narrow, permissions: {'loans.manage'});
    await t.tap(find.text('Give and record payment'));
    await t.pumpAndSettle();
    expect(find.textContaining('Choose the employee'), findsOneWidget);
    expect(b.last('POST', '/loans'), isNull);
  });
}
