/// Financial-year aware periods for reports, ledgers and the day book.
/// Pure Dart so it can be unit-tested.
library;

import '../../core/money.dart';

/// Today without the time of day.
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// 1 April of the financial year (April–March) that contains [d].
DateTime financialYearStart(DateTime d) =>
    DateTime(d.month >= 4 ? d.year : d.year - 1, 4, 1);

/// 31 March that ends the financial year containing [d].
DateTime financialYearEnd(DateTime d) =>
    DateTime(financialYearStart(d).year + 1, 3, 31);

/// `FY 2026-27` for any date between 1 Apr 2026 and 31 Mar 2027.
String financialYearLabel(DateTime d) {
  final start = financialYearStart(d).year;
  return 'FY $start-${((start + 1) % 100).toString().padLeft(2, '0')}';
}

/// An inclusive date range (dates only).
class DateRange {
  DateRange(DateTime from, DateTime to)
    : from = dateOnly(from.isAfter(to) ? to : from),
      to = dateOnly(from.isAfter(to) ? from : to);

  /// 1 April of the current financial year up to [today].
  factory DateRange.fyToDate([DateTime? today]) {
    final now = dateOnly(today ?? DateTime.now());
    return DateRange(financialYearStart(now), now);
  }

  final DateTime from;
  final DateTime to;

  String get apiFrom => apiDate(from);
  String get apiTo => apiDate(to);

  /// `01 Apr 2026 – 21 Oct 2026`.
  String get label => '${formatDate(from)} – ${formatDate(to)}';

  bool contains(DateTime d) {
    final day = dateOnly(d);
    return !day.isBefore(from) && !day.isAfter(to);
  }

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'DateRange($apiFrom..$apiTo)';
}

/// Quick choices offered by the period pickers.
enum RangePreset {
  fyToDate('Financial year to date'),
  thisMonth('This month'),
  lastMonth('Last month'),
  thisQuarter('This quarter'),
  lastFy('Last financial year'),
  today('Today');

  const RangePreset(this.label);

  final String label;

  DateRange resolve([DateTime? today]) {
    final now = dateOnly(today ?? DateTime.now());
    switch (this) {
      case RangePreset.fyToDate:
        return DateRange.fyToDate(now);
      case RangePreset.thisMonth:
        return DateRange(DateTime(now.year, now.month), now);
      case RangePreset.lastMonth:
        final first = DateTime(now.year, now.month - 1);
        return DateRange(first, DateTime(now.year, now.month, 0));
      case RangePreset.thisQuarter:
        // Financial-year quarters start in April, July, October and January
        // — the same months as calendar quarters.
        final month = ((now.month - 1) ~/ 3) * 3 + 1;
        return DateRange(DateTime(now.year, month), now);
      case RangePreset.lastFy:
        final start = financialYearStart(now);
        return DateRange(
          DateTime(start.year - 1, 4, 1),
          DateTime(start.year, 3, 31),
        );
      case RangePreset.today:
        return DateRange(now, now);
    }
  }
}

/// Quick choices for "as of" reports.
enum AsOfPreset {
  today('Today'),
  endOfLastMonth('End of last month'),
  endOfLastFy('End of last financial year');

  const AsOfPreset(this.label);

  final String label;

  DateTime resolve([DateTime? today]) {
    final now = dateOnly(today ?? DateTime.now());
    return switch (this) {
      AsOfPreset.today => now,
      AsOfPreset.endOfLastMonth => DateTime(now.year, now.month, 0),
      AsOfPreset.endOfLastFy => DateTime(financialYearStart(now).year, 3, 31),
    };
  }
}
