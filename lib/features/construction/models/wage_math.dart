/// Wage maths from the API contract, for previews and explanations. The
/// server's figures are authoritative; these only mirror them.
///
/// `basic = presentDays × dailyRate`;
/// `otAmount = otHours × dailyRate ÷ 8 × 2` (twice the ordinary hourly rate);
/// `gross = basic + otAmount`; `net = gross − advance`; each to paise.
library;

import '../../../core/money.dart';
import 'labour_models.dart';

/// Ordinary hours in a working day.
const double kWorkdayHours = 8;

/// Overtime is paid at this multiple of the ordinary hourly rate.
const double kOvertimeMultiplier = 2;

/// Rounds half away from zero to 2 decimals, tolerating binary noise
/// (`2.675` → `2.68`).
double roundPaise(num value) {
  final paise = value * 100;
  final nudged = paise + (paise >= 0 ? 1e-6 : -1e-6);
  return nudged.round() / 100;
}

double basicPay(num presentDays, num dailyRate) =>
    roundPaise(presentDays * dailyRate);

double overtimePay(num otHours, num dailyRate) =>
    roundPaise(otHours * dailyRate / kWorkdayHours * kOvertimeMultiplier);

double grossPay(num presentDays, num otHours, num dailyRate) => roundPaise(
  basicPay(presentDays, dailyRate) + overtimePay(otHours, dailyRate),
);

double netPay(num gross, num advance) => roundPaise(gross - advance);

/// Days for wages from a run of attendance statuses (half day = 0.5).
double presentDaysOf(Iterable<AttendanceStatus?> statuses) =>
    statuses.fold(0, (sum, s) => sum + (s?.days ?? 0));

/// `2.5` → `2.5`, `3` → `3`.
String formatDays(num days) => formatQty(days);

/// `2 h × ₹800.00 ÷ 8 × 2 = ₹400.00`.
String overtimeExplanation(num otHours, num dailyRate) =>
    '${formatQty(otHours)} h × ${formatMoney(dailyRate)} ÷ '
    '${formatQty(kWorkdayHours)} × ${formatQty(kOvertimeMultiplier)} = '
    '${formatMoney(overtimePay(otHours, dailyRate))}';

/// `5.5 days × ₹800.00 = ₹4,400.00`.
String basicExplanation(num presentDays, num dailyRate) =>
    '${formatDays(presentDays)} days × ${formatMoney(dailyRate)} = '
    '${formatMoney(basicPay(presentDays, dailyRate))}';

/// A wage row with an advance edited on the client (draft sheets).
class WageRowView {
  const WageRowView(this.row, this.advance);

  final WageRow row;
  final double advance;

  double get gross => row.gross;
  double get net => netPay(row.gross, advance);
  bool get advanceChanged => roundPaise(advance) != roundPaise(row.advance);

  /// Advance must not exceed gross (net cannot go negative).
  bool get advanceTooHigh => advance > row.gross + 0.004;
}

class WageTotals {
  const WageTotals({
    this.workers = 0,
    this.days = 0,
    this.otHours = 0,
    this.basic = 0,
    this.otAmount = 0,
    this.gross = 0,
    this.advance = 0,
    this.net = 0,
  });

  /// [advances] (workerId → amount) overrides the rows' saved advances.
  factory WageTotals.of(
    Iterable<WageRow> rows, [
    Map<String, double> advances = const {},
  ]) {
    var t = const WageTotals();
    for (final row in rows) {
      final advance = advances[row.workerId] ?? row.advance;
      t = WageTotals(
        workers: t.workers + 1,
        days: t.days + row.presentDays,
        otHours: t.otHours + row.otHours,
        basic: roundPaise(t.basic + row.basic),
        otAmount: roundPaise(t.otAmount + row.otAmount),
        gross: roundPaise(t.gross + row.gross),
        advance: roundPaise(t.advance + advance),
        net: roundPaise(t.net + netPay(row.gross, advance)),
      );
    }
    return t;
  }

  final int workers;
  final double days;
  final double otHours;
  final double basic;
  final double otAmount;
  final double gross;
  final double advance;
  final double net;
}
