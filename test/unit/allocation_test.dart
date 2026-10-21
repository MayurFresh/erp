import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/features/expenses/expense_model.dart';
import 'package:progen_erp/features/payments/allocation.dart';
import 'package:progen_erp/features/payments/payment_model.dart';

void main() {
  const docs = [
    OpenDoc(
      id: 'b',
      number: 'INV/2',
      date: '2026-10-05',
      total: 500,
      amountDue: 300.10,
    ),
    OpenDoc(
      id: 'a',
      number: 'INV/1',
      date: '2026-09-01',
      total: 1000,
      amountDue: 1000,
    ),
    OpenDoc(
      id: 'c',
      number: 'INV/3',
      date: '2026-10-05',
      total: 200,
      amountDue: 200,
    ),
    OpenDoc(
      id: 'paid',
      number: 'INV/0',
      date: '2026-08-01',
      total: 50,
      amountDue: 0,
    ),
  ];

  group('autoAllocate', () {
    test('fills oldest first up to the amount', () {
      expect(autoAllocate(docs, 1200.05), {'a': 1000.0, 'b': 200.05});
    });

    test('same date keeps the server order', () {
      expect(autoAllocate(docs, 1400), {'a': 1000.0, 'b': 300.10, 'c': 99.9});
    });

    test('more than everything due leaves the rest unallocated', () {
      final result = autoAllocate(docs, 2000);
      expect(result, {'a': 1000.0, 'b': 300.10, 'c': 200.0});
      expect(allocatedTotal(result), 1500.10);
      expect(unallocatedAmount(2000, result), 499.90);
    });

    test('a preferred document is settled first', () {
      expect(autoAllocate(docs, 250, firstId: 'c'), {'c': 200.0, 'a': 50.0});
    });

    test('zero or negative amount allocates nothing', () {
      expect(autoAllocate(docs, 0), isEmpty);
      expect(autoAllocate(docs, -5), isEmpty);
      expect(autoAllocate(const [], 100), isEmpty);
    });
  });

  group('validation', () {
    test('each allocation must be within its due', () {
      expect(allocationError(docs[0], 300.10), isNull);
      expect(allocationError(docs[0], 300.11), 'More than due');
      expect(allocationError(docs[0], -1), 'Cannot be negative');
      expect(allocationError(docs[0], null), isNull);
    });

    test('the sum must not exceed the amount', () {
      expect(allocationsError(docs, {'a': 600, 'b': 300.10}, 900.10), isNull);
      expect(
        allocationsError(docs, {'a': 600, 'b': 300.10}, 900),
        'Allocations add up to more than the amount',
      );
      expect(
        allocationsError(docs, {'a': 1000.01}, 5000),
        'INV/1: More than due',
      );
      expect(allocationsError(docs, {'zzz': 1}, 5), 'Unknown document');
    });

    test('unallocated never goes negative', () {
      expect(unallocatedAmount(100, {'a': 150}), 0);
    });
  });

  group('estimateExpenseTax', () {
    test('intra-state splits CGST and SGST', () {
      final t = estimateExpenseTax(1000, 18, interState: false);
      expect(t.cgst, 90);
      expect(t.sgst, 90);
      expect(t.igst, 0);
      expect(t.total, 1180);
    });

    test('inter-state is IGST, rounded to paise', () {
      final t = estimateExpenseTax(333.33, 5, interState: true);
      expect(t.igst, 16.67);
      expect(t.cgst, 0);
      expect(t.total, 350);
    });

    test('zero rate', () {
      expect(estimateExpenseTax(250, 0, interState: false).total, 250);
    });
  });
}
