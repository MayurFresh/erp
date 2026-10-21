// End-to-end test against a running backend, using the app's real
// ApiClient and repositories. Skipped unless PROGEN_API is set:
//
//   PROGEN_API=http://localhost:8080/api/v1 flutter test test/live_api_test.dart
//
// Uses plain `test` (not `testWidgets`) so real HTTP is allowed.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/api_client.dart';
import 'package:progen_erp/core/api_exception.dart';
import 'package:progen_erp/core/token_store.dart';
import 'package:progen_erp/features/accounts/accounts_repository.dart';
import 'package:progen_erp/features/auth/auth_models.dart';
import 'package:progen_erp/features/auth/auth_repository.dart';
import 'package:progen_erp/features/company/company_repository.dart';
import 'package:progen_erp/features/credit_notes/credit_note_model.dart';
import 'package:progen_erp/features/credit_notes/credit_notes_repository.dart';
import 'package:progen_erp/features/dashboard/dashboard_repository.dart';
import 'package:progen_erp/features/documents/document_models.dart';
import 'package:progen_erp/features/expenses/expense_model.dart';
import 'package:progen_erp/features/expenses/expenses_repository.dart';
import 'package:progen_erp/features/invoices/invoice_model.dart';
import 'package:progen_erp/features/invoices/invoices_repository.dart';
import 'package:progen_erp/features/items/item_model.dart';
import 'package:progen_erp/features/items/items_repository.dart';
import 'package:progen_erp/features/locations/locations_repository.dart';
import 'package:progen_erp/features/parties/parties_repository.dart';
import 'package:progen_erp/features/payments/payment_model.dart';
import 'package:progen_erp/features/payments/payments_repository.dart';
import 'package:progen_erp/features/purchases/purchase_model.dart';
import 'package:progen_erp/features/purchases/purchases_repository.dart';
import 'package:progen_erp/features/stock/stock_models.dart';
import 'package:progen_erp/features/stock/stock_repository.dart';
import 'package:progen_erp/features/transfers/transfer_model.dart';
import 'package:progen_erp/features/transfers/transfers_repository.dart';

void main() {
  final baseUrl = Platform.environment['PROGEN_API'];

  group(
    'live API',
    skip: baseUrl == null || baseUrl.isEmpty
        ? 'Set PROGEN_API (e.g. http://localhost:8080/api/v1) to run'
        : false,
    () {
      late ApiClient api;
      late AuthRepository auth;
      late LocationsRepository locations;
      late ItemsRepository items;
      late PartiesRepository parties;
      late StockRepository stock;
      late InvoicesRepository invoices;
      late PurchasesRepository purchases;
      late PaymentsRepository payments;
      late CreditNotesRepository creditNotes;
      late TransfersRepository transfers;
      late ExpensesRepository expenses;
      late AccountsRepository accounts;
      late DashboardRepository dashboard;
      late CompanyRepository companyRepo;

      setUpAll(() {
        api = ApiClient(baseUrl: baseUrl!, tokenStore: InMemoryTokenStore());
        auth = AuthRepository(api);
        locations = LocationsRepository(api);
        items = ItemsRepository(api);
        parties = PartiesRepository(api);
        stock = StockRepository(api);
        invoices = InvoicesRepository(api);
        purchases = PurchasesRepository(api);
        payments = PaymentsRepository(api);
        creditNotes = CreditNotesRepository(api);
        transfers = TransfersRepository(api);
        expenses = ExpensesRepository(api);
        accounts = AccountsRepository(api);
        dashboard = DashboardRepository(api);
        companyRepo = CompanyRepository(api);
      });

      tearDownAll(() => api.close());

      Future<double> qtyAt(
        String itemId,
        String itemName,
        String locationId,
      ) async {
        final page = await stock.balances(
          locationId: locationId,
          q: itemName,
          limit: 200,
        );
        final row = page.data.where((b) => b.itemId == itemId).toList();
        expect(row, hasLength(1), reason: 'one balance row for the item');
        return row.single.qty;
      }

      test('signup → stock → invoice → cancel', () async {
        final stamp = DateTime.now().microsecondsSinceEpoch;
        final email = 'live$stamp@example.com';

        // Sign up (Karnataka) and load /me.
        final signup = await auth.signup(
          SignupRequest(
            businessName: 'Live Test $stamp',
            name: 'Live Tester',
            email: email,
            password: 'LiveTest@123',
            phone: '9876543210',
            stateCode: '29',
          ),
        );
        expect(signup.user.email, email);
        expect(signup.tokens.accessToken, isNotEmpty);

        final me = await auth.me();
        expect(me.user.email, email);
        expect(me.companies, isNotEmpty);
        final company = me.companies.first;
        await api.setCompany(company.id);
        expect(company.locationIds, isNull, reason: 'owner sees everything');
        expect(company.permissions.can('invoices.create'), isTrue);

        // Refresh rotates the tokens and the session keeps working.
        final refreshed = await auth.refresh();
        expect(
          refreshed.tokens.refreshToken,
          isNot(signup.tokens.refreshToken),
        );

        // A site location in the same state.
        final site = await locations.create({
          'type': 'site',
          'name': 'Live Site $stamp',
          'code': 'LS$stamp'.substring(0, 8),
          'stateCode': '29',
        });
        expect(site.type, 'site');
        expect(site.stateCode, '29');
        final scoped = await locations.list(limit: 200);
        expect(scoped.data.map((l) => l.id), contains(site.id));

        // A stocked item at 18 % GST.
        final itemName = 'Live Item $stamp';
        final item = await items.create(
          ItemInput(
            name: itemName,
            unit: 'pcs',
            gstRate: 18,
            salePrice: 100,
            purchasePrice: 60,
            trackStock: true,
            reorderLevel: 2,
          ),
          includeCost: true,
        );
        expect(item.trackStock, isTrue);
        expect(item.gstRate, 18);
        expect(item.salePrice, 100);
        expect(item.purchasePrice, 60, reason: 'owner has items.view_cost');

        // +10 at the site.
        final move = await stock.adjust(
          StockAdjustment(
            locationId: site.id,
            itemId: item.id,
            qty: 10,
            rate: 60,
            note: 'live test opening',
          ),
        );
        expect(move.qty, 10);
        expect(await qtyAt(item.id, itemName, site.id), 10);

        // Removing more than available is refused.
        await expectLater(
          stock.adjust(
            StockAdjustment(locationId: site.id, itemId: item.id, qty: -50),
          ),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              ApiException.insufficientStock,
            ),
          ),
        );

        // A customer in Maharashtra → inter-state supply.
        final customer = await parties.create({
          'type': 'customer',
          'name': 'Live Customer $stamp',
          'stateCode': '27',
        });
        expect(customer.stateCode, '27');

        final draft = InvoiceDraft(
          locationId: site.id,
          partyId: customer.id,
          lines: [InvoiceDraftLine(itemId: item.id, qty: 2)],
        );

        final preview = await invoices.preview(draft);
        expect(preview.id, isNull);
        expect(preview.number, isNull);
        expect(preview.supplyType, 'inter');
        expect(preview.placeOfSupply, '27');
        expect(preview.subtotal, 200);
        expect(preview.igst, 36);
        expect(preview.cgst, 0);
        expect(preview.sgst, 0);
        expect(preview.total, 236);
        expect(preview.lines, hasLength(1));
        expect(
          preview.lines!.single.rate,
          100,
          reason: 'defaults to salePrice',
        );
        // Preview saves nothing.
        expect(await qtyAt(item.id, itemName, site.id), 10);

        final invoice = await invoices.create(draft);
        expect(invoice.id, isNotNull);
        expect(invoice.number, startsWith('INV/'));
        expect(invoice.status, InvoiceStatus.posted);
        expect(invoice.total, 236);
        expect(invoice.lines, hasLength(1));

        final listed = await invoices.list(q: invoice.number, limit: 50);
        expect(listed.data.map((i) => i.id), contains(invoice.id));
        final all = await invoices.list(limit: 50);
        expect(all.data.map((i) => i.id), contains(invoice.id));

        final detail = await invoices.get(invoice.id!);
        expect(detail.number, invoice.number);
        expect(detail.lines, hasLength(1));

        expect(await qtyAt(item.id, itemName, site.id), 8);

        final cancelled = await invoices.cancel(invoice.id!, 'live test');
        expect(cancelled.status, InvoiceStatus.cancelled);
        expect(cancelled.number, invoice.number, reason: 'keeps its number');
        expect(cancelled.cancelReason, 'live test');

        expect(await qtyAt(item.id, itemName, site.id), 10);

        await expectLater(
          invoices.cancel(invoice.id!, 'again'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'ALREADY_CANCELLED',
            ),
          ),
        );

        final moves = await stock.moves(itemId: item.id, locationId: site.id);
        expect(
          moves.data.map((m) => m.refType),
          containsAll(['adjustment', 'invoice', 'invoice_cancel']),
        );

        await auth.logout();
        expect(api.refreshToken, isNull);
      });

      test('purchase → payment → invoice → receipt → credit note → '
          'transfer → expense → dashboard', () async {
        final stamp = DateTime.now().microsecondsSinceEpoch;
        await auth.signup(
          SignupRequest(
            businessName: 'Live Books $stamp',
            name: 'Live Accountant',
            email: 'books$stamp@example.com',
            password: 'LiveTest@123',
            stateCode: '29',
          ),
        );
        final company = (await auth.me()).companies.first;
        await api.setCompany(company.id);
        final profile = await companyRepo.get();
        expect(profile.id, company.id);
        expect(profile.stateCode, '29');

        // Head Office comes with signup; add a warehouse in the same state.
        final head = (await locations.list(limit: 200)).data.first;
        final warehouse = await locations.create({
          'type': 'warehouse',
          'name': 'Live Warehouse $stamp',
          'stateCode': '29',
        });

        final itemName = 'Live Stock Item $stamp';
        final item = await items.create(
          ItemInput(
            name: itemName,
            unit: 'pcs',
            gstRate: 18,
            salePrice: 100,
            purchasePrice: 60,
          ),
          includeCost: true,
        );

        // Vendor in Karnataka: intra-state purchase.
        final vendor = await parties.create({
          'type': 'vendor',
          'name': 'Live Vendor $stamp',
          'stateCode': '29',
          'creditDays': 15,
        });
        expect(vendor.creditDays, 15);

        // Purchase bill: 10 pcs at the item's purchase price (stock in).
        final billDraft = PurchaseDraft(
          locationId: head.id,
          partyId: vendor.id,
          supplierInvoiceNo: 'SUP-$stamp'.substring(0, 12),
          lines: [DraftLine(itemId: item.id, qty: 10)],
        );
        final billPreview = await purchases.preview(billDraft);
        expect(billPreview.id, isNull);
        expect(billPreview.supplyType, 'intra');
        expect(billPreview.lines!.single.rate, 60);
        expect(billPreview.cgst, 54);
        expect(billPreview.sgst, 54);
        expect(billPreview.total, 708);
        final bill = await purchases.create(billDraft);
        expect(bill.number, startsWith('PUR/'));
        expect(bill.paymentStatus, PaymentStatus.unpaid);
        expect(bill.amountDue, 708);
        expect(await qtyAt(item.id, itemName, head.id), 10);

        final cashBank = (await accounts.list(
          type: 'asset',
          activeOnly: true,
          limit: 200,
        )).data.where((a) => a.isCashOrBank).toList();
        final cash = cashBank.firstWhere((a) => a.subtype == 'cash');
        final bank = cashBank.firstWhere((a) => a.subtype == 'bank');

        // Pay the bill in full from cash.
        final vendorOpen = await payments.outstanding(vendor.id);
        expect(vendorOpen.purchases.map((d) => d.id), contains(bill.id));
        final payment = await payments.create(
          PaymentDraft(
            kind: PaymentKind.payment,
            partyId: vendor.id,
            accountId: cash.id,
            mode: PaymentMode.cash,
            amount: 708,
            allocations: {bill.id!: 708},
          ),
        );
        expect(payment.number, startsWith('PAY/'));
        expect(payment.allocated, 708);
        expect(payment.unallocated, 0);
        final paidBill = await purchases.get(bill.id!);
        expect(paidBill.paymentStatus, PaymentStatus.paid);
        expect(paidBill.amountDue, 0);
        expect(paidBill.settlements!.map((s) => s.id), contains(payment.id));

        // Customer in Maharashtra: inter-state invoice, 30 days credit.
        final customer = await parties.create({
          'type': 'customer',
          'name': 'Live Buyer $stamp',
          'stateCode': '27',
          'creditDays': 30,
        });
        final invoice = await invoices.create(
          InvoiceDraft(
            locationId: head.id,
            partyId: customer.id,
            lines: [DraftLine(itemId: item.id, qty: 4)],
          ),
        );
        expect(invoice.total, 472);
        expect(invoice.paymentStatus, PaymentStatus.unpaid);
        final invoiceDate = DateTime.parse(invoice.invoiceDate!);
        expect(
          DateTime.parse(invoice.dueDate!),
          invoiceDate.add(const Duration(days: 30)),
        );

        // Part payment by UPI into the bank.
        final receipt = await payments.create(
          PaymentDraft(
            kind: PaymentKind.receipt,
            partyId: customer.id,
            accountId: bank.id,
            mode: PaymentMode.upi,
            reference: 'UTR$stamp',
            amount: 200,
            allocations: {invoice.id!: 200},
          ),
        );
        expect(receipt.number, startsWith('RCT/'));
        final partly = await invoices.get(invoice.id!);
        expect(partly.paymentStatus, PaymentStatus.partial);
        expect(partly.amountPaid, 200);
        expect(partly.amountDue, 272);

        // Return one piece to stock.
        final line = partly.lines!.single;
        final cnDraft = CreditNoteDraft(
          invoiceId: invoice.id!,
          reason: 'live test return',
          lines: {line.id!: 1},
        );
        final cnPreview = await creditNotes.preview(cnDraft);
        expect(cnPreview.id, isNull);
        expect(cnPreview.total, 118);
        final note = await creditNotes.create(cnDraft);
        expect(note.number, startsWith('CN/'));
        expect(note.restock, isTrue);
        expect(await qtyAt(item.id, itemName, head.id), 7);
        final afterReturn = await invoices.get(invoice.id!);
        expect(afterReturn.lines!.single.returnedQty, 1);
        expect(afterReturn.amountDue, 154);
        expect(
          afterReturn.settlements!.map((s) => s.kind),
          containsAll(['receipt', 'credit_note']),
        );
        await expectLater(
          invoices.cancel(invoice.id!, 'not allowed'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              ApiException.hasSettlements,
            ),
          ),
        );

        // Move 3 pieces to the warehouse and receive them.
        final transfer = await transfers.create(
          TransferDraft(
            fromLocationId: head.id,
            toLocationId: warehouse.id,
            lines: {item.id: 3},
          ),
        );
        expect(transfer.number, startsWith('TRF/'));
        expect(transfer.status, TransferStatus.inTransit);
        expect(await qtyAt(item.id, itemName, head.id), 4);
        final received = await transfers.receive(transfer.id);
        expect(received.status, TransferStatus.received);
        expect(await qtyAt(item.id, itemName, warehouse.id), 3);

        // An expense paid from cash (no vendor: CGST + SGST).
        final heads = (await accounts.list(
          type: 'expense',
          activeOnly: true,
          limit: 200,
        )).data.where((a) => a.isExpenseHead).toList();
        expect(heads, isNotEmpty);
        final expense = await expenses.create(
          ExpenseDraft(
            locationId: head.id,
            accountId: heads.first.id,
            description: 'live test diesel',
            amount: 1000,
            gstRate: 18,
            paidFromAccountId: cash.id,
          ),
        );
        expect(expense.number, startsWith('EXP/'));
        expect(expense.cgst, 90);
        expect(expense.sgst, 90);
        expect(expense.total, 1180);

        final board = await dashboard.get();
        expect(board.receivables, isNotNull);
        expect(board.receivables, closeTo(154, 0.001));

        final statement = await parties.statement(customer.id);
        expect(statement.closingBalance, closeTo(154, 0.001));
        final refTypes = (await stock.moves(
          itemId: item.id,
          limit: 200,
        )).data.map((m) => m.refType);
        expect(
          refTypes,
          containsAll([
            'purchase',
            'invoice',
            'credit_note',
            'transfer_out',
            'transfer_in',
          ]),
        );

        await auth.logout();
      });
    },
  );
}
