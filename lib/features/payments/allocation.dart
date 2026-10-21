/// Pure helpers for allocating a receipt or payment to open documents.
/// All maths is done in whole paise.
library;

import 'payment_model.dart';

int _paise(num amount) => (amount * 100).round();
double _rupees(int paise) => paise / 100;

/// Fills [docs] oldest first (by date, then the given order) up to
/// [amount]; [firstId] is filled before the rest. Returns docId → amount for
/// every document that gets money.
Map<String, double> autoAllocate(
  List<OpenDoc> docs,
  double amount, {
  String? firstId,
}) {
  final ordered = [...docs.indexed]
    ..sort((a, b) {
      if (firstId != null && (a.$2.id == firstId) != (b.$2.id == firstId)) {
        return a.$2.id == firstId ? -1 : 1;
      }
      final byDate = (a.$2.date ?? '').compareTo(b.$2.date ?? '');
      return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
    });
  var left = _paise(amount);
  final result = <String, double>{};
  for (final (_, doc) in ordered) {
    if (left <= 0) break;
    final due = _paise(doc.amountDue);
    if (due <= 0) continue;
    final take = due < left ? due : left;
    result[doc.id] = _rupees(take);
    left -= take;
  }
  return result;
}

/// Σ of the allocations, rounded to paise.
double allocatedTotal(Map<String, double> allocations) =>
    _rupees(allocations.values.fold(0, (sum, v) => sum + _paise(v)));

/// What stays as an advance; never negative.
double unallocatedAmount(double amount, Map<String, double> allocations) {
  final left = _paise(amount) - _paise(allocatedTotal(allocations));
  return left > 0 ? _rupees(left) : 0;
}

/// Error for one document's allocation, or `null` if valid.
String? allocationError(OpenDoc doc, double? value) {
  if (value == null) return null;
  if (value < 0) return 'Cannot be negative';
  if (_paise(value) > _paise(doc.amountDue)) return 'More than due';
  return null;
}

/// First problem with the whole set of allocations, or `null` if valid:
/// each ≤ its document's due, and Σ ≤ [amount].
String? allocationsError(
  List<OpenDoc> docs,
  Map<String, double> allocations,
  double amount,
) {
  final byId = {for (final doc in docs) doc.id: doc};
  for (final MapEntry(:key, :value) in allocations.entries) {
    final doc = byId[key];
    if (doc == null) return 'Unknown document';
    final error = allocationError(doc, value);
    if (error != null) return '${doc.number}: $error';
  }
  if (_paise(allocatedTotal(allocations)) > _paise(amount)) {
    return 'Allocations add up to more than the amount';
  }
  return null;
}
