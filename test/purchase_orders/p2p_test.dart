import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/features/purchase_orders/bill_from_grn_screen.dart';
import 'package:progen_erp/features/purchase_orders/po_detail_screen.dart';
import 'package:progen_erp/features/purchase_orders/po_form_screen.dart';
import 'package:progen_erp/features/purchase_orders/purchase_orders_screen.dart';
import 'package:progen_erp/features/purchase_orders/receive_goods_screen.dart';
import 'package:progen_erp/features/purchase_orders/reorder_screen.dart';
import 'package:progen_erp/features/stock_counts/stock_count_screen.dart';
import 'package:progen_erp/features/stock_counts/stock_counts_screen.dart';

import 'p2p_harness.dart';

Map<String, Object?> err(String code, String message, [Object? details]) => {
  'error': {
    'code': code,
    'message': message,
    'details': ?details,
  },
};

FakeControlsBackend baseBackend() => FakeControlsBackend()
  ..on('GET /locations', pageOf([]))
  ..on('GET /purchase-orders/po1', poJson())
  ..on('GET /goods-receipts', pageOf([]));

Future<void> scanText(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).first, text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  for (final size in p2pSizes) {
    final tag = '${size.width.toInt()}px';

    group('purchase orders $tag', () {
      testWidgets('list shows orders with status and progress', (tester) async {
        final b = baseBackend()
          ..on('GET /purchase-orders', pageOf([poJson(withLines: false)]));
        await pumpP2p(tester, const PurchaseOrdersScreen(), b, size: size);
        expect(find.text('PO/26-27/00001'), findsWidgets);
        expect(find.text('Partly received'), findsWidgets);
        expect(find.text('New order'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('list hides create actions without manage permission', (
        tester,
      ) async {
        final b = baseBackend()..on('GET /purchase-orders', pageOf([]));
        await pumpP2p(
          tester,
          const PurchaseOrdersScreen(),
          b,
          size: size,
          permissions: {'purchase_orders.view'},
        );
        expect(find.text('New order'), findsNothing);
        expect(find.text('No purchase orders found.'), findsOneWidget);
      });

      testWidgets('detail shows progress per line and actions', (tester) async {
        final b = baseBackend();
        await pumpP2p(tester, const PoDetailScreen(poId: 'po1'), b, size: size);
        expect(find.text('Cement 50kg'), findsWidgets);
        expect(find.textContaining('Received 4 of 10'), findsWidgets);
        expect(find.textContaining('Billed 0 of 10'), findsWidgets);
        expect(find.text('Receive goods'), findsWidgets);
        expect(tester.takeException(), isNull);
      });

      testWidgets('detail of a view-only user has no actions', (tester) async {
        final b = baseBackend();
        await pumpP2p(
          tester,
          const PoDetailScreen(poId: 'po1'),
          b,
          size: size,
          permissions: {'purchase_orders.view'},
        );
        expect(find.text('Receive goods'), findsNothing);
        expect(find.text('Cancel order'), findsNothing);
      });

      testWidgets('detail of a draft offers submit and edit', (tester) async {
        final b = baseBackend()
          ..on('GET /purchase-orders/po1', poJson(status: 'draft'));
        await pumpP2p(tester, const PoDetailScreen(poId: 'po1'), b, size: size);
        expect(find.text('Submit'), findsWidgets);
        expect(find.text('Draft'), findsWidgets);
      });

      testWidgets('form renders and edit loads the order', (tester) async {
        final b = baseBackend()
          ..on('GET /parties/p1', {
            'id': 'p1',
            'name': 'Acme Steel',
            'type': 'vendor',
            'companyId': 'c1',
          })
          ..on('POST /purchase-orders/preview', poJson())
          ..on('GET /purchase-orders/po1', poJson(status: 'draft'));
        await pumpP2p(tester, const PoFormScreen(poId: 'po1'), b, size: size);
        expect(find.text('Edit purchase order'), findsOneWidget);
        expect(find.text('Acme Steel'), findsWidgets);
        expect(tester.takeException(), isNull);
      });
    });

    group('receive goods $tag', () {
      testWidgets('a scan adds one to the accepted quantity', (tester) async {
        final b = baseBackend()
          ..on(
            'POST /goods-receipts',
            err('OVER_RECEIPT', 'Too much', {
              'lines': [
                {
                  'poLineId': 'pl1',
                  'itemName': 'Cement 50kg',
                  'allowed': 6,
                  'receiving': 7,
                },
              ],
            }),
            status: 400,
          );
        await pumpP2p(
          tester,
          const ReceiveGoodsScreen(poId: 'po1'),
          b,
          size: size,
        );
        await scanText(tester, 'cem50');
        await scanText(tester, 'CEM50');
        expect(find.textContaining('Cement 50kg: 2'), findsOneWidget);
        final scanField = tester.widget<TextField>(
          find.byType(TextField).first,
        );
        expect(scanField.focusNode!.hasFocus, isTrue);

        await tester.ensureVisible(find.text('Save receipt'));
        await tester.tap(find.text('Save receipt'));
        await tester.pumpAndSettle();
        final body = b.last('POST', '/goods-receipts')!.data as Map;
        expect((body['lines'] as List).single['acceptedQty'], 2);
        expect(find.text('Only 6 can be received'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('an unknown code is reported and focus stays', (
        tester,
      ) async {
        final b = baseBackend()..on('GET /items', pageOf([]));
        await pumpP2p(
          tester,
          const ReceiveGoodsScreen(poId: 'po1'),
          b,
          size: size,
        );
        await scanText(tester, 'NOPE123');
        expect(find.textContaining('is not on this order'), findsOneWidget);
        final scanField = tester.widget<TextField>(
          find.byType(TextField).first,
        );
        expect(scanField.focusNode!.hasFocus, isTrue);
      });
    });

    group('bill from receipt $tag', () {
      testWidgets('shows the price difference and the override prompt', (
        tester,
      ) async {
        final b = baseBackend()
          ..on('GET /goods-receipts/g1', grnJson())
          ..on(
            'POST /purchases',
            err(
              'PRICE_VARIANCE',
              'The bill price differs from the purchase order.',
              {
                'lines': [
                  {
                    'index': 0,
                    'grnLineId': 'gl1',
                    'itemName': 'Cement 50kg',
                    'poRate': 400,
                    'billRate': 420,
                    'variancePct': 5,
                    'varianceValue': 80,
                  },
                ],
              },
            ),
            status: 409,
          );
        await pumpP2p(
          tester,
          const BillFromGrnScreen(grnId: 'g1'),
          b,
          size: size,
        );
        expect(find.text('Create bill from receipt'), findsOneWidget);
        expect(find.textContaining('Differs from the order'), findsNothing);

        final price = find.widgetWithText(TextFormField, 'Bill price');
        await tester.ensureVisible(price);
        await tester.enterText(price, '420');
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Differs from the order by 5%'),
          findsOneWidget,
        );

        final save = find.text('Save bill');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        final body = b.last('POST', '/purchases')!.data as Map;
        final line = (body['lines'] as List).single as Map;
        expect(line['grnLineId'], 'gl1');
        expect(line['rate'], 420);
        expect(body.containsKey('acceptVariance'), isFalse);
        expect(find.text('Accept the price difference'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });

    group('reorder suggestions $tag', () {
      testWidgets('lists suggestions and creates orders for the selection', (
        tester,
      ) async {
        final b = baseBackend()
          ..on(
            'GET /reorder-suggestions',
            pageOf([
              {
                'itemId': 'i1',
                'itemName': 'Cement 50kg',
                'sku': 'CEM50',
                'unit': 'bag',
                'locationId': 'l1',
                'locationName': 'Main store',
                'onHand': 2,
                'reserved': 0,
                'openPoQty': 0,
                'position': 2,
                'reorderLevel': 10,
                'suggestedQty': 18,
                'lastVendorId': 'p1',
                'lastVendorName': 'Acme Steel',
                'lastRate': 400,
              },
            ]),
          )
          ..on('POST /reorder-suggestions/purchase-orders', {
            'data': [poJson(status: 'draft')],
          }, status: 201);
        await pumpP2p(tester, const ReorderScreen(), b, size: size);
        expect(find.text('Cement 50kg'), findsOneWidget);
        expect(find.text('0 selected'), findsOneWidget);
        await tester.tap(find.byType(Checkbox).first);
        await tester.pumpAndSettle();
        expect(find.text('1 selected'), findsOneWidget);
        expect(find.text('Acme Steel'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('empty state', (tester) async {
        final b = baseBackend()..on('GET /reorder-suggestions', pageOf([]));
        await pumpP2p(tester, const ReorderScreen(), b, size: size);
        expect(find.textContaining('Nothing to reorder'), findsOneWidget);
      });
    });

    group('stock counts $tag', () {
      testWidgets('list renders', (tester) async {
        final b = baseBackend()
          ..on(
            'GET /stock-counts',
            pageOf([
              {
                'id': 'c1',
                'number': 'CNT/26-27/00001',
                'status': 'open',
                'locationId': 'l1',
                'locationName': 'Main store',
                'scope': 'all',
                'snapshotAt': '2026-11-03T09:00:00Z',
                'lineCount': 2,
                'countedCount': 1,
              },
            ]),
          );
        await pumpP2p(tester, const StockCountsScreen(), b, size: size);
        expect(find.text('CNT/26-27/00001'), findsWidgets);
        expect(find.text('New count'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('scan field has focus, keeps it, and counts by Enter', (
        tester,
      ) async {
        final b = baseBackend()
          ..on('GET /stock-counts/c1', countJson())
          ..on('POST /stock-counts/c1/scans', {
            'duplicate': false,
            'line': (countJson(counted: true)['lines'] as List).first,
          });
        await pumpP2p(
          tester,
          const StockCountScreen(countId: 'c1'),
          b,
          size: size,
        );
        TextField field() =>
            tester.widget<TextField>(find.byType(TextField).first);
        expect(field().focusNode!.hasFocus, isTrue);

        await scanText(tester, 'CEM50');
        final body = b.last('POST', '/stock-counts/c1/scans')!.data as Map;
        expect(body['code'], 'CEM50');
        expect(body['mode'], 'add');
        expect((body['scanId'] as String).isNotEmpty, isTrue);
        expect(find.textContaining('Cement 50kg: counted 8'), findsOneWidget);
        expect(field().focusNode!.hasFocus, isTrue);
        expect(field().controller!.text, isEmpty);
        expect(tester.takeException(), isNull);
      });

      testWidgets('an unknown barcode shows an error and keeps focus', (
        tester,
      ) async {
        final b = baseBackend()
          ..on('GET /stock-counts/c1', countJson())
          ..on(
            'POST /stock-counts/c1/scans',
            err('UNKNOWN_BARCODE', 'No item has that barcode.'),
            status: 400,
          );
        await pumpP2p(
          tester,
          const StockCountScreen(countId: 'c1'),
          b,
          size: size,
        );
        await scanText(tester, 'ZZZ');
        expect(
          find.textContaining('No item has that barcode.'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .focusNode!
              .hasFocus,
          isTrue,
        );
      });

      testWidgets('posting over the limit explains who can approve', (
        tester,
      ) async {
        final b = baseBackend()
          ..on('GET /stock-counts/c1', countJson(counted: true))
          ..on(
            'POST /stock-counts/c1/post',
            err('COUNT_APPROVAL_REQUIRED', 'Approval needed', {
              'varianceValue': 25000,
              'thresholdValue': 10000,
            }),
            status: 403,
          );
        await pumpP2p(
          tester,
          const StockCountScreen(countId: 'c1'),
          b,
          size: size,
        );
        expect(find.textContaining('Matches'), findsNothing);
        await tester.tap(find.text('Post count'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Post count'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Approval needed'), findsOneWidget);
        expect(find.textContaining('count approval rights'), findsOneWidget);
      });

      testWidgets('a posted count is read only', (tester) async {
        final b = baseBackend()
          ..on(
            'GET /stock-counts/c1',
            countJson(status: 'posted', counted: true),
          );
        await pumpP2p(
          tester,
          const StockCountScreen(countId: 'c1'),
          b,
          size: size,
        );
        expect(find.byType(TextField), findsOneWidget); // only the search field
        expect(find.text('Post count'), findsNothing);
      });
    });
  }
}
