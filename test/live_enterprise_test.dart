@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/api_client.dart';
import 'package:onematrix/core/token_store.dart';
import 'package:onematrix/features/auth/auth_repository.dart';
import 'package:onematrix/features/controls/controls_repository.dart';
import 'package:onematrix/features/platform/platform_repository.dart';

/// v1.7 client models against the real API and the seeded demo data (seed-platform.ts and
/// seed-controls.ts). Read-only, so the suite can run repeatedly.
void main() {
  final baseUrl = Platform.environment['ONEMATRIX_API'];

  group(
    'live enterprise',
    skip: baseUrl == null || baseUrl.isEmpty
        ? 'Set ONEMATRIX_API (e.g. http://localhost:8080/api/v1) to run'
        : false,
    () {
      late ApiClient api;
      late PlatformRepository platform;
      late ControlsRepository controls;

      Future<ApiClient> signIn(String email) async {
        final c = ApiClient(
          baseUrl: baseUrl!,
          tokenStore: InMemoryTokenStore(),
        );
        final auth = AuthRepository(c);
        await auth.login(email, 'Demo@1234');
        await c.setCompany((await auth.me()).companies.first.id);
        return c;
      }

      setUpAll(() async {
        api = await signIn('owner@demo.in');
        platform = PlatformRepository(api);
        controls = ControlsRepository(api);
      });

      tearDownAll(() => api.close());

      test('security, sessions and notifications', () async {
        final s = await platform.security();
        expect(s.twoFactorEnabled, isFalse);
        expect(s.mustEnrol2fa, isFalse);
        expect(await platform.sessions(), isNotEmpty);
        expect(await platform.unreadCount(), greaterThanOrEqualTo(0));
        expect(await platform.prefs(), isNotEmpty);
      });

      test('companies, inter-company and consolidation', () async {
        final cos = await platform.companies();
        expect(cos, hasLength(2));
        expect(cos.map((c) => c.name), contains('OneMatrix Infra Projects LLP'));

        final ice = await platform.intercompany();
        expect(ice.total, 1);
        expect(ice.data.single.amount, 25000);
        expect(ice.data.single.status, 'posted');

        final bal = await platform.intercompanyBalances();
        expect(bal.rows, isNotEmpty);
        expect(bal.unexplained, closeTo(0, 0.01));

        final tb = await platform.consolidated(
          'trial-balance',
          cos.map((c) => c.id).toList(),
        );
        expect(tb.companies, hasLength(2));
        final totals = tb.sections.single.totals;
        expect(totals[0].$2, greaterThan(0));
        expect(totals[0].$2, closeTo(totals[1].$2, 0.01));
      });

      test('cost centres and custom fields', () async {
        final cc = await controls.costCentres();
        expect(cc.map((c) => c.code), containsAll(['RET', 'PRJ', 'HO']));

        final report = await controls.costCentreReport();
        final prj = report.rows.firstWhere((r) => r.code == 'PRJ');
        expect(prj.income, greaterThan(0));
        expect(prj.expense, greaterThanOrEqualTo(12000));
        final ho = report.rows.firstWhere((r) => r.code == 'HO');
        expect(ho.expense, greaterThanOrEqualTo(6500));

        final fields = await controls.customFields(null);
        expect(
          fields.map((f) => '${f.entity}.${f.key}'),
          containsAll(['item.brand', 'party.region', 'invoice.po_number']),
        );
        expect(fields.firstWhere((f) => f.key == 'region').options, [
          'North',
          'South',
          'East',
          'West',
        ]);
      });

      test('pending approval and finished import', () async {
        final mine = await controls.approvals(scope: 'awaiting_me');
        final req = mine.data.firstWhere((r) => r.amount == 600000);
        expect(req.status, 'pending');
        expect(req.docType, 'payment');
        expect(req.canAct, isTrue);

        final acc = await signIn('accountant@demo.in');
        try {
          final theirs = await ControlsRepository(acc).approvals(scope: 'mine');
          expect(theirs.data.map((r) => r.id), contains(req.id));
        } finally {
          acc.close();
        }

        final imports = await controls.imports();
        final job = imports.data.firstWhere((j) => j.kind == 'items');
        expect(job.status, 'done');
        expect(job.created, 3);
      });

      test('GSP settings', () async {
        final g = await platform.gsp();
        // No live provider ships in v1.7; the sandbox is not listed.
        expect(g.mode, 'sandbox');
        expect(g.providers, isEmpty);
      });
    },
  );
}
