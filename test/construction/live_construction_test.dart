// End-to-end test of the construction pack against a running backend,
// through the app's real ApiClient, the HTTP bridge and the repositories.
// Skipped unless PROGEN_API is set:
//
//   PROGEN_API=http://localhost:8080/api/v1 \
//     flutter test test/construction/live_construction_test.dart
//
// It signs up a fresh business (so the demo company is untouched) and walks
// project → BOQ → indent → issue → DPR with photo → workers → attendance →
// wage sheet → pay. Uses plain `test` so real HTTP is allowed.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show DateUtils;
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/api_client.dart';
import 'package:progen_erp/core/api_exception.dart';
import 'package:progen_erp/core/money.dart';
import 'package:progen_erp/core/token_store.dart';
import 'package:progen_erp/features/auth/auth_models.dart';
import 'package:progen_erp/features/auth/auth_repository.dart';
import 'package:progen_erp/features/construction/data/construction_http.dart';
import 'package:progen_erp/features/construction/data/construction_repository.dart';
import 'package:progen_erp/features/construction/data/photo_source.dart';
import 'package:progen_erp/features/construction/data/subcontract_repository.dart';
import 'package:progen_erp/features/construction/models/boq_paste.dart';
import 'package:progen_erp/features/construction/models/dpr_models.dart';
import 'package:progen_erp/features/construction/models/labour_models.dart';
import 'package:progen_erp/features/construction/models/material_models.dart';
import 'package:progen_erp/features/construction/models/wage_math.dart';

void main() {
  final baseUrl = Platform.environment['PROGEN_API'];

  group(
    'live construction API',
    skip: baseUrl == null || baseUrl.isEmpty
        ? 'Set PROGEN_API (e.g. http://localhost:8080/api/v1) to run'
        : false,
    () {
      late ApiClient api;
      late ConstructionHttp http;
      late ConstructionRepository repo;

      setUpAll(() {
        api = ApiClient(baseUrl: baseUrl!, tokenStore: InMemoryTokenStore());
        http = BridgedConstructionHttp(api);
        repo = ConstructionRepository(api, http);
      });

      tearDownAll(() {
        http.close();
        api.close();
      });

      Future<Object> apiError(Future<Object?> Function() call) async {
        try {
          await call();
        } on ApiException catch (e) {
          return e;
        }
        fail('expected an ApiException');
      }

      test('project → BOQ → indent → issue → DPR → labour → wages', () async {
        final stamp = DateTime.now().microsecondsSinceEpoch;
        final auth = AuthRepository(api);
        await auth.signup(
          SignupRequest(
            businessName: 'Live Construction $stamp',
            name: 'Live Tester',
            email: 'live-c$stamp@example.com',
            password: 'LiveTest@123',
            stateCode: '29',
          ),
        );
        await api.setCompany((await auth.me()).companies.first.id);

        // Masters through the core endpoints.
        final site = await api.postJson(
          '/locations',
          body: {'type': 'site', 'name': 'Live Site $stamp'},
        );
        final siteId = site['id'] as String;
        final item = await api.postJson(
          '/items',
          body: {
            'name': 'Cement $stamp',
            'unit': 'bag',
            'gstRate': 18,
            'salePrice': 420,
            'purchasePrice': 380,
          },
        );
        final itemId = item['id'] as String;
        await api.postJson(
          '/stock/adjustments',
          body: {
            'locationId': siteId,
            'itemId': itemId,
            'qty': 100,
            'rate': 380,
            'isOpening': true,
          },
        );
        final contractor = await api.postJson(
          '/parties',
          body: {'type': 'vendor', 'name': 'Labour Contractor $stamp'},
        );

        // Project with the site, BOQ pasted from a spreadsheet.
        final project = await repo.createProject({
          'code': 'P$stamp'.substring(0, 12),
          'name': 'Live Tower $stamp',
          'status': 'active',
          'contractValue': 5000000,
          'siteIds': [siteId],
        });
        expect(project.sites.single.id, siteId);
        final paste = parseBoqPaste(
          'Code\tDescription\tUnit\tQty\tRate\tMaterial\n'
          '1.1\tExcavation\tcum\t100\t450\t10000\n'
          '1.2\tPCC 1:4:8\tcum\t20\t5200\t60000\n'
          '9.9\tSpare line\tnos\t1\t1\n',
        );
        expect(paste.canImport, isTrue);
        final added = await repo.addBoqLines(project.id, paste.lines);
        expect(added, hasLength(3));
        final boq = await repo.boq(project.id);
        expect(boq.map((l) => l.code), ['1.1', '1.2', '9.9']);
        final excavation = boq.first;
        final pcc = boq[1];
        await repo.deleteBoqLine(boq.last.id); // DELETE via the bridge

        // Indent: create + submit in one request, approve less, close.
        final indent = await repo.createIndent(
          IndentDraft(
            locationId: siteId,
            submit: true,
            lines: [
              IndentLineDraft(itemId: itemId, qty: 50, boqLineId: pcc.id),
            ],
          ),
        );
        expect(indent.status, IndentStatus.submitted);
        expect(indent.projectId, project.id);
        final approved = await repo.approveIndent(indent.id, {
          indent.lines.single.id: 40,
        });
        expect(approved.status, IndentStatus.approved);
        expect(approved.lines.single.approvedQty, 40);
        expect((await repo.closeIndent(indent.id)).status, IndentStatus.closed);

        // Material issue; too much is INSUFFICIENT_STOCK.
        final issue = await repo.createIssue(
          IssueDraft(
            locationId: siteId,
            boqLineId: pcc.id,
            lines: [(itemId: itemId, qty: 10)],
          ),
        );
        expect(issue.boqCode, '1.2');
        expect(issue.totalValue, 3800);
        final short = await apiError(
          () => repo.createIssue(
            IssueDraft(
              locationId: siteId,
              lines: [(itemId: itemId, qty: 1000)],
            ),
          ),
        );
        expect((short as ApiException).code, ApiException.insufficientStock);
        final inUse = await apiError(() => repo.deleteBoqLine(pcc.id));
        expect((inUse as ApiException).code, 'IN_USE');

        // DPR with an uploaded photo; the bytes come back through the bridge.
        final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        );
        final file = await repo.uploadPhoto(
          PickedPhoto(name: 'site.png', mimeType: 'image/png', bytes: png),
        );
        expect(file.mimeType, 'image/png');
        expect(await repo.fileBytes(file.id), png);
        final dpr = await repo.createDpr(
          DprDraft(
            locationId: siteId,
            date: apiDate(DateTime.now()),
            weather: 'sunny',
            workDone: [
              DprWork(
                boqLineId: excavation.id,
                description: excavation.description,
                qty: 25,
              ),
            ],
            labour: const [DprLabour(trade: 'mason', count: 4)],
            equipment: const [DprEquipment(name: 'JCB', hours: 6.5)],
            photos: [DprPhoto(fileId: file.id, caption: 'Pit 1')],
            submit: true,
          ),
        );
        expect(dpr.status, DprStatus.submitted);
        expect(dpr.workDone.single.unit, 'cum'); // filled from the BOQ line
        final rejected = await repo.rejectDpr(dpr.id, 'Add the JCB log');
        expect(rejected.rejectReason, 'Add the JCB log');
        await repo.submitDpr(dpr.id);
        expect((await repo.approveDpr(dpr.id)).status, DprStatus.approved);
        expect((await repo.previousDpr(siteId))?.id, dpr.id);
        final progressed = await repo.boq(project.id);
        expect(progressed.first.executedQty, 25);

        // Workers and attendance (PUT via the bridge) for yesterday.
        final w1 = await repo.createWorker({
          'name': 'Ramesh $stamp',
          'trade': 'mason',
          'skill': 'skilled',
          'dailyRate': 800,
          'contractorPartyId': contractor['id'],
          'siteId': siteId,
          'aadhaarLast4': '1234',
        });
        final w2 = await repo.createWorker({
          'name': 'Suresh $stamp',
          'trade': 'helper',
          'dailyRate': 600,
          'siteId': siteId,
        });
        expect(w1.contractorName, 'Labour Contractor $stamp');
        final day = apiDate(
          DateUtils.dateOnly(DateTime.now()).subtract(const Duration(days: 1)),
        );
        final sheet = await repo.attendance(siteId, day);
        expect(sheet.rows.map((r) => r.workerId), containsAll([w1.id, w2.id]));
        final saved = await repo.saveAttendance(siteId, day, [
          for (final row in sheet.rows)
            row.workerId == w1.id
                ? row.copyWith(status: AttendanceStatus.present, otHours: 2)
                : row.copyWith(status: AttendanceStatus.halfDay),
        ]);
        expect(AttendanceSummary.of(saved.rows).manDays, 1.5);

        // Wage sheet: maths, advance, approve (locks attendance), pay.
        final wages = await repo.createWageSheet(
          siteId: siteId,
          from: day,
          to: day,
        );
        final r1 = wages.rows!.firstWhere((r) => r.workerId == w1.id);
        expect(r1.basic, basicPay(1, 800));
        expect(r1.otAmount, overtimePay(2, 800));
        expect(r1.gross, grossPay(1, 2, 800));
        final accounts = await repo.cashAndBankAccounts();
        final cash = accounts.firstWhere((a) => a.subtype == 'cash');
        // Since v1.3 a wage-sheet advance must recover a registered labour advance.
        await SubcontractRepository(api).createLabourAdvance(
          workerId: w1.id,
          amount: 200,
          paidFromAccountId: cash.id,
        );
        final withAdvance = await repo.saveAdvances(wages.id, {w1.id: 200});
        expect(
          withAdvance.rows!.firstWhere((r) => r.workerId == w1.id).net,
          netPay(r1.gross, 200),
        );
        await repo.approveWageSheet(wages.id);
        final locked = await apiError(
          () => repo.saveAttendance(siteId, day, saved.rows),
        );
        expect((locked as ApiException).code, 'LOCKED');
        expect((await repo.attendance(siteId, day)).locked, isTrue);
        final paid = await repo.payWageSheet(
          wages.id,
          paidFromAccountId: cash.id,
        );
        expect(paid.status, WageSheetStatus.paid);

        // Costs: issued material and paid wages show up as actuals.
        final costs = await repo.costs(project.id);
        expect(costs.actual.material, 3800);
        expect(costs.actual.labour, withAdvance.totalGross);
        expect(costs.budget.material, 70000);
      });
    },
  );
}
