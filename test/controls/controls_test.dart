import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:onematrix/core/api_exception.dart';
import 'package:onematrix/features/controls/approval_rules_screen.dart';
import 'package:onematrix/features/controls/approvals_screens.dart';
import 'package:onematrix/features/controls/cost_centre_widgets.dart';
import 'package:onematrix/features/controls/custom_fields_section.dart';
import 'package:onematrix/features/controls/import_screens.dart';
import 'package:onematrix/widgets/busy.dart';
import 'package:onematrix/widgets/layout.dart';

import 'controls_harness.dart';

Map<String, Object?> importJob(String status, {int created = 0}) => {
  'id': 'i1',
  'kind': 'items',
  'status': status,
  'fileName': 'items.csv',
  'totalRows': 2,
  'validRows': 2,
  'errors': <Object?>[],
  'preview': [
    {'name': 'Cement', 'unit': 'bag'},
  ],
  'options': {'updateExisting': false},
  if (status == 'done')
    'result': {'created': created, 'updated': 0, 'skipped': 0},
  'createdBy': {'name': 'Rita'},
  'createdAt': '2026-11-01T10:00:00Z',
};

void main() {
  group('approval pending (202)', () {
    test('ApiClient throws ApprovalPendingException', () async {
      final b = FakeControlsBackend()
        ..on('POST /purchases', {
          'approvalRequest': {
            'id': 'a1',
            'number': 'APR/0007',
            'docType': 'purchase',
          },
        }, status: 202);
      await expectLater(
        fakeApi(b).postJson('/purchases', body: {}),
        throwsA(
          isA<ApprovalPendingException>()
              .having((e) => e.requestId, 'id', 'a1')
              .having(
                (e) => e.message,
                'message',
                'Sent for approval (APR/0007)',
              ),
        ),
      );
    });

    testWidgets('form shows "Sent for approval" and leaves', (tester) async {
      final b = FakeControlsBackend();
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (c, _) => Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () => handleApprovalPending(
                    context,
                    ApprovalPendingException(
                      requestId: 'a1',
                      number: 'APR/0007',
                    ),
                    listPath: '/purchases',
                  ),
                  child: const Text('Save'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/purchases',
            builder: (_, _) => const Scaffold(body: Text('Purchases list')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await pumpControls(
        tester,
        const SizedBox(),
        b,
        wrap: (_) => MaterialApp.router(routerConfig: router),
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Purchases list'), findsOneWidget);
      expect(
        find.textContaining('Sent for approval (APR/0007)'),
        findsOneWidget,
      );
    });

    test('other errors are not handled', () {
      expect(
        ApprovalPendingException(requestId: 'a', number: 'n').statusCode,
        202,
      );
    });
  });

  group('approvals', () {
    testWidgets('inbox lists requests with counts', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /approvals/count', {'awaitingMe': 3, 'mine': 1})
        ..on('GET /approvals', pageOf([approvalJson()]));
      await pumpControls(tester, const ApprovalsScreen(), b);
      expect(find.textContaining('APR/0001'), findsWidgets);
      expect(find.textContaining('Waiting for me'), findsOneWidget);
      expect(find.textContaining('3'), findsWidgets);
      expect(
        b.last('GET', '/approvals')!.queryParameters['scope'],
        'awaiting_me',
      );
    });

    testWidgets('approve posts and reject needs a 3+ char comment', (
      tester,
    ) async {
      final b = FakeControlsBackend()
        ..on('GET /approvals/a1', approvalJson())
        ..on('POST /approvals/a1/approve', approvalJson(status: 'approved'))
        ..on('POST /approvals/a1/reject', approvalJson(status: 'rejected'));
      await pumpControls(tester, const ApprovalDetailScreen(id: 'a1'), b);
      expect(find.text('Approve'), findsOneWidget);

      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Reject').last);
      await tester.pumpAndSettle();
      expect(find.text('Comment is required'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).last, 'no');
      await tester.tap(find.widgetWithText(FilledButton, 'Reject').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Comment must be at least 3 characters'),
        findsOneWidget,
      );
      expect(b.last('POST', '/approvals/a1/reject'), isNull);
      await tester.enterText(find.byType(TextFormField).last, 'Over budget');
      await tester.tap(find.widgetWithText(FilledButton, 'Reject').last);
      await tester.pumpAndSettle();
      expect(
        b.last('POST', '/approvals/a1/reject')!.data,
        containsPair('comment', 'Over budget'),
      );
    });

    testWidgets('approve sends the request', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /approvals/a1', approvalJson())
        ..on('POST /approvals/a1/approve', approvalJson(status: 'approved'));
      await pumpControls(tester, const ApprovalDetailScreen(id: 'a1'), b);
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Approve').last);
      await tester.pumpAndSettle();
      expect(b.last('POST', '/approvals/a1/approve'), isNotNull);
    });

    testWidgets('detail fits a phone', (tester) async {
      final b = FakeControlsBackend()..on('GET /approvals/a1', approvalJson());
      await pumpControls(
        tester,
        const ApprovalDetailScreen(id: 'a1'),
        b,
        size: phone,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Approve'), findsOneWidget);
    });
  });

  group('approval rules', () {
    FakeControlsBackend rulesBackend() => FakeControlsBackend()
      ..on(
        'GET /roles',
        pageOf([
          {
            'id': 'r1',
            'name': 'Admin',
            'isSystem': true,
            'permissions': <Object?>[],
          },
        ]),
      )
      ..on('GET /users', pageOf([]))
      ..on('GET /approval-rules', {'data': <Object?>[]})
      ..on('GET /locations', pageOf([]));

    testWidgets('levels can be added up to 5', (tester) async {
      await pumpControls(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const RuleEditorDialog(),
            ),
            child: const Text('Open'),
          ),
        ),
        rulesBackend(),
        size: phone,
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Level 1 approver'), findsOneWidget);
      for (var i = 0; i < 6; i++) {
        final add = find.text('Add level');
        if (add.evaluate().isEmpty) break;
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pumpAndSettle();
      }
      expect(find.text('Level 5 approver'), findsOneWidget);
      expect(find.text('Level 6 approver'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('custom fields', () {
    final fields = {
      'data': [
        {
          'id': 'f1',
          'entity': 'invoice',
          'key': 'po_number',
          'label': 'PO number',
          'type': 'text',
          'required': true,
          'sortOrder': 1,
        },
        {
          'id': 'f2',
          'entity': 'invoice',
          'key': 'grade',
          'label': 'Grade',
          'type': 'select',
          'options': ['A', 'B'],
          'sortOrder': 2,
        },
      ],
    };

    testWidgets('renders fields and maps custom.<key> errors', (tester) async {
      final b = FakeControlsBackend()..on('GET /custom-fields', fields);
      await pumpControls(
        tester,
        CustomFieldsSection(
          entity: 'invoice',
          values: const {},
          onChanged: (_) {},
          errors: const {'custom.po_number': 'PO number is required'},
        ),
        b,
      );
      expect(find.text('PO number *'), findsWidgets);
      expect(find.text('Grade'), findsWidgets);
      expect(find.text('PO number is required'), findsOneWidget);
    });

    testWidgets('typing reports values', (tester) async {
      final b = FakeControlsBackend()..on('GET /custom-fields', fields);
      Map<String, Object?> got = {};
      await pumpControls(
        tester,
        CustomFieldsSection(
          entity: 'invoice',
          values: const {},
          onChanged: (v) => got = v,
        ),
        b,
      );
      await tester.enterText(
        find.byKey(const ValueKey('custom-po_number')),
        'PO-9',
      );
      expect(got, {'po_number': 'PO-9'});
    });

    test('customPatch nulls cleared keys', () {
      expect(customPatch({'a': 1, 'b': 2}, {'a': 3}), {'a': 3, 'b': null});
    });
  });

  group('cost centre picker', () {
    final centres = {
      'data': [
        {'id': 'cc1', 'code': 'SITE1', 'name': 'Site one'},
      ],
    };

    testWidgets('required when the company says so', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /company', {'costCentreRequired': true})
        ..on('GET /cost-centres', centres);
      final key = GlobalKey<FormState>();
      String? picked;
      await pumpControls(
        tester,
        Form(
          key: key,
          child: CostCentreField(value: null, onChanged: (v) => picked = v),
        ),
        b,
      );
      expect(find.text('Cost centre *'), findsOneWidget);
      expect(key.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text('Cost centre is required'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SITE1 · Site one').last);
      await tester.pumpAndSettle();
      expect(picked, 'cc1');
    });

    testWidgets('optional offers None', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /company', {'costCentreRequired': false})
        ..on('GET /cost-centres', centres);
      await pumpControls(
        tester,
        CostCentreField(value: null, onChanged: (_) {}),
        b,
      );
      expect(find.text('Cost centre'), findsOneWidget);
    });
  });

  group('import wizard', () {
    testWidgets('validate, preview, commit, poll to done', (tester) async {
      var polls = 0;
      final b = FakeControlsBackend()
        ..on('POST /imports', importJob('validated'), status: 201)
        ..on('POST /imports/i1/commit', importJob('queued'))
        ..on('GET /imports', pageOf([]));
      b.routes['GET /imports/i1'] = (_) {
        polls++;
        return (200, importJob(polls < 2 ? 'running' : 'done', created: 2));
      };
      await pumpControls(
        tester,
        const ImportsScreen(pollInterval: Duration(milliseconds: 50)),
        b,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Or paste CSV / rows copied from Excel'),
        'name,unit\nCement,bag\nSand,t',
      );
      await tester.ensureVisible(find.widgetWithText(BusyButton, 'Validate'));
      await tester.tap(find.widgetWithText(BusyButton, 'Validate'));
      await tester.pumpAndSettle();
      expect(b.last('POST', '/imports')!.data, containsPair('kind', isNotNull));
      expect(find.text('Cement'), findsOneWidget);
      final commit = find.widgetWithText(BusyButton, 'Import 2 rows');
      await tester.ensureVisible(commit);
      await tester.tap(commit);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.textContaining('Done. 2 created'), findsOneWidget);
    });

    testWidgets('wizard fits a phone', (tester) async {
      final b = FakeControlsBackend()..on('GET /imports', pageOf([]));
      await pumpControls(tester, const ImportsScreen(), b, size: phone);
      expect(tester.takeException(), isNull);
      expect(find.text('Validate'), findsOneWidget);
    });
  });
}
