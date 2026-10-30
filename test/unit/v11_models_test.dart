import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/features/accounts/account_model.dart';
import 'package:progen_erp/features/auth/auth_models.dart';
import 'package:progen_erp/features/credit_notes/credit_note_model.dart';
import 'package:progen_erp/features/dashboard/dashboard_repository.dart';
import 'package:progen_erp/features/documents/document_models.dart';
import 'package:progen_erp/features/expenses/expense_model.dart';
import 'package:progen_erp/features/invoices/invoice_model.dart';
import 'package:progen_erp/features/parties/party_model.dart';
import 'package:progen_erp/features/payments/payment_model.dart';
import 'package:progen_erp/features/purchases/purchase_model.dart';
import 'package:progen_erp/features/stock/stock_models.dart';
import 'package:progen_erp/features/transfers/transfer_model.dart';

import '../support/fake_backend.dart';

void main() {
  Map<String, Object?> without(Map<String, Object?> json, List<String> keys) =>
      Map.of(json)..removeWhere((k, _) => keys.contains(k));

  group('Company / Membership', () {
    test('profile, bank and invoice fields', () {
      final c = Company.fromJson(FakeBackend.company);
      expect(c.pan, 'AAACD1234E');
      expect(c.phone, '080-4000 1234');
      expect(c.website, 'demobuilders.in');
      expect(c.bankIfsc, 'HDFC0001234');
      expect(c.upiId, 'demobuilders@hdfcbank');
      expect(c.invoiceTerms, startsWith('Payment within'));
      expect(c.invoiceFooter, 'Thank you for your business!');
      expect(c.hasBankDetails, isTrue);
    });

    test('absent v1.1 fields are null', () {
      final m = Membership.fromJson({
        'id': 'c1',
        'name': 'Old Co',
        'stateCode': '29',
        'roles': [],
        'permissions': ['items.view'],
        'locationIds': null,
      });
      expect(m.phone, isNull);
      expect(m.bankName, isNull);
      expect(m.invoiceTerms, isNull);
      expect(m.hasBankDetails, isFalse);
      expect(m.can('items.view'), isTrue);
    });

    test('memberships in /me carry the profile', () {
      final me = Me.fromJson(FakeBackend.me({'invoices.view'}));
      final first = me.companies.first;
      expect(first, isA<Company>());
      expect(first.bankAccountNo, '50200012345678');
      expect(first.roles.single.name, 'Owner');
    });
  });

  group('Invoice v1.1', () {
    test('payment fields, settlements and returned qty', () {
      final inv = Invoice.fromJson(FakeBackend.invoiceDetail);
      expect(inv.dueDate, '2026-11-20');
      expect(inv.amountPaid, 500);
      expect(inv.amountDue, 521);
      expect(inv.paymentStatus, PaymentStatus.partial);
      expect(inv.settlements, hasLength(2));
      expect(inv.settlements!.first.route, '/receipts/pay1');
      expect(inv.settlements!.last.kindLabel, 'Credit note');
      expect(inv.settlements!.last.route, '/credit-notes/cn1');
      expect(inv.lines!.single.returnedQty, 1);
      expect(inv.lines!.single.returnableQty, 1);
      expect(inv.hasReturnableQty, isTrue);
    });

    test('absent payment fields stay null (v1.0 server)', () {
      final inv = Invoice.fromJson(
        without(FakeBackend.invoiceRow, [
          'dueDate',
          'amountPaid',
          'amountDue',
          'paymentStatus',
        ]),
      );
      expect(inv.dueDate, isNull);
      expect(inv.amountPaid, isNull);
      expect(inv.amountDue, isNull);
      expect(inv.paymentStatus, isNull);
      expect(inv.settlements, isNull);
      expect(inv.lines, isNull);
      expect(inv.hasReturnableQty, isFalse);
    });

    test('fully returned lines are not returnable', () {
      const line = TaxLine(
        itemId: 'i1',
        description: 'x',
        qty: 2,
        unit: 'bag',
        rate: 1,
        returnedQty: 2,
      );
      expect(line.returnableQty, 0);
    });
  });

  test('Party creditDays and balance', () {
    final p = Party.fromJson(FakeBackend.vendor);
    expect(p.creditDays, 15);
    expect(p.balance, -8000);
    expect(p.isVendor, isTrue);
    expect(p.isCustomer, isFalse);
    expect(p.toInputJson()['creditDays'], 15);

    final old = Party.fromJson(
      without(FakeBackend.customer, ['creditDays', 'balance']),
    );
    expect(old.creditDays, 0);
    expect(old.balance, isNull);
  });

  group('Purchase', () {
    test('detail with lines and payment settlements', () {
      final p = Purchase.fromJson(FakeBackend.purchaseDetail);
      expect(p.number, 'PUR/26-27/00001');
      expect(p.supplierInvoiceNo, 'BSS/2026/118');
      expect(p.isInterState, isFalse);
      expect(p.cgst, 1064);
      expect(p.amountDue, 8000);
      expect(p.paymentStatus, PaymentStatus.partial);
      expect(p.lines!.single.lineTotal, 9728);
      expect(p.settlements!.single.route, '/payments/pay2');
    });

    test('list row without lines; preview without id', () {
      final row = Purchase.fromJson(FakeBackend.purchaseRow);
      expect(row.lines, isNull);
      expect(row.settlements, isNull);
      final preview = Purchase.fromJson(FakeBackend.purchasePreview);
      expect(preview.id, isNull);
      expect(preview.number, isNull);
    });

    test('draft omits optional fields', () {
      const draft = PurchaseDraft(
        locationId: 'l1',
        partyId: 'p2',
        lines: [DraftLine(itemId: 'i1', qty: 3)],
      );
      expect(draft.toJson(), {
        'locationId': 'l1',
        'partyId': 'p2',
        'lines': [
          {'itemId': 'i1', 'qty': 3.0},
        ],
        // v1.4: always sent (null = no TDS, never the party default).
        'tdsSectionId': null,
        'reverseCharge': false,
      });
    });
  });

  group('Payment', () {
    test('receipt with allocations', () {
      final p = Payment.fromJson(FakeBackend.receipt);
      expect(p.kind, PaymentKind.receipt);
      expect(p.mode, PaymentMode.upi);
      expect(p.unallocated, 500);
      expect(p.allocations.single.route, '/invoices/inv1');
      final vendor = Payment.fromJson(FakeBackend.vendorPayment);
      expect(vendor.kind, PaymentKind.payment);
      expect(vendor.kind.basePath, '/payments');
      expect(vendor.allocations.single.route, '/purchases/pur1');
      expect(vendor.reference, isNull);
    });

    test('draft: omitted allocations vs explicit empty list', () {
      const auto = PaymentDraft(
        kind: PaymentKind.receipt,
        partyId: 'p1',
        accountId: 'a-cash',
        mode: PaymentMode.cash,
        amount: 100,
      );
      expect(auto.toJson().containsKey('allocations'), isFalse);
      const advance = PaymentDraft(
        kind: PaymentKind.payment,
        partyId: 'p2',
        accountId: 'a-bank',
        mode: PaymentMode.cheque,
        amount: 100,
        allocations: {},
      );
      expect(advance.toJson()['allocations'], isEmpty);
      expect(advance.toJson()['kind'], 'payment');
      expect(advance.toJson()['mode'], 'cheque');
    });

    test('outstanding documents', () {
      final o = Outstanding.fromJson(FakeBackend.customerOutstanding);
      expect(o.balance, 12500);
      expect(o.docsFor(PaymentKind.receipt).map((d) => d.id), ['inv3', 'inv1']);
      expect(o.docsFor(PaymentKind.payment), isEmpty);
      expect(o.invoices.first.isOverdue(DateTime(2026, 10, 21)), isTrue);
      expect(o.invoices.last.isOverdue(DateTime(2026, 10, 21)), isFalse);
    });
  });

  test('CreditNote and its draft', () {
    final n = CreditNote.fromJson(FakeBackend.creditNote);
    expect(n.invoiceNumber, 'INV/26-27/00001');
    expect(n.restock, isTrue);
    expect(n.lines!.single.invoiceLineId, 'line1');
    expect(
      CreditNote.fromJson(without(FakeBackend.creditNote, ['restock'])).restock,
      isTrue,
    );
    const draft = CreditNoteDraft(
      invoiceId: 'inv1',
      reason: 'Damaged',
      lines: {'line1': 1, 'line2': 0},
      restock: false,
    );
    expect(draft.toJson(), {
      'invoiceId': 'inv1',
      'reason': 'Damaged',
      'restock': false,
      'lines': [
        {'invoiceLineId': 'line1', 'qty': 1.0},
      ],
    });
  });

  test('Transfer', () {
    final t = Transfer.fromJson(FakeBackend.transfer);
    expect(t.status, TransferStatus.inTransit);
    expect(t.isInTransit, isTrue);
    expect(t.totalValue, 1900);
    expect(t.receivedBy, isNull);
    expect(t.lines.single.qty, 5);
    final received = Transfer.fromJson(FakeBackend.receivedTransfer);
    expect(received.status, TransferStatus.received);
    expect(received.receivedBy!.name, 'Ravi Kumar');
    // No items.view_cost: totalValue absent.
    expect(
      Transfer.fromJson(
        without(FakeBackend.transfer, ['totalValue']),
      ).totalValue,
      isNull,
    );
    expect(TransferStatus.parse('cancelled'), TransferStatus.cancelled);
  });

  test('Expense and its draft', () {
    final e = Expense.fromJson(FakeBackend.expense);
    expect(e.taxTotal, 180);
    expect(e.partyName, isNull);
    const draft = ExpenseDraft(
      locationId: 'l1',
      accountId: 'a-rent',
      description: 'Rent',
      amount: 5000,
      paidFromAccountId: 'a-bank',
    );
    expect(draft.toJson().containsKey('partyId'), isFalse);
    expect(draft.toJson().containsKey('gstRate'), isFalse);
  });

  test('Account helpers and ledger', () {
    final cash = Account.fromJson(FakeBackend.cashAccount);
    expect(cash.isCashOrBank, isTrue);
    expect(Account.fromJson(FakeBackend.rentAccount).isExpenseHead, isTrue);
    expect(Account.fromJson(FakeBackend.cogsAccount).isExpenseHead, isFalse);
    final ledger = Ledger.fromJson(FakeBackend.statement);
    expect(ledger.openingBalance, 10000);
    expect(ledger.lines.first.route, '/invoices/inv1');
    expect(ledger.lines.last.voucherLabel, 'Receipt');
    expect(drCr(1500, (n) => '$n'), '1500.0 Dr');
    expect(drCr(-20, (n) => '$n'), '20.0 Cr');
  });

  test('Dashboard v1.1 figures are optional', () {
    final d = Dashboard.fromJson(FakeBackend.dashboard);
    expect(d.receivables, 264910);
    expect(d.cashAndBank, 150000.5);
    final old = Dashboard.fromJson(
      without(FakeBackend.dashboard, [
        'receivables',
        'payables',
        'cashAndBank',
        'purchasesThisMonth',
      ]),
    );
    expect(old.receivables, isNull);
    expect(old.purchasesThisMonth, isNull);
  });

  test('StockMove v1.1 fields and labels', () {
    final move = StockMove.fromJson(FakeBackend.transferInMove);
    expect(move.costRate, 380);
    expect(move.value, 1900);
    expect(move.refLabel, 'Transfer in');
    expect(move.refRoute, '/transfers/trf1');
    expect(
      StockMove.fromJson(FakeBackend.purchaseMove).refRoute,
      '/purchases/pur1',
    );
    expect(stockRefLabel('credit_note'), 'Sales return');
    expect(stockRefLabel('purchase_cancel'), 'Purchase cancelled');
    final noCost = StockMove.fromJson(
      without(FakeBackend.adjustmentMove, ['value', 'costRate']),
    );
    expect(noCost.value, isNull);
    expect(noCost.costRate, isNull);
    expect(noCost.refRoute, isNull);

    expect(
      const StockAdjustment(
        locationId: 'l1',
        itemId: 'i1',
        qty: 5,
        isOpening: true,
      ).toJson()['isOpening'],
      isTrue,
    );
    expect(
      const StockAdjustment(
        locationId: 'l1',
        itemId: 'i1',
        qty: 5,
      ).toJson().containsKey('isOpening'),
      isFalse,
    );
  });
}
