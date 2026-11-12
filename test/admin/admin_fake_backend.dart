import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// In-process stand-in for the accounting, reports and administration
/// endpoints (same approach as `test/support/fake_backend.dart`), serving
/// JSON shaped like the v1.1 contract and the dev server's real responses.
class AdminFakeBackend implements HttpClientAdapter {
  AdminFakeBackend({Set<String>? permissions})
    : permissions = permissions ?? allPermissions;

  static const allPermissions = {
    'dashboard.view',
    'items.view',
    'items.view_cost',
    'parties.view',
    'locations.view',
    'invoices.view',
    'purchases.view',
    'payments.view',
    'expenses.view',
    'users.manage',
    'roles.manage',
    'company.manage',
    'accounts.view',
    'accounts.manage',
    'accounts.journal',
    'reports.view',
  };

  final Set<String> permissions;
  final List<RequestOptions> requests = [];

  /// `'METHOD /path'` → (status, body), checked before the defaults.
  final Map<String, (int, Object?)> overrides = {};

  RequestOptions last(String method, String path) =>
      requests.lastWhere((r) => r.method == method && r.path == path);

  int count(String method, String path) =>
      requests.where((r) => r.method == method && r.path == path).length;

  static (int, Object?) error(
    int status,
    String code,
    String message, [
    Map<String, Object?> details = const {},
  ]) => (
    status,
    {
      'error': {'code': code, 'message': message, 'details': details},
    },
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (status, body) =
        overrides['${options.method} ${options.path}'] ??
        _route(options.method, options.path, options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  Map<String, Object?> _body(RequestOptions o) =>
      Map<String, Object?>.from(o.data as Map? ?? const {});

  (int, Object?) _route(String method, String path, RequestOptions o) {
    Map<String, Object?> page(List<Object?> data) => {
      'data': data,
      'total': data.length,
    };
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    final id = segments.length > 1 ? segments[1] : null;
    switch ((method, path)) {
      case ('POST', '/auth/refresh' || '/auth/login'):
        return (200, authResult);
      case ('GET', '/me'):
        return (200, me(permissions));
      case ('GET', '/company'):
        return (200, company);
      case ('PATCH', '/company'):
        return (200, {...company, ..._body(o)});
      case ('GET', '/locations'):
        return (200, page([headOffice, site]));
      case ('GET', '/parties'):
        return (200, page([customer, vendor]));
      case ('GET', '/accounts'):
        final type = o.queryParameters['type'];
        final active = o.queryParameters['activeOnly'] == 'true';
        return (
          200,
          page([
            for (final a in accounts)
              if ((type == null || a['type'] == type) &&
                  (!active || a['isActive'] == true))
                a,
          ]),
        );
      case ('POST', '/accounts'):
        final b = _body(o);
        return (
          201,
          {
            ...account('a-new', b['code'] as String? ?? '6100', '', 'expense'),
            ...b,
            'subtype': b['subtype'] ?? 'other',
          },
        );
      case ('GET', '/journals'):
        return (200, page([manualJournal, salesJournal, reversalJournal]));
      case ('POST', '/journals'):
        return (
          201,
          {
            ...manualJournal,
            'id': 'j-new',
            'number': 'JV/26-27/00003',
            'narration': _body(o)['narration'],
          },
        );
      case ('GET', '/reports/trial-balance'):
        return (200, trialBalance);
      case ('GET', '/reports/profit-loss'):
        return (200, profitLoss);
      case ('GET', '/reports/balance-sheet'):
        return (200, balanceSheet);
      case ('GET', '/reports/sales-register'):
        return (200, salesRegister);
      case ('GET', '/reports/purchase-register'):
        return (200, purchaseRegister);
      case ('GET', '/reports/gst-summary'):
        return (200, gstSummary);
      case ('GET', '/reports/stock-valuation'):
        return (200, stockValuation);
      case ('GET', '/reports/ageing'):
        return (
          200,
          o.queryParameters['type'] == 'payables' ? payablesAgeing : ageing,
        );
      case ('GET', '/permissions'):
        return (200, permissionDefs);
      case ('GET', '/roles'):
        return (200, page([ownerRole, supervisorRole, clerkRole]));
      case ('POST', '/roles'):
        return (
          201,
          {...clerkRole, ..._body(o), 'id': 'r-new', 'isSystem': false},
        );
      case ('GET', '/users'):
        return (200, page([self, userRow]));
      case ('POST', '/me/password'):
        return (204, null);
    }
    if (segments.length == 2 &&
        segments[0] == 'accounts' &&
        method == 'PATCH') {
      final a = accounts.firstWhere((x) => x['id'] == id, orElse: () => {});
      return (200, {...a, ..._body(o)});
    }
    if (segments.length == 3 &&
        segments[0] == 'accounts' &&
        segments[2] == 'ledger') {
      return (200, {...ledger, 'accountId': id});
    }
    if (segments.length == 2 && segments[0] == 'journals' && method == 'GET') {
      final j = [
        manualJournal,
        salesJournal,
        reversalJournal,
      ].where((x) => x['id'] == id).firstOrNull;
      return j == null
          ? error(404, 'NOT_FOUND', 'Journal not found')
          : (200, j);
    }
    if (segments.length == 3 &&
        segments[0] == 'journals' &&
        segments[2] == 'cancel') {
      return (200, reversalJournal);
    }
    if (segments.length == 2 && segments[0] == 'roles' && method == 'PATCH') {
      return (200, {...clerkRole, ..._body(o)});
    }
    if (segments.length == 2 && segments[0] == 'users' && method == 'PATCH') {
      return (200, {...userRow, ..._body(o)});
    }
    if (segments.length == 3 &&
        segments[0] == 'users' &&
        segments[2] == 'password') {
      return (204, null);
    }
    return error(404, 'NOT_FOUND', 'No fake for $method $path');
  }

  @override
  void close({bool force = false}) {}

  // ------------------------------------------------------------------ Data

  static final user = {
    'id': 'u1',
    'name': 'Asha Rao',
    'email': 'owner@demo.in',
    'phone': '9800000001',
  };

  static final authResult = {
    'accessToken': 'access',
    'refreshToken': 'refresh-2',
    'expiresIn': 900,
    'user': user,
  };

  static final company = <String, Object?>{
    'id': 'c1',
    'name': 'Demo Builders & Traders',
    'legalName': 'Demo Builders & Traders Private Limited',
    'gstin': '24AAACD1234F1Z5',
    'stateCode': '24',
    'pan': 'AAACD1234F',
    'address': '402, Shilp Square, SG Highway, Ahmedabad, Gujarat 380054',
    'phone': '079-4000-1234',
    'email': 'accounts@demobuilders.in',
    'website': 'www.demobuilders.in',
    'bankName': 'HDFC Bank, SG Highway',
    'bankAccountNo': '50200012345678',
    'bankIfsc': 'HDFC0001234',
    'upiId': 'demobuilders@hdfcbank',
    'invoiceTerms':
        '1. Goods once sold will not be taken back.\n2. Interest at 18% p.a. '
        'after the due date.\n3. Subject to Ahmedabad jurisdiction.',
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
    ],
  };

  static final headOffice = {
    'id': 'l1',
    'companyId': 'c1',
    'parentId': null,
    'type': 'branch',
    'name': 'Head Office',
    'code': 'HO',
    'stateCode': '24',
    'address': null,
    'isActive': true,
    'createdAt': '2026-10-01T09:30:00.000Z',
  };

  static final site = {
    ...headOffice,
    'id': 'l2',
    'type': 'site',
    'name': 'Site A — Tower 1',
    'code': 'SA-T1',
  };

  static final customer = {
    'id': 'p1',
    'companyId': 'c1',
    'type': 'customer',
    'name': 'Patel Constructions',
    'gstin': '24AABCP1234C1Z9',
    'stateCode': '24',
    'phone': null,
    'email': null,
    'address': null,
    'creditLimit': 0,
    'creditDays': 30,
    'balance': 114910,
    'createdAt': '2026-10-01T09:30:00.000Z',
  };

  static final vendor = {
    ...customer,
    'id': 'p2',
    'type': 'vendor',
    'name': 'Mumbai Steel Suppliers',
    'gstin': '27AABCT3518Q1ZW',
    'stateCode': '27',
    'balance': -371995,
  };

  static Map<String, Object?> account(
    String id,
    String code,
    String name,
    String type, {
    String subtype = 'other',
    String? systemKey,
    double balance = 0,
    bool active = true,
  }) => {
    'id': id,
    'code': code,
    'name': name,
    'type': type,
    'subtype': subtype,
    'systemKey': systemKey,
    'isSystem': systemKey != null,
    'isActive': active,
    'balance': balance,
  };

  static final accounts = [
    account(
      'a-cash',
      '1000',
      'Cash in Hand',
      'asset',
      subtype: 'cash',
      systemKey: 'cash',
      balance: 65400,
    ),
    account(
      'a-bank',
      '1010',
      'Bank Account',
      'asset',
      subtype: 'bank',
      systemKey: 'bank',
      balance: 2421880,
    ),
    account(
      'a-ar',
      '1100',
      'Accounts Receivable',
      'asset',
      subtype: 'receivables',
      systemKey: 'receivables',
      balance: 174350,
    ),
    account(
      'a-inv',
      '1200',
      'Inventory',
      'asset',
      subtype: 'inventory',
      systemKey: 'inventory',
      balance: 1640013.1,
    ),
    account(
      'a-ap',
      '2000',
      'Accounts Payable',
      'liability',
      subtype: 'payables',
      systemKey: 'payables',
      balance: -371995,
    ),
    account(
      'a-ocgst',
      '2100',
      'Output CGST',
      'liability',
      subtype: 'tax',
      systemKey: 'output_cgst',
      balance: -20655,
    ),
    account(
      'a-cap',
      '3000',
      "Owner's Capital",
      'equity',
      systemKey: 'capital',
      balance: -2500000,
    ),
    account(
      'a-sales',
      '4000',
      'Sales',
      'income',
      systemKey: 'sales',
      balance: -294640,
    ),
    account(
      'a-cogs',
      '5000',
      'Cost of Goods Sold',
      'expense',
      systemKey: 'cogs',
      balance: 263096.9,
    ),
    account('a-rent', '6000', 'Rent', 'expense', balance: 45000),
    account('a-old', '6095', 'Old Site Canteen', 'expense', active: false),
  ];

  static final ledger = {
    'accountId': 'a-cash',
    'accountName': 'Cash in Hand',
    'from': '2026-04-01',
    'to': '2026-10-21',
    'openingBalance': 0,
    'closingBalance': 65400,
    'totalDebit': 68900,
    'totalCredit': 3500,
    'lines': [
      {
        'entryId': 'j1',
        'date': '2026-10-21',
        'voucherType': 'journal',
        'voucherId': null,
        'number': 'JV/26-27/00001',
        'narration': 'Cash withdrawn from bank for site expenses',
        'partyName': null,
        'debit': 50000,
        'credit': 0,
        'balance': 50000,
      },
      {
        'entryId': 'j4',
        'date': '2026-10-21',
        'voucherType': 'receipt',
        'voucherId': 'pay1',
        'number': 'RCT/26-27/00001',
        'narration': 'Received from Walk-in Customer by cash',
        'partyName': 'Walk-in Customer',
        'debit': 18900,
        'credit': 0,
        'balance': 68900,
      },
      {
        'entryId': 'j5',
        'date': '2026-10-21',
        'voucherType': 'expense',
        'voucherId': 'exp2',
        'number': 'EXP/26-27/00002',
        'narration': 'Transport & Freight: Tempo hire for material shifting',
        'partyName': null,
        'debit': 0,
        'credit': 3500,
        'balance': 65400,
      },
    ],
  };

  static final manualJournal = <String, Object?>{
    'id': 'j1',
    'date': '2026-10-21',
    'voucherType': 'journal',
    'voucherId': null,
    'number': 'JV/26-27/00001',
    'narration': 'Cash withdrawn from bank for site expenses',
    'isReversal': false,
    'createdAt': '2026-10-21T08:58:21.932Z',
    'createdBy': {'id': 'u1', 'name': 'Asha Rao'},
    'lines': [
      {
        'accountId': 'a-cash',
        'accountCode': '1000',
        'accountName': 'Cash in Hand',
        'partyId': null,
        'partyName': null,
        'debit': 50000,
        'credit': 0,
      },
      {
        'accountId': 'a-bank',
        'accountCode': '1010',
        'accountName': 'Bank Account',
        'partyId': null,
        'partyName': null,
        'debit': 0,
        'credit': 50000,
      },
    ],
  };

  static final salesJournal = <String, Object?>{
    'id': 'j2',
    'date': '2026-10-20',
    'voucherType': 'sales',
    'voucherId': 'inv1',
    'number': 'INV/26-27/00001',
    'narration': 'Sales invoice to Patel Constructions',
    'isReversal': false,
    'createdAt': '2026-10-20T08:58:21.932Z',
    'createdBy': {'id': 'u1', 'name': 'Asha Rao'},
    'lines': [
      {
        'accountId': 'a-ar',
        'accountCode': '1100',
        'accountName': 'Accounts Receivable',
        'partyId': 'p1',
        'partyName': 'Patel Constructions',
        'debit': 264910,
        'credit': 0,
      },
      {
        'accountId': 'a-sales',
        'accountCode': '4000',
        'accountName': 'Sales',
        'partyId': null,
        'partyName': null,
        'debit': 0,
        'credit': 224500,
      },
      {
        'accountId': 'a-ocgst',
        'accountCode': '2100',
        'accountName': 'Output CGST',
        'partyId': null,
        'partyName': null,
        'debit': 0,
        'credit': 40410,
      },
    ],
  };

  static final reversalJournal = <String, Object?>{
    ...manualJournal,
    'id': 'j3',
    'number': 'JV/26-27/00002',
    'narration': 'Cancelled JV/26-27/00001: duplicate entry',
    'isReversal': true,
    'createdBy': null,
    'lines': [
      {
        ...(manualJournal['lines'] as List)[0] as Map,
        'debit': 0,
        'credit': 50000,
      },
      {
        ...(manualJournal['lines'] as List)[1] as Map,
        'debit': 50000,
        'credit': 0,
      },
    ],
  };

  static final trialBalance = {
    'asOf': '2026-10-21',
    'rows': [
      {
        'accountId': 'a-cash',
        'code': '1000',
        'name': 'Cash in Hand',
        'type': 'asset',
        'debit': 65400,
        'credit': 0,
      },
      {
        'accountId': 'a-bank',
        'code': '1010',
        'name': 'Bank Account',
        'type': 'asset',
        'debit': 2421880,
        'credit': 0,
      },
      {
        'accountId': 'a-ap',
        'code': '2000',
        'name': 'Accounts Payable',
        'type': 'liability',
        'debit': 0,
        'credit': 371995,
      },
      {
        'accountId': 'a-cap',
        'code': '3000',
        'name': "Owner's Capital",
        'type': 'equity',
        'debit': 0,
        'credit': 2500000,
      },
      {
        'accountId': 'a-rent',
        'code': '6000',
        'name': 'Rent',
        'type': 'expense',
        'debit': 384715,
        'credit': 0,
      },
    ],
    'totalDebit': 2871995,
    'totalCredit': 2871995,
  };

  static final profitLoss = {
    'from': '2026-04-01',
    'to': '2026-10-21',
    'revenue': {
      'rows': [
        {
          'accountId': 'a-sales',
          'code': '4000',
          'name': 'Sales',
          'amount': 294640,
        },
        {
          'accountId': 'a-sr',
          'code': '4010',
          'name': 'Sales Returns',
          'amount': -1767,
        },
      ],
      'total': 292873,
    },
    'cogs': {
      'rows': [
        {
          'accountId': 'a-cogs',
          'code': '5000',
          'name': 'Cost of Goods Sold',
          'amount': 263096.9,
        },
      ],
      'total': 263096.9,
    },
    'grossProfit': 29776.1,
    'otherIncome': {'rows': [], 'total': 0},
    'expenses': {
      'rows': [
        {
          'accountId': 'a-rent',
          'code': '6000',
          'name': 'Rent',
          'amount': 45000,
        },
        {
          'accountId': 'a-ro',
          'code': '5900',
          'name': 'Round Off',
          'amount': 0.14,
        },
      ],
      'total': 45000.14,
    },
    'netProfit': -15224.04,
  };

  static final balanceSheet = {
    'asOf': '2026-10-21',
    'assets': {
      'rows': [
        {
          'accountId': 'a-cash',
          'code': '1000',
          'name': 'Cash in Hand',
          'amount': 65400,
        },
        {
          'accountId': 'a-bank',
          'code': '1010',
          'name': 'Bank Account',
          'amount': 2421880,
        },
      ],
      'total': 2487280,
    },
    'liabilities': {
      'rows': [
        {
          'accountId': 'a-ap',
          'code': '2000',
          'name': 'Accounts Payable',
          'amount': 371995,
        },
      ],
      'total': 371995,
    },
    'equity': {
      'rows': [
        {
          'accountId': 'a-cap',
          'code': '3000',
          'name': "Owner's Capital",
          'amount': 2130209.04,
        },
        {
          'accountId': null,
          'code': null,
          'name': 'Profit & Loss',
          'amount': -14924.04,
        },
      ],
      'total': 2115285,
    },
    'totalAssets': 2487280,
    'totalLiabilitiesAndEquity': 2487280,
  };

  static final salesRegister = {
    'rows': [
      {
        'id': 'inv1',
        'number': 'INV/26-27/00001',
        'date': '2026-10-21',
        'partyName': 'Patel Constructions',
        'partyGstin': '24AABCP1234C1Z9',
        'placeOfSupply': '24',
        'taxable': 224500,
        'cgst': 20205,
        'sgst': 20205,
        'igst': 0,
        'total': 264910,
        'status': 'posted',
      },
      {
        'id': 'inv2',
        'number': 'INV/26-27/00002',
        'date': '2026-10-21',
        'partyName': 'Mumbai Infra Projects',
        'partyGstin': '27AAPFU0939F1ZV',
        'placeOfSupply': '27',
        'taxable': 52140,
        'cgst': 0,
        'sgst': 0,
        'igst': 9385.2,
        'total': 61525,
        'status': 'cancelled',
      },
    ],
    'totals': {
      'taxable': 224500,
      'cgst': 20205,
      'sgst': 20205,
      'igst': 0,
      'total': 264910,
    },
  };

  static final purchaseRegister = {
    'rows': [
      {
        'id': 'pur1',
        'number': 'PUR/26-27/00001',
        'supplierInvoiceNo': 'MSS-44521',
        'date': '2026-10-21',
        'partyName': 'Mumbai Steel Suppliers',
        'partyGstin': '27AABCT3518Q1ZW',
        'placeOfSupply': '24',
        'taxable': 315250,
        'cgst': 0,
        'sgst': 0,
        'igst': 56745,
        'total': 371995,
        'status': 'posted',
      },
    ],
    'totals': {
      'taxable': 315250,
      'cgst': 0,
      'sgst': 0,
      'igst': 56745,
      'total': 371995,
    },
  };

  static final gstSummary = {
    'from': '2026-10-01',
    'to': '2026-10-21',
    'outward': {
      'byRate': [
        {'gstRate': 5, 'taxable': 18000, 'cgst': 450, 'sgst': 450, 'igst': 0},
        {
          'gstRate': 18,
          'taxable': 276640,
          'cgst': 20205,
          'sgst': 20205,
          'igst': 9385.2,
        },
      ],
      'b2b': {'count': 2, 'taxable': 276640, 'tax': 49795.2},
      'b2c': {'count': 1, 'taxable': 18000, 'tax': 900},
      'creditNotes': {
        'gstRate': null,
        'taxable': 1767,
        'cgst': 0,
        'sgst': 0,
        'igst': 318.06,
      },
      'net': {
        'gstRate': null,
        'taxable': 292873,
        'cgst': 20655,
        'sgst': 20655,
        'igst': 9067.14,
      },
    },
    'inward': {
      'byRate': [
        {
          'gstRate': 18,
          'taxable': 414250,
          'cgst': 8910,
          'sgst': 8910,
          'igst': 56745,
        },
      ],
      'expenses': {
        'gstRate': null,
        'taxable': 56700,
        'cgst': 4050,
        'sgst': 4050,
        'igst': 0,
      },
      'total': {
        'gstRate': null,
        'taxable': 470950,
        'cgst': 12960,
        'sgst': 12960,
        'igst': 56745,
      },
    },
    'hsn': [
      {
        'hsnCode': '2523',
        'unit': 'bag',
        'qty': 150,
        'taxable': 57000,
        'cgst': 5130,
        'sgst': 5130,
        'igst': 0,
      },
      {
        'hsnCode': '7214',
        'unit': 'kg',
        'qty': 2500,
        'taxable': 167500,
        'cgst': 15075,
        'sgst': 15075,
        'igst': 0,
      },
    ],
    'netPayable': {
      'cgst': 7695,
      'sgst': 7695,
      'igst': -47677.86,
      'total': -32287.86,
    },
  };

  static final stockValuation = {
    'rows': [
      {
        'itemId': 'i1',
        'name': 'Cement OPC 53 Grade (50 kg)',
        'sku': 'CEM-OPC53',
        'unit': 'bag',
        'qty': 1070,
        'avgCost': 333.77,
        'value': 357134.43,
      },
      {
        'itemId': 'i2',
        'name': 'Steel TMT Bar 12 mm',
        'sku': null,
        'unit': 'kg',
        'qty': 16300.5,
        'avgCost': 61.3,
        'value': 999220.65,
      },
    ],
    'totalValue': 1356355.08,
  };

  static final ageing = {
    'asOf': '2026-10-21',
    'rows': [
      {
        'partyId': 'p1',
        'partyName': 'Patel Constructions',
        'notDue': 114910,
        'd1_30': 0,
        'd31_60': 25000,
        'd61_90': 0,
        'd90plus': 10000,
        'total': 149910,
      },
      {
        'partyId': 'p3',
        'partyName': 'Mumbai Infra Projects',
        'notDue': 59440,
        'd1_30': 12000,
        'd31_60': 0,
        'd61_90': 0,
        'd90plus': 0,
        'total': 71440,
      },
    ],
    'totals': {
      'notDue': 174350,
      'd1_30': 12000,
      'd31_60': 25000,
      'd61_90': 0,
      'd90plus': 10000,
      'total': 221350,
    },
  };

  static final payablesAgeing = {
    'asOf': '2026-10-21',
    'rows': [
      {
        'partyId': 'p2',
        'partyName': 'Mumbai Steel Suppliers',
        'notDue': 371995,
        'd1_30': 0,
        'd31_60': 0,
        'd61_90': 0,
        'd90plus': 0,
        'total': 371995,
      },
    ],
    'totals': {
      'notDue': 371995,
      'd1_30': 0,
      'd31_60': 0,
      'd61_90': 0,
      'd90plus': 0,
      'total': 371995,
    },
  };

  static final permissionDefs = [
    {'key': 'dashboard.view', 'module': 'Dashboard', 'label': 'View dashboard'},
    {'key': 'invoices.view', 'module': 'Invoices', 'label': 'View invoices'},
    {
      'key': 'invoices.create',
      'module': 'Invoices',
      'label': 'Create invoices',
    },
    {
      'key': 'invoices.cancel',
      'module': 'Invoices',
      'label': 'Cancel invoices',
    },
    {
      'key': 'users.manage',
      'module': 'Administration',
      'label': 'Manage users',
    },
    {
      'key': 'roles.manage',
      'module': 'Administration',
      'label': 'Manage roles',
    },
    {
      'key': 'company.manage',
      'module': 'Administration',
      'label': 'Edit company profile',
    },
    {
      'key': 'accounts.view',
      'module': 'Accounting',
      'label': 'View accounts, ledgers and financial statements',
    },
    {
      'key': 'accounts.journal',
      'module': 'Accounting',
      'label': 'Post manual journals',
    },
    {
      'key': 'reports.view',
      'module': 'Reports',
      'label': 'View registers, GST summary, ageing and valuation',
    },
  ];

  static final ownerRole = {
    'id': 'r1',
    'name': 'Owner',
    'description': 'Full access, including roles',
    'isSystem': true,
    'permissions': [for (final p in permissionDefs) p['key']],
  };

  static final supervisorRole = {
    'id': 'r2',
    'name': 'Site Supervisor',
    'description': 'Stock, transfers and dashboard for assigned sites only',
    'isSystem': true,
    'permissions': ['dashboard.view', 'stock.view'],
  };

  static final clerkRole = {
    'id': 'r3',
    'name': 'Billing Clerk',
    'description': null,
    'isSystem': false,
    'permissions': ['dashboard.view', 'invoices.view', 'invoices.create'],
  };

  static final self = {
    'id': 'u1',
    'name': 'Asha Rao',
    'email': 'owner@demo.in',
    'phone': '9800000001',
    'isActive': true,
    'assignments': [
      {'roleId': 'r1', 'roleName': 'Owner', 'locationIds': null},
    ],
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
}
