import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// An in-process stand-in for the API used by widget tests (no network).
class FakeBackend implements HttpClientAdapter {
  FakeBackend({Set<String>? permissions, this.v11 = true})
    : permissions = permissions ?? allPermissions;

  static const allPermissions = {
    'dashboard.view',
    'items.view',
    'items.create',
    'items.edit',
    'items.view_cost',
    'parties.view',
    'parties.create',
    'parties.edit',
    'locations.view',
    'locations.manage',
    'stock.view',
    'stock.adjust',
    'invoices.view',
    'invoices.create',
    'invoices.cancel',
    'users.manage',
    'roles.manage',
    'audit.view',
    'company.manage',
    'purchases.view',
    'purchases.create',
    'purchases.cancel',
    'payments.view',
    'payments.create',
    'payments.cancel',
    'credit_notes.view',
    'credit_notes.create',
    'credit_notes.cancel',
    'transfers.view',
    'transfers.create',
    'transfers.receive',
    'expenses.view',
    'expenses.create',
    'expenses.cancel',
    'accounts.view',
    'accounts.manage',
    'accounts.journal',
    'reports.view',
  };

  final Set<String> permissions;

  /// `false` serves v1.0 shapes (no v1.1 fields) for robustness tests.
  final bool v11;
  final List<RequestOptions> requests = [];

  /// `'METHOD /path'` → (status, body), checked before the defaults.
  final Map<String, (int, Object?)> overrides = {};

  int count(String method, String path) =>
      requests.where((r) => r.method == method && r.path == path).length;

  RequestOptions last(String method, String path) =>
      requests.lastWhere((r) => r.method == method && r.path == path);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final override = overrides['${options.method} ${options.path}'];
    final (status, body) =
        override ?? _route(options.method, options.path, options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  static (int, Object?) error(int status, String code, String message) => (
    status,
    {
      'error': {'code': code, 'message': message, 'details': {}},
    },
  );

  (int, Object?) _route(String method, String path, RequestOptions o) {
    Map<String, Object?> page(List<Object?> data) => {
      'data': data,
      'total': data.length,
    };
    final q = o.queryParameters;
    Map<String, Object?> v10(Map<String, Object?> json, List<String> keys) =>
        v11 ? json : (Map.of(json)..removeWhere((k, _) => keys.contains(k)));
    const invoiceV11 = [
      'dueDate',
      'amountPaid',
      'amountDue',
      'paymentStatus',
      'settlements',
    ];
    return switch ((method, path)) {
      ('POST', '/auth/refresh' || '/auth/login') => (200, authResult),
      ('POST', '/auth/logout') => (204, null),
      ('GET', '/me') => (200, me(permissions)),
      ('GET', '/company') => (200, company),
      ('GET', '/dashboard') => (
        200,
        v10(dashboard, [
          'receivables',
          'payables',
          'cashAndBank',
          'purchasesThisMonth',
        ]),
      ),
      ('GET', '/items') => (200, page([item, untrackedItem])),
      ('GET', '/items/i1') => (200, item),
      ('GET', '/parties') => (
        200,
        page([
          if (q['type'] != 'vendor') customer,
          if (q['type'] != 'customer') vendor,
        ]),
      ),
      ('GET', '/parties/p1') => (200, v10(customer, ['creditDays', 'balance'])),
      ('GET', '/parties/p2') => (200, vendor),
      ('GET', '/parties/p1/outstanding') => (200, customerOutstanding),
      ('GET', '/parties/p2/outstanding') => (200, vendorOutstanding),
      ('GET', '/parties/p1/statement' || '/parties/p2/statement') => (
        200,
        statement,
      ),
      ('GET', '/locations') => (200, page([headOffice, site])),
      ('GET', '/stock') => (200, page([balance, lowBalance])),
      ('GET', '/stock/moves') => (
        200,
        page([adjustmentMove, invoiceMove, purchaseMove, transferInMove]),
      ),
      ('GET', '/invoices') => (
        200,
        page([v10(invoiceRow, invoiceV11), v10(cancelledRow, invoiceV11)]),
      ),
      ('GET', '/invoices/inv1') => (200, v10(invoiceDetail, invoiceV11)),
      ('POST', '/invoices/preview') => (200, preview),
      ('POST', '/invoices/inv1/cancel') => (
        200,
        {...invoiceDetail, 'status': 'cancelled'},
      ),
      ('GET', '/purchases') => (200, page([purchaseRow, cancelledPurchase])),
      ('GET', '/purchases/pur1') => (200, purchaseDetail),
      ('POST', '/purchases/preview') => (200, purchasePreview),
      ('GET', '/payments') => (
        200,
        page([if (q['kind'] == 'payment') vendorPayment else receipt]),
      ),
      ('GET', '/payments/pay1') => (200, receipt),
      ('GET', '/payments/pay2') => (200, vendorPayment),
      ('POST', '/payments') => (201, receipt),
      ('GET', '/credit-notes') => (200, page([creditNote])),
      ('GET', '/credit-notes/cn1') => (200, creditNote),
      ('POST', '/credit-notes/preview') => (200, creditNotePreview),
      ('POST', '/credit-notes') => (201, creditNote),
      ('POST', '/purchases') => (201, purchaseDetail),
      ('POST', '/transfers') => (201, transfer),
      ('POST', '/transfers/trf1/receive') => (
        200,
        {...transfer, 'status': 'received'},
      ),
      ('POST', '/expenses') => (201, expense),
      ('GET', '/transfers') => (200, page([transfer, receivedTransfer])),
      ('GET', '/transfers/trf1') => (200, transfer),
      ('GET', '/expenses') => (200, page([expense])),
      ('GET', '/expenses/exp1') => (200, expense),
      ('GET', '/accounts') => (
        200,
        page(switch (q['type']) {
          'asset' => [cashAccount, bankAccount, receivablesAccount],
          'expense' => [rentAccount, cogsAccount],
          _ => [cashAccount, bankAccount, rentAccount],
        }),
      ),
      ('GET', '/users') => (200, page([userRow])),
      ('GET', '/roles') => (200, page([ownerRole])),
      ('GET', '/audit') => (200, page([auditEntry])),
      _ => error(404, 'NOT_FOUND', 'No fake for $method $path'),
    };
  }

  @override
  void close({bool force = false}) {}

  static final authResult = {
    'accessToken': 'access',
    'refreshToken': 'refresh-2',
    'expiresIn': 900,
    'user': user,
  };

  static final user = {
    'id': 'u1',
    'name': 'Asha Rao',
    'email': 'owner@demo.in',
    'phone': null,
  };

  static final company = {
    'id': 'c1',
    'name': 'Demo Builders',
    'legalName': 'Demo Builders Private Limited',
    'gstin': '29AAACD1234E1Z5',
    'stateCode': '29',
    'pan': 'AAACD1234E',
    'address': '12 MG Road, Bengaluru 560001',
    'phone': '080-4000 1234',
    'email': 'billing@demobuilders.in',
    'website': 'demobuilders.in',
    'bankName': 'HDFC Bank',
    'bankAccountNo': '50200012345678',
    'bankIfsc': 'HDFC0001234',
    'upiId': 'demobuilders@hdfcbank',
    'invoiceTerms':
        'Payment within 30 days. Goods once sold are not taken back.',
    'invoiceFooter': 'Thank you for your business!',
  };

  static Map<String, Object?> me(Set<String> permissions) => {
    'user': user,
    'companies': [
      {
        ...company,
        'roles': [
          {'id': 'r1', 'name': 'Owner'},
        ],
        'permissions': permissions.toList(),
        'locationIds': null,
      },
      {
        'id': 'c2',
        'name': 'Second Company With A Long Name',
        'legalName': null,
        'gstin': null,
        'stateCode': '27',
        'pan': null,
        'address': null,
        'roles': [
          {'id': 'r1', 'name': 'Owner'},
        ],
        'permissions': permissions.toList(),
        'locationIds': ['l2'],
      },
    ],
  };

  static final item = {
    'id': 'i1',
    'companyId': 'c1',
    'name': 'Portland Cement 53 Grade 50kg',
    'sku': 'CEM-53-50',
    'hsnCode': '2523',
    'unit': 'bag',
    'gstRate': 28,
    'salePrice': 420,
    'purchasePrice': 380,
    'avgCost': 377.5,
    'trackStock': true,
    'reorderLevel': 20,
    'isActive': true,
    'createdAt': '2026-10-01T09:30:00.000Z',
    'updatedAt': '2026-10-01T09:30:00.000Z',
  };

  static final untrackedItem = {
    ...item,
    'id': 'i2',
    'name': 'Site supervision (per day)',
    'sku': null,
    'hsnCode': '998311',
    'unit': 'nos',
    'gstRate': 18,
    'salePrice': 2500,
    'trackStock': false,
    'isActive': false,
  };

  static final customer = {
    'id': 'p1',
    'companyId': 'c1',
    'type': 'customer',
    'name': 'Mumbai Infra Projects LLP',
    'gstin': '27AAPFU0939F1ZV',
    'stateCode': '27',
    'phone': '9820012345',
    'email': 'accounts@mumbai-infra.in',
    'address': 'Andheri East, Mumbai',
    'creditLimit': 500000,
    'creditDays': 30,
    'balance': 12500,
    'createdAt': '2026-10-01T09:30:00.000Z',
  };

  static final vendor = {
    ...customer,
    'id': 'p2',
    'type': 'vendor',
    'name': 'Bengaluru Steel Suppliers',
    'gstin': null,
    'stateCode': '29',
    'creditDays': 15,
    'balance': -8000,
  };

  static final headOffice = {
    'id': 'l1',
    'companyId': 'c1',
    'parentId': null,
    'type': 'branch',
    'name': 'Head Office',
    'code': 'HO',
    'stateCode': '29',
    'address': 'MG Road, Bengaluru',
    'isActive': true,
    'createdAt': '2026-10-01T09:30:00.000Z',
  };

  static final site = {
    ...headOffice,
    'id': 'l2',
    'type': 'site',
    'name': 'Site A — Tower 1',
    'code': 'SA-T1',
    'address': null,
  };

  static final balance = {
    'itemId': 'i1',
    'itemName': 'Portland Cement 53 Grade 50kg',
    'sku': 'CEM-53-50',
    'unit': 'bag',
    'locationId': 'l1',
    'locationName': 'Head Office',
    'qty': 1240.5,
    'reorderLevel': 20,
    'value': 471390,
  };

  static final lowBalance = {
    ...balance,
    'locationId': 'l2',
    'locationName': 'Site A — Tower 1',
    'qty': 4,
    'value': 1520,
  };

  static final adjustmentMove = {
    'id': 'm1',
    'itemId': 'i1',
    'locationId': 'l1',
    'qty': 10,
    'rate': 380,
    'costRate': 380,
    'value': 3800,
    'refType': 'opening',
    'refId': null,
    'note': 'Opening count',
    'createdAt': '2026-10-02T09:30:00.000Z',
  };

  static final invoiceMove = {
    ...adjustmentMove,
    'id': 'm2',
    'qty': -2,
    'rate': null,
    'value': -760,
    'refType': 'invoice',
    'refId': 'inv1',
    'note': null,
  };

  static final purchaseMove = {
    ...adjustmentMove,
    'id': 'm3',
    'qty': 20,
    'value': 7600,
    'refType': 'purchase',
    'refId': 'pur1',
    'note': null,
  };

  static final transferInMove = {
    ...adjustmentMove,
    'id': 'm4',
    'locationId': 'l2',
    'qty': 5,
    'value': 1900,
    'refType': 'transfer_in',
    'refId': 'trf1',
    'note': null,
  };

  static final line = {
    'id': 'line1',
    'itemId': 'i1',
    'description': 'Portland Cement 53 Grade 50kg',
    'hsnCode': '2523',
    'qty': 2,
    'unit': 'bag',
    'rate': 420,
    'discountPct': 5,
    'taxableValue': 798,
    'gstRate': 28,
    'cgst': 0,
    'sgst': 0,
    'igst': 223.44,
    'lineTotal': 1021.44,
  };

  static final invoiceRow = {
    'id': 'inv1',
    'companyId': 'c1',
    'locationId': 'l1',
    'locationName': 'Head Office',
    'partyId': 'p1',
    'partyName': 'Mumbai Infra Projects LLP',
    'partyGstin': '27AAPFU0939F1ZV',
    'number': 'INV/26-27/00001',
    'fy': '2026-27',
    'invoiceDate': '2026-10-21',
    'dueDate': '2026-11-20',
    'placeOfSupply': '27',
    'supplyType': 'inter',
    'status': 'posted',
    'subtotal': 798,
    'cgst': 0,
    'sgst': 0,
    'igst': 223.44,
    'taxTotal': 223.44,
    'roundOff': -0.44,
    'total': 1021,
    'amountPaid': 500,
    'amountDue': 521,
    'paymentStatus': 'partial',
    'notes': 'Deliver to gate 2',
    'createdAt': '2026-10-21T09:30:00.000Z',
    'createdBy': {'id': 'u1', 'name': 'Asha Rao'},
    'cancelledAt': null,
    'cancelReason': null,
  };

  static final cancelledRow = {
    ...invoiceRow,
    'id': 'inv2',
    'number': 'INV/26-27/00002',
    'status': 'cancelled',
    'amountPaid': 0,
    'amountDue': 0,
    'paymentStatus': 'unpaid',
    'cancelledAt': '2026-10-21T10:30:00.000Z',
    'cancelReason': 'Wrong party',
  };

  static final invoiceDetail = {
    ...invoiceRow,
    'lines': [
      {...line, 'returnedQty': 1},
    ],
    'settlements': [
      {
        'kind': 'receipt',
        'id': 'pay1',
        'number': 'RCT/26-27/00001',
        'date': '2026-10-22',
        'amount': 300,
      },
      {
        'kind': 'credit_note',
        'id': 'cn1',
        'number': 'CN/26-27/00001',
        'date': '2026-10-23',
        'amount': 200,
      },
    ],
  };

  static final preview = {
    ...invoiceRow,
    'lines': [line],
    'id': null,
    'number': null,
    'createdBy': null,
    'createdAt': null,
  };

  static final customerOutstanding = {
    'balance': 12500,
    'invoices': [
      {
        'id': 'inv3',
        'number': 'INV/26-27/00003',
        'date': '2026-09-15',
        'dueDate': '2026-10-15',
        'total': 2000,
        'amountDue': 2000,
      },
      {
        'id': 'inv1',
        'number': 'INV/26-27/00001',
        'date': '2026-10-21',
        'dueDate': '2026-11-20',
        'total': 1021,
        'amountDue': 521,
      },
    ],
    'purchases': [],
  };

  static final vendorOutstanding = {
    'balance': -8000,
    'invoices': [],
    'purchases': [
      {
        'id': 'pur1',
        'number': 'PUR/26-27/00001',
        'date': '2026-10-10',
        'dueDate': '2026-10-25',
        'total': 9728,
        'amountDue': 8000,
      },
    ],
  };

  static final statement = {
    'accountId': 'a-ar',
    'accountName': 'Accounts Receivable',
    'from': '2026-04-01',
    'to': '2026-10-21',
    'openingBalance': 10000,
    'closingBalance': 12500,
    'totalDebit': 3021,
    'totalCredit': 521,
    'lines': [
      {
        'entryId': 'j1',
        'date': '2026-10-21',
        'voucherType': 'sales',
        'voucherId': 'inv1',
        'number': 'INV/26-27/00001',
        'narration': 'Sales invoice',
        'partyName': 'Mumbai Infra Projects LLP',
        'debit': 1021,
        'credit': 0,
        'balance': 11021,
      },
      {
        'entryId': 'j2',
        'date': '2026-10-22',
        'voucherType': 'receipt',
        'voucherId': 'pay1',
        'number': 'RCT/26-27/00001',
        'narration': 'Receipt by UPI with a rather long narration text',
        'partyName': 'Mumbai Infra Projects LLP',
        'debit': 0,
        'credit': 300,
        'balance': 10721,
      },
    ],
  };

  static final purchaseLine = {
    ...line,
    'id': 'pl1',
    'qty': 20,
    'rate': 380,
    'discountPct': 0,
    'taxableValue': 7600,
    'cgst': 1064,
    'sgst': 1064,
    'igst': 0,
    'lineTotal': 9728,
  };

  static final purchaseRow = {
    'id': 'pur1',
    'companyId': 'c1',
    'locationId': 'l1',
    'locationName': 'Head Office',
    'partyId': 'p2',
    'partyName': 'Bengaluru Steel Suppliers',
    'partyGstin': null,
    'number': 'PUR/26-27/00001',
    'supplierInvoiceNo': 'BSS/2026/118',
    'supplierInvoiceDate': '2026-10-09',
    'fy': '2026-27',
    'billDate': '2026-10-10',
    'dueDate': '2026-10-25',
    'placeOfSupply': '29',
    'supplyType': 'intra',
    'status': 'posted',
    'subtotal': 7600,
    'cgst': 1064,
    'sgst': 1064,
    'igst': 0,
    'taxTotal': 2128,
    'roundOff': 0,
    'total': 9728,
    'amountPaid': 1728,
    'amountDue': 8000,
    'paymentStatus': 'partial',
    'notes': null,
    'createdAt': '2026-10-10T09:30:00.000Z',
    'createdBy': {'id': 'u1', 'name': 'Asha Rao'},
    'cancelledAt': null,
    'cancelReason': null,
  };

  static final cancelledPurchase = {
    ...purchaseRow,
    'id': 'pur2',
    'number': 'PUR/26-27/00002',
    'supplierInvoiceNo': null,
    'status': 'cancelled',
    'amountPaid': 0,
    'amountDue': 0,
    'paymentStatus': 'unpaid',
    'cancelledAt': '2026-10-11T09:30:00.000Z',
    'cancelReason': 'Duplicate entry',
  };

  static final purchaseDetail = {
    ...purchaseRow,
    'lines': [purchaseLine],
    'settlements': [
      {
        'kind': 'payment',
        'id': 'pay2',
        'number': 'PAY/26-27/00001',
        'date': '2026-10-12',
        'amount': 1728,
      },
    ],
  };

  static final purchasePreview = {
    ...purchaseRow,
    'id': null,
    'number': null,
    'lines': [purchaseLine],
  };

  static final receipt = {
    'id': 'pay1',
    'companyId': 'c1',
    'kind': 'receipt',
    'number': 'RCT/26-27/00001',
    'date': '2026-10-22',
    'partyId': 'p1',
    'partyName': 'Mumbai Infra Projects LLP',
    'accountId': 'a-bank',
    'accountName': 'Bank Account',
    'mode': 'upi',
    'reference': 'UTR123456',
    'amount': 800,
    'allocated': 300,
    'unallocated': 500,
    'notes': 'Part payment',
    'status': 'posted',
    'createdAt': '2026-10-22T09:30:00.000Z',
    'createdBy': {'id': 'u1', 'name': 'Asha Rao'},
    'cancelledAt': null,
    'cancelReason': null,
    'allocations': [
      {
        'docType': 'invoice',
        'docId': 'inv1',
        'docNumber': 'INV/26-27/00001',
        'docDate': '2026-10-21',
        'docTotal': 1021,
        'amount': 300,
      },
    ],
  };

  static final vendorPayment = {
    ...receipt,
    'id': 'pay2',
    'kind': 'payment',
    'number': 'PAY/26-27/00001',
    'partyId': 'p2',
    'partyName': 'Bengaluru Steel Suppliers',
    'accountId': 'a-cash',
    'accountName': 'Cash in Hand',
    'mode': 'cash',
    'reference': null,
    'amount': 1728,
    'allocated': 1728,
    'unallocated': 0,
    'notes': null,
    'allocations': [
      {
        'docType': 'purchase',
        'docId': 'pur1',
        'docNumber': 'PUR/26-27/00001',
        'docDate': '2026-10-10',
        'docTotal': 9728,
        'amount': 1728,
      },
    ],
  };

  static final creditNoteLine = {
    ...line,
    'id': 'cnl1',
    'invoiceLineId': 'line1',
    'qty': 1,
    'taxableValue': 399,
    'igst': 111.72,
    'lineTotal': 510.72,
  };

  static final creditNote = {
    'id': 'cn1',
    'companyId': 'c1',
    'invoiceId': 'inv1',
    'invoiceNumber': 'INV/26-27/00001',
    'locationId': 'l1',
    'locationName': 'Head Office',
    'partyId': 'p1',
    'partyName': 'Mumbai Infra Projects LLP',
    'number': 'CN/26-27/00001',
    'fy': '2026-27',
    'noteDate': '2026-10-23',
    'reason': 'Damaged bags',
    'restock': true,
    'placeOfSupply': '27',
    'supplyType': 'inter',
    'status': 'posted',
    'subtotal': 399,
    'cgst': 0,
    'sgst': 0,
    'igst': 111.72,
    'taxTotal': 111.72,
    'roundOff': 0.28,
    'total': 511,
    'createdAt': '2026-10-23T09:30:00.000Z',
    'createdBy': {'id': 'u1', 'name': 'Asha Rao'},
    'cancelledAt': null,
    'cancelReason': null,
    'lines': [creditNoteLine],
  };

  static final creditNotePreview = {...creditNote, 'id': null, 'number': null};

  static final transfer = {
    'id': 'trf1',
    'companyId': 'c1',
    'number': 'TRF/26-27/00001',
    'fromLocationId': 'l1',
    'fromLocationName': 'Head Office',
    'toLocationId': 'l2',
    'toLocationName': 'Site A — Tower 1',
    'status': 'in_transit',
    'transferDate': '2026-10-20',
    'notes': 'Vehicle KA-01-AB-1234',
    'totalValue': 1900,
    'createdAt': '2026-10-20T09:30:00.000Z',
    'createdBy': {'id': 'u1', 'name': 'Asha Rao'},
    'receivedAt': null,
    'receivedBy': null,
    'cancelledAt': null,
    'cancelReason': null,
    'lines': [
      {
        'itemId': 'i1',
        'itemName': 'Portland Cement 53 Grade 50kg',
        'sku': 'CEM-53-50',
        'unit': 'bag',
        'qty': 5,
      },
    ],
  };

  static final receivedTransfer = {
    ...transfer,
    'id': 'trf2',
    'number': 'TRF/26-27/00002',
    'status': 'received',
    'receivedAt': '2026-10-21T09:30:00.000Z',
    'receivedBy': {'id': 'u2', 'name': 'Ravi Kumar'},
  };

  static final expense = {
    'id': 'exp1',
    'companyId': 'c1',
    'number': 'EXP/26-27/00001',
    'expenseDate': '2026-10-19',
    'locationId': 'l2',
    'locationName': 'Site A — Tower 1',
    'accountId': 'a-rent',
    'accountName': 'Electricity',
    'partyId': null,
    'partyName': null,
    'description': 'Diesel for generator',
    'amount': 1000,
    'gstRate': 18,
    'cgst': 90,
    'sgst': 90,
    'igst': 0,
    'total': 1180,
    'paidFromAccountId': 'a-cash',
    'paidFromAccountName': 'Cash in Hand',
    'status': 'posted',
    'createdAt': '2026-10-19T09:30:00.000Z',
    'createdBy': {'id': 'u1', 'name': 'Asha Rao'},
    'cancelledAt': null,
    'cancelReason': null,
  };

  static Map<String, Object?> _account(
    String id,
    String code,
    String name,
    String type,
    String subtype, [
    String? systemKey,
  ]) => {
    'id': id,
    'code': code,
    'name': name,
    'type': type,
    'subtype': subtype,
    'systemKey': systemKey,
    'isSystem': systemKey != null,
    'isActive': true,
    'balance': 0,
  };

  static final cashAccount = _account(
    'a-cash',
    '1000',
    'Cash in Hand',
    'asset',
    'cash',
    'cash',
  );
  static final bankAccount = _account(
    'a-bank',
    '1010',
    'Bank Account',
    'asset',
    'bank',
    'bank',
  );
  static final receivablesAccount = _account(
    'a-ar',
    '1100',
    'Accounts Receivable',
    'asset',
    'receivables',
    'receivables',
  );
  static final rentAccount = _account(
    'a-rent',
    '6020',
    'Electricity',
    'expense',
    'other',
  );
  static final cogsAccount = _account(
    'a-cogs',
    '5000',
    'Cost of Goods Sold',
    'expense',
    'other',
    'cogs',
  );

  static final dashboard = {
    'salesToday': 1021,
    'salesThisMonth': 12345678.9,
    'invoicesThisMonth': 42,
    'lowStockCount': 3,
    'recentInvoices': [invoiceRow, cancelledRow],
    'topItems': [
      {
        'itemId': 'i1',
        'name': 'Portland Cement 53 Grade 50kg',
        'qty': 120,
        'amount': 50400,
      },
    ],
    'receivables': 264910,
    'payables': 8000,
    'cashAndBank': 150000.5,
    'purchasesThisMonth': 9728,
  };

  static final userRow = {
    'id': 'u2',
    'name': 'Ravi Kumar',
    'email': 'supervisor@demo.in',
    'phone': null,
    'isActive': true,
    'assignments': [
      {
        'roleId': 'r2',
        'roleName': 'Site Supervisor',
        'locationIds': ['l2'],
      },
    ],
  };

  static final ownerRole = {
    'id': 'r1',
    'name': 'Owner',
    'description': 'Full access',
    'isSystem': true,
    'permissions': allPermissions.toList(),
  };

  static final auditEntry = {
    'id': 'a1',
    'entity': 'invoice',
    'entityId': 'inv1',
    'action': 'create',
    'userId': 'u1',
    'userName': 'Asha Rao',
    'before': null,
    'after': {'number': 'INV/26-27/00001', 'total': 1021},
    'createdAt': '2026-10-21T09:30:00.000Z',
  };
}
