@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/api_client.dart';
import 'package:progen_erp/core/api_exception.dart';
import 'package:progen_erp/core/token_store.dart';
import 'package:progen_erp/features/auth/auth_repository.dart';
import 'package:progen_erp/features/filings/filings_repository.dart';
import 'package:progen_erp/features/fixed_assets/fa_repository.dart';
import 'package:progen_erp/features/gst_filing/gst_filing_repository.dart';
import 'package:progen_erp/features/income_tax/it_repository.dart';

/// v1.6 client models against the real API and the seeded demo company. The models parse
/// leniently, so these tests check seeded values, not just that nothing threw.
void main() {
  final baseUrl = Platform.environment['PROGEN_API'];

  group(
    'live self-filing',
    skip: baseUrl == null || baseUrl.isEmpty
        ? 'Set PROGEN_API (e.g. http://localhost:8080/api/v1) to run'
        : false,
    () {
      late ApiClient api;
      late FilingsRepository filings;
      late GstFilingRepository gst;
      late IncomeTaxRepository tax;
      late FixedAssetRepository assets;
      const fy = '2026-27';

      setUpAll(() async {
        api = ApiClient(baseUrl: baseUrl!, tokenStore: InMemoryTokenStore());
        final auth = AuthRepository(api);
        await auth.login('owner@demo.in', 'Demo@1234');
        await api.setCompany((await auth.me()).companies.first.id);
        filings = FilingsRepository(api);
        gst = GstFilingRepository(api);
        tax = IncomeTaxRepository(api);
        assets = FixedAssetRepository(api);
      });

      tearDownAll(() => api.close());

      test('filing register and calendar', () async {
        final list = await filings.list(fy: fy);
        expect(list.map((f) => f.returnType), containsAll(['gstr1', 'gstr3b']));
        expect(
          list.every((f) => f.period.isNotEmpty && f.status.isNotEmpty),
          isTrue,
        );
        final cal = await filings.calendar(fy);
        expect(cal, isNotEmpty);
        expect(
          cal.every(
            (r) => r.dueDate.toString().isNotEmpty && r.label.isNotEmpty,
          ),
          isTrue,
        );
        expect(cal.map((r) => r.returnType), contains('advance_tax'));
      });

      test('GST wizard data', () async {
        final period = (await filings.list(returnType: 'gstr3b')).first.period;
        final checks = await gst.prefile(period, 'gstr3b');
        expect(checks.checks, isNotEmpty);
        expect(
          checks.checks.every((c) => c.id.isNotEmpty && c.title.isNotEmpty),
          isTrue,
        );
        final so = await gst.setoff(period, 'cgst_first');
        expect(so.creditOpening.cgst, 5000);
        expect((await gst.gstr3b(period)).toString(), isNotEmpty);
        expect(await gst.gstr1Gstn(period), contains('gstin'));
        expect(await gst.payments(fy), isNotEmpty);
        expect(await gst.ledgerBalances(), isNotEmpty);
        await gst.itcReversals(period);
        expect(await gst.itcReversalsCsv(period), isNotEmpty);
        await gst.gstr9(fy);
      });

      test('income tax and TDS', () async {
        final pays = await tax.payments(fy);
        expect(pays.single.amount, 50000);
        expect(pays.single.bsrCode, hasLength(7));
        final r = await tax.regime({
          'taxYear': fy,
          'age': 'below60',
          'business': 1500000,
        });
        expect(r.toString(), isNotEmpty);
        await tax.presumptive({
          'taxYear': fy,
          'kind': 'business',
          'digitalReceipts': 5000000,
          'cashReceipts': 0,
        });
        await tax.advanceTax(taxYear: fy, regime: 'new', presumptive: false);
        await tax.itrPack(fy, 'itr3');
        expect(await tax.itrPackCsv(fy, 'itr3'), isNotEmpty);
        await tax.caRequired(fy);
        final pre = await tax.tdsPrefile(fy, 2);
        expect(pre.checks, isNotEmpty);
        await tax.tdsDefaults(fy);
        try {
          expect(await tax.tdsStatementTxt(fy, 2), isNotEmpty);
        } on ApiException catch (e) {
          expect(e.code, 'PREFILE_FAILED');
        }
      });

      test('fixed assets', () async {
        expect(await assets.blocks(), hasLength(10));
        final page = await assets.list();
        expect(page.data, hasLength(5));
        expect(page.data.every((a) => a.name.isNotEmpty && a.cost > 0), isTrue);
        final one = await assets.asset(page.data.first.id);
        expect(one.id, page.data.first.id);
        final runs = await assets.runs(fy);
        expect(runs.single.total, greaterThan(0));
        final today = DateTime.now().toIso8601String().substring(0, 10);
        final preview = await assets.runDepreciation(
          toDate: today,
          preview: true,
        );
        expect(preview.id, isNull);
        expect(preview.lines, isNotEmpty);
        final schedule = await assets.itSchedule(fy);
        expect(schedule.rows, isNotEmpty);
      });
    },
  );
}
