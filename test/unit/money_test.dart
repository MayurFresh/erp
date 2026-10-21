import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/money.dart';

void main() {
  group('formatMoney', () {
    test('uses Indian digit grouping and two decimals', () {
      expect(formatMoney(123456.5), '₹1,23,456.50');
      expect(formatMoney(10000000), '₹1,00,00,000.00');
      expect(formatMoney(999), '₹999.00');
      expect(formatMoney(0), '₹0.00');
      expect(formatMoney(null), '₹0.00');
    });

    test('handles negatives and paise', () {
      expect(formatMoney(-0.4), '-₹0.40');
      expect(formatMoney(1234.567), '₹1,234.57');
    });
  });

  group('formatQty', () {
    test('drops trailing zeros and keeps up to 3 decimals', () {
      expect(formatQty(2), '2');
      expect(formatQty(1234.5), '1,234.5');
      expect(formatQty(0.125), '0.125');
      expect(formatQty(123456.789), '1,23,456.789');
    });
  });

  test('formatPercent and formatPlain', () {
    expect(formatPercent(18), '18%');
    expect(formatPercent(0.25), '0.25%');
    expect(formatPlain(100), '100');
    expect(formatPlain(12.5), '12.5');
    expect(formatPlain(null), '');
  });

  test('dates', () {
    expect(apiDate(DateTime(2026, 4, 1)), '2026-04-01');
    expect(formatDate('2026-10-21'), '21 Oct 2026');
    expect(formatDate(null), '');
  });
}
