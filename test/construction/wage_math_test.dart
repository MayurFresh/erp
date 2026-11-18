import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/construction/models/labour_models.dart';
import 'package:onematrix/features/construction/models/wage_math.dart';

void main() {
  group('wage maths (API.md v1.2)', () {
    test('OT = otHours × dailyRate ÷ 8 × 2', () {
      expect(overtimePay(4, 800), 800);
      expect(overtimePay(1.5, 650), 243.75);
      expect(overtimePay(0, 800), 0);
      // ₹733 / 8 × 2 × 1 h = 183.25
      expect(overtimePay(1, 733), 183.25);
    });

    test('basic, gross and net round to paise', () {
      expect(basicPay(5.5, 800), 4400);
      expect(basicPay(3, 333.33), 999.99);
      expect(grossPay(5.5, 4, 800), 5200);
      expect(netPay(5200, 500), 4700);
      expect(roundPaise(2.675), 2.68);
      expect(roundPaise(-2.675), -2.68);
      expect(roundPaise(0.1 + 0.2), 0.3);
    });

    test('present days count half days as 0.5', () {
      expect(
        presentDaysOf([
          AttendanceStatus.present,
          AttendanceStatus.halfDay,
          AttendanceStatus.absent,
          null,
          AttendanceStatus.present,
        ]),
        2.5,
      );
    });

    test('explanations for the wage sheet', () {
      expect(overtimeExplanation(2, 800), '2 h × ₹800.00 ÷ 8 × 2 = ₹400.00');
      expect(basicExplanation(5.5, 800), '5.5 days × ₹800.00 = ₹4,400.00');
      expect(formatDays(3), '3');
    });

    test('totals use edited advances and flag excess advances', () {
      const a = WageRow(
        workerId: 'w1',
        workerName: 'A',
        presentDays: 5,
        otHours: 2,
        basic: 4000,
        otAmount: 400,
        gross: 4400,
        advance: 500,
        net: 3900,
      );
      const b = WageRow(
        workerId: 'w2',
        workerName: 'B',
        presentDays: 2.5,
        basic: 1500,
        gross: 1500,
        net: 1500,
      );
      final saved = WageTotals.of([a, b]);
      expect(saved.workers, 2);
      expect(saved.days, 7.5);
      expect(saved.gross, 5900);
      expect(saved.advance, 500);
      expect(saved.net, 5400);

      final edited = WageTotals.of([a, b], {'w2': 250.5});
      expect(edited.advance, 750.5);
      expect(edited.net, 5149.5);

      expect(const WageRowView(a, 500).advanceChanged, isFalse);
      expect(const WageRowView(a, 600).advanceChanged, isTrue);
      expect(const WageRowView(a, 4400.01).advanceTooHigh, isTrue);
      expect(const WageRowView(a, 4400).advanceTooHigh, isFalse);
    });
  });

  group('attendance summary', () {
    AttendanceRow row(AttendanceStatus? s, [double ot = 0]) => AttendanceRow(
      workerId: '$s$ot',
      workerName: 'x',
      status: s,
      otHours: ot,
    );

    test('counts statuses, OT and man-days', () {
      final summary = AttendanceSummary.of([
        row(AttendanceStatus.present, 2),
        row(AttendanceStatus.present),
        row(AttendanceStatus.halfDay, 1.5),
        row(AttendanceStatus.absent, 3), // OT of absent workers is ignored
        row(null),
      ]);
      expect(summary.present, 2);
      expect(summary.halfDay, 1);
      expect(summary.absent, 1);
      expect(summary.unmarked, 1);
      expect(summary.total, 5);
      expect(summary.marked, 4);
      expect(summary.onSite, 3);
      expect(summary.manDays, 2.5);
      expect(summary.otHours, 3.5);
    });

    test('entries skip unmarked rows and zero OT when absent', () {
      expect(row(null).toEntry(), isNull);
      expect(row(AttendanceStatus.absent, 2).toEntry(), {
        'workerId': 'AttendanceStatus.absent2.0',
        'status': 'absent',
        'otHours': 0,
      });
      expect(row(AttendanceStatus.halfDay, 1).toEntry()!['status'], 'half_day');
    });
  });
}
