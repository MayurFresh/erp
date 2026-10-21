import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/permissions.dart';
import 'package:progen_erp/features/auth/auth_models.dart';
import 'package:progen_erp/features/invoices/invoice_model.dart';
import 'package:progen_erp/features/items/item_model.dart';
import 'package:progen_erp/features/stock/stock_models.dart';

void main() {
  group('Me.fromJson', () {
    final json = {
      'user': {
        'id': 'u1',
        'name': 'Asha Rao',
        'email': 'asha@demo.in',
        'phone': null,
      },
      'companies': [
        {
          'id': 'c1',
          'name': 'Demo Builders',
          'legalName': 'Demo Builders Pvt Ltd',
          'gstin': '29AAACD1234E1Z5',
          'stateCode': '29',
          'pan': null,
          'address': null,
          'roles': [
            {'id': 'r1', 'name': 'Owner'},
          ],
          'permissions': [Perm.itemsView, Perm.itemsViewCost],
          'locationIds': null,
        },
        {
          'id': 'c2',
          'name': 'Site Co',
          'legalName': null,
          'gstin': null,
          'stateCode': '27',
          'pan': null,
          'address': null,
          'roles': [
            {'id': 'r2', 'name': 'Site Supervisor'},
          ],
          'permissions': [Perm.stockView],
          'locationIds': ['l1', 'l2'],
        },
      ],
    };

    test('parses user and memberships', () {
      final me = Me.fromJson(json);
      expect(me.user.name, 'Asha Rao');
      expect(me.user.phone, isNull);
      expect(me.user.initials, 'AR');
      expect(me.companies, hasLength(2));

      final first = me.companies.first;
      expect(first.legalName, 'Demo Builders Pvt Ltd');
      expect(first.roles.single.name, 'Owner');
      expect(first.can(Perm.itemsViewCost), isTrue);
      expect(first.can(Perm.usersManage), isFalse);
      expect(first.locationIds, isNull);
      expect(first.allLocations, isTrue);

      final second = me.company('c2')!;
      expect(second.stateCode, '27');
      expect(second.locationIds, ['l1', 'l2']);
      expect(second.allLocations, isFalse);
      expect(me.company('missing'), isNull);
    });

    test('AuthResult carries tokens and user', () {
      final result = AuthResult.fromJson({
        'accessToken': 'a',
        'refreshToken': 'r',
        'expiresIn': 900,
        'user': json['user'],
      });
      expect(result.tokens.accessToken, 'a');
      expect(result.tokens.refreshToken, 'r');
      expect(result.tokens.expiresIn, 900);
      expect(result.user.email, 'asha@demo.in');
    });
  });

  group('Item.fromJson', () {
    final base = {
      'id': 'i1',
      'companyId': 'c1',
      'name': 'Cement 50kg',
      'sku': 'CEM-50',
      'hsnCode': '2523',
      'unit': 'bag',
      'gstRate': 28,
      'salePrice': 420.5,
      'trackStock': true,
      'reorderLevel': 20,
      'isActive': true,
      'createdAt': '2026-10-21T09:30:00.000Z',
      'updatedAt': '2026-10-21T09:30:00.000Z',
    };

    test('reads purchasePrice when present', () {
      final item = Item.fromJson({...base, 'purchasePrice': 380});
      expect(item.name, 'Cement 50kg');
      expect(item.gstRate, 28.0);
      expect(item.salePrice, 420.5);
      expect(item.purchasePrice, 380.0);
      expect(item.reorderLevel, 20.0);
      expect(item.createdAt, DateTime.utc(2026, 10, 21, 9, 30));
    });

    test('purchasePrice is null when absent (no items.view_cost)', () {
      final item = Item.fromJson(base);
      expect(item.purchasePrice, isNull);
      expect(item.sku, 'CEM-50');
    });

    test('input JSON includes cost only when allowed', () {
      final input = ItemInput.fromItem(
        Item.fromJson({...base, 'purchasePrice': 380}),
      );
      expect(
        input.toJson(includeCost: false).containsKey('purchasePrice'),
        isFalse,
      );
      expect(input.toJson(includeCost: true)['purchasePrice'], 380.0);
      expect(input.toJson(includeCost: false).containsKey('isActive'), isFalse);
    });
  });

  group('Invoice.fromJson', () {
    final line = {
      'id': 'line1',
      'itemId': 'i1',
      'description': 'Cement 50kg',
      'hsnCode': '2523',
      'qty': 2,
      'unit': 'bag',
      'rate': 100,
      'discountPct': 0,
      'taxableValue': 200,
      'gstRate': 18,
      'cgst': 0,
      'sgst': 0,
      'igst': 36,
      'lineTotal': 236,
    };
    final invoice = {
      'id': 'inv1',
      'companyId': 'c1',
      'locationId': 'l1',
      'locationName': 'Head Office',
      'partyId': 'p1',
      'partyName': 'Mumbai Traders',
      'partyGstin': '27AAPFU0939F1ZV',
      'number': 'INV/26-27/00001',
      'fy': '2026-27',
      'invoiceDate': '2026-10-21',
      'placeOfSupply': '27',
      'supplyType': 'inter',
      'status': 'posted',
      'subtotal': 200,
      'cgst': 0,
      'sgst': 0,
      'igst': 36,
      'taxTotal': 36,
      'roundOff': 0,
      'total': 236,
      'notes': null,
      'createdAt': '2026-10-21T09:30:00.000Z',
      'createdBy': {'id': 'u1', 'name': 'Asha Rao'},
      'cancelledAt': null,
      'cancelReason': null,
      'lines': [line],
    };

    test('parses header, totals and lines', () {
      final inv = Invoice.fromJson(invoice);
      expect(inv.number, 'INV/26-27/00001');
      expect(inv.isInterState, isTrue);
      expect(inv.status, InvoiceStatus.posted);
      expect(inv.igst, 36.0);
      expect(inv.total, 236.0);
      expect(inv.createdBy?.name, 'Asha Rao');
      expect(inv.lines, hasLength(1));
      expect(inv.lines!.single.igst, 36.0);
      expect(inv.lines!.single.taxTotal, 36.0);
    });

    test('list rows have no lines', () {
      final inv = Invoice.fromJson(Map.of(invoice)..remove('lines'));
      expect(inv.lines, isNull);
    });

    test('preview has null id and number', () {
      final inv = Invoice.fromJson({
        ...invoice,
        'id': null,
        'number': null,
        'createdBy': null,
        'createdAt': null,
        'status': 'cancelled',
      });
      expect(inv.id, isNull);
      expect(inv.number, isNull);
      expect(inv.createdBy, isNull);
      expect(inv.isCancelled, isTrue);
      expect(inv.lines!.single.id, 'line1');
    });

    test('draft JSON omits optional fields', () {
      const draft = InvoiceDraft(
        locationId: 'l1',
        partyId: 'p1',
        lines: [InvoiceDraftLine(itemId: 'i1', qty: 2)],
      );
      expect(draft.toJson(), {
        'locationId': 'l1',
        'partyId': 'p1',
        'lines': [
          {'itemId': 'i1', 'qty': 2.0},
        ],
      });
    });
  });

  test('StockBalance value is optional', () {
    final row = {
      'itemId': 'i1',
      'itemName': 'Cement',
      'sku': null,
      'unit': 'bag',
      'locationId': 'l1',
      'locationName': 'Head Office',
      'qty': 5,
      'reorderLevel': 10,
    };
    expect(StockBalance.fromJson(row).value, isNull);
    expect(StockBalance.fromJson(row).isLow, isTrue);
    expect(StockBalance.fromJson({...row, 'value': 1900}).value, 1900.0);
  });
}
