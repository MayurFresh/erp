import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/features/construction/models/dpr_models.dart';
import 'package:progen_erp/features/construction/models/labour_models.dart';
import 'package:progen_erp/features/construction/models/material_models.dart';
import 'package:progen_erp/features/construction/models/project_models.dart';

import 'support/construction_fake_backend.dart';

/// fromJson against the API.md v1.2 shapes (the fake's fixtures follow the
/// backend's JSON), plus nulls and absent optional fields.
void main() {
  test('Project and BOQ line', () {
    final p = Project.fromJson(ConstructionFakeBackend.project());
    expect(p.code, 'PRJ-001');
    expect(p.status, ProjectStatus.active);
    expect(p.endDate, isNull);
    expect(p.sites.single.name, 'Site A — Tower 1');
    expect(p.hasSite('l2'), isTrue);
    expect(p.progressPct, 37.5);
    expect(p.toInputJson()['siteIds'], ['l2']);
    expect(ProjectStatus.parse('on_hold'), ProjectStatus.onHold);

    final bare = Project.fromJson({'id': 'x', 'code': 'C', 'name': 'N'});
    expect(bare.sites, isEmpty);
    expect(bare.clientName, isNull);
    expect(bare.status, ProjectStatus.planning);
    expect(bare.contractValue, 0);

    final b = BoqLine.fromJson(
      ConstructionFakeBackend.boqLine('b1', '1.1', 'Excavation'),
    );
    expect(b.amount, 54000);
    expect(b.label, '1.1 · Excavation');
    expect(b.toInput().toJson()['qty'], 120);
    expect(
      const BoqLineInput(
        code: 'a',
        description: 'b',
        unit: 'c',
        qty: 1,
        rate: 2,
      ).toJson().containsKey('materialBudget'),
      isFalse,
    );
  });

  test('ProjectCosts maps actual.expenses to other', () {
    final c = ProjectCosts.fromJson(ConstructionFakeBackend.costs());
    expect(c.budget.material, 40000);
    expect(c.actual.other, 2500);
    expect(c.actual.total, 60500);
    expect(c.byBoqLine.single.materialVariance, -6000);
    final empty = ProjectCosts.fromJson({'projectId': 'p'});
    expect(empty.byBoqLine, isEmpty);
    expect(empty.budget.total, 0);
  });

  test('Indent: statuses, rejection fields, fulfilment and bodies', () {
    final json = ConstructionFakeBackend.indent('i', 'IND/1', 'rejected')
      ..['rejectedBy'] = {'id': 'u2', 'name': 'Ravi'}
      ..['rejectReason'] = 'Too much';
    final i = Indent.fromJson(json);
    expect(i.status, IndentStatus.rejected);
    expect(i.rejectedBy?.name, 'Ravi');
    expect(i.approvedBy, isNull);
    expect(i.lines.single.approvedQty, isNull);
    expect(i.lines.single.target, 200);

    const line = IndentLine(
      id: 'l',
      itemId: 'i',
      itemName: 'Cement',
      unit: 'bag',
      qty: 200,
      approvedQty: 150,
      fulfilledQty: 75,
    );
    expect(line.fulfilmentPct, 50);
    expect(line.isFulfilled, isFalse);
    expect(
      const Indent(
        id: 'x',
        number: 'n',
        locationId: 'l',
        locationName: 'L',
        lines: [line],
      ).fulfilmentPct,
      50,
    );

    const draft = IndentDraft(
      locationId: 'l2',
      submit: true,
      lines: [IndentLineDraft(itemId: 'i1', qty: 10)],
    );
    expect(draft.toCreateJson(), {
      'locationId': 'l2',
      'submit': true,
      'lines': [
        {'itemId': 'i1', 'qty': 10.0},
      ],
    });
    expect(draft.toUpdateJson().containsKey('submit'), isFalse);
  });

  test('Issue: costs only with view_cost, cancellation fields', () {
    final i = Issue.fromJson(ConstructionFakeBackend.issue());
    expect(i.totalValue, 15100);
    expect(i.lines.single.costRate, 377.5);
    final noCost = Issue.fromJson(
      Map.of(ConstructionFakeBackend.issue())
        ..remove('totalValue')
        ..['lines'] = [
          {'itemId': 'i1', 'itemName': 'Cement', 'unit': 'bag', 'qty': 4},
        ]
        ..['status'] = 'cancelled'
        ..['cancelReason'] = 'Wrong site'
        ..['cancelledAt'] = '2026-10-28T05:00:00.000Z',
    );
    expect(noCost.totalValue, isNull);
    expect(noCost.lines.single.value, isNull);
    expect(noCost.isCancelled, isTrue);
    expect(noCost.cancelReason, 'Wrong site');
    expect(noCost.cancelledAt, isNotNull);
  });

  test('DPR: children, rejection, and request bodies', () {
    final d = Dpr.fromJson(ConstructionFakeBackend.dpr());
    expect(d.labourTotal, 16);
    expect(d.equipmentHours, 6.5);
    expect(d.photos.single.caption, 'Column C4');
    expect(d.workDone.single.boqCode, '1.1');
    expect(weatherLabel(d.weather), 'Sunny');

    final rejected = Dpr.fromJson({
      ...ConstructionFakeBackend.dpr(),
      'status': 'rejected',
      'rejectReason': 'Photos missing',
      'rejectedBy': {'id': 'u2', 'name': 'Ravi'},
    });
    expect(rejected.isRejected, isTrue);
    expect(rejected.rejectedBy?.name, 'Ravi');

    final bare = Dpr.fromJson({'id': 'd', 'date': '2026-10-01'});
    expect(bare.workDone, isEmpty);
    expect(bare.weather, isNull);
    expect(bare.status, DprStatus.draft);

    const draft = DprDraft(
      locationId: 'l2',
      date: '2026-10-28',
      workDone: [DprWork(description: 'Shuttering')],
      labour: [
        DprLabour(trade: 'mason', count: 4),
        DprLabour(trade: 'helper', count: 0),
      ],
      equipment: [DprEquipment(name: ' ', hours: 2)],
      photos: [DprPhoto(fileId: 'f1')],
      submit: true,
    );
    final create = draft.toCreateJson();
    // optionalText fields reject null, so they are omitted on create.
    expect(create.containsKey('weather'), isFalse);
    expect(create['labour'], [
      {'trade': 'mason', 'count': 4},
    ]);
    expect(create['equipment'], isEmpty);
    expect(create['photos'], [
      {'fileId': 'f1'},
    ]);
    expect(create['workDone'], [
      {'description': 'Shuttering'},
    ]);
    expect(create['submit'], isTrue);
    final patch = draft.toPatchJson();
    expect(patch.containsKey('weather'), isTrue); // null clears on PATCH
    expect(patch['submit'], isTrue);
  });

  test('Worker, attendance sheet and wage sheet', () {
    final w = Worker.fromJson(ConstructionFakeBackend.worker('w', 'Ram'));
    expect(w.trade, Trade.mason);
    expect(w.skill, Skill.skilled);
    expect(w.toInputJson()['photoFileId'], isNull);
    expect(Trade.parse('bar_bender'), Trade.barBender);
    expect(tradeLabel('crane_operator'), 'Crane operator');
    final bare = Worker.fromJson({'id': 'w', 'name': 'X'});
    expect(bare.contractorName, isNull);
    expect(bare.isActive, isTrue);

    final sheet = AttendanceSheet.fromJson(
      ConstructionFakeBackend().attendanceSheet('2026-10-27'),
    );
    expect(sheet.locked, isFalse);
    expect(sheet.rows.first.status, AttendanceStatus.present);
    expect(sheet.rows.last.status, isNull);

    final wage = WageSheet.fromJson(ConstructionFakeBackend.wageSheet());
    expect(wage.isDraft, isTrue);
    expect(wage.rows!.single.presentDays, 5.5);
    final listRow = WageSheet.fromJson(
      Map.of(ConstructionFakeBackend.wageSheet())..remove('rows'),
    );
    expect(listRow.rows, isNull);
    expect(WageSheetStatus.parse('paid'), WageSheetStatus.paid);
  });
}
