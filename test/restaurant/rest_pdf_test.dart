import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/company/company_model.dart';
import 'package:onematrix/features/restaurant/rest_models.dart';
import 'package:onematrix/features/restaurant/rest_pdf.dart';

void main() {
  test('KOT and bill PDFs build on 80 mm paper', () async {
    final kot = Kot.fromJson({
      'id': 'k1', 'kotNo': 7, 'station': 'Tandoor', 'status': 'new', 'orderNumber': 'O1', 'kind': 'dine_in',
      'tableName': 'T3', 'covers': 4, 'createdAt': '2026-11-12T12:30:00Z',
      'lines': [
        {'id': 'a', 'name': 'PNR TIKKA', 'qty': 2, 'note': 'less spicy', 'state': 'sent'},
        {'id': 'b', 'name': 'Gone', 'qty': 1, 'state': 'cancelled'},
      ],
    });
    expect(kot.liveLines, hasLength(1));
    final kotPdf = await buildKotPdf(kot);
    expect(String.fromCharCodes(kotPdf.take(4)), '%PDF');

    final order = RestOrder.fromJson({
      'id': 'o1', 'number': 'O1', 'kind': 'dine_in', 'status': 'bill_printed', 'tableName': 'T3', 'covers': 4,
      'bill': {
        'lines': [
          {'name': 'Paneer Tikka', 'qty': 2, 'rate': 240, 'amount': 480, 'gstRate': 5},
        ],
        'gross': 480, 'serviceChargePct': 5, 'serviceCharge': 24, 'taxable': 504, 'cgst': 12.6, 'sgst': 12.6,
        'taxTotal': 25.2, 'roundOff': -0.2, 'total': 529,
        'gstSummary': [
          {'rate': 5, 'taxable': 504, 'cgst': 12.6, 'sgst': 12.6, 'igst': 0},
        ],
      },
    });
    final billPdf = await buildBillPdf(order, const Company(id: 'c', name: 'Spice Route', stateCode: '24'));
    expect(String.fromCharCodes(billPdf.take(4)), '%PDF');
    expect(kRoll80.width, closeTo(226.77, 0.1));
  });
}
