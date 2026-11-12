import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/features/construction/models/boq_paste.dart';
import 'package:progen_erp/features/construction/models/project_models.dart';

void main() {
  group('BOQ paste', () {
    test('tab separated rows from Excel, default column order', () {
      final r = parseBoqPaste(
        '1.1\tExcavation in ordinary soil\tcum\t120\t450\n'
        '1.2\tPCC 1:4:8\tcum\t35.5\t5200\t150000\t30000\t0\n',
      );
      expect(r.errors, isEmpty);
      expect(r.hasHeader, isFalse);
      expect(r.lines, [
        const BoqLineInput(
          code: '1.1',
          description: 'Excavation in ordinary soil',
          unit: 'cum',
          qty: 120,
          rate: 450,
        ),
        const BoqLineInput(
          code: '1.2',
          description: 'PCC 1:4:8',
          unit: 'cum',
          qty: 35.5,
          rate: 5200,
          materialBudget: 150000,
          labourBudget: 30000,
          otherBudget: 0,
        ),
      ]);
      expect(r.totalAmount, 120 * 450 + 35.5 * 5200);
      expect(r.canImport, isTrue);
    });

    test('header row maps columns by name in any order; amount ignored', () {
      final r = parseBoqPaste(
        'Description\tItem No\tQty\tUOM\tUnit Rate\tAmount\n'
        'Brickwork in CM 1:6\t3.1\t80\tcum\t₹6,450.00\t516000\n',
      );
      expect(r.hasHeader, isTrue);
      expect(r.errors, isEmpty);
      expect(r.lines.single.code, '3.1');
      expect(r.lines.single.unit, 'cum');
      expect(r.lines.single.rate, 6450);
      expect(r.lines.single.qty, 80);
    });

    test('CSV with quotes, Indian grouping and CRLF', () {
      final r = parseBoqPaste(
        'code,description,unit,qty,rate\r\n'
        '4.2,"Plaster 12 mm, CM 1:4",sqm,"1,250","Rs. 1,20,000.50"\r\n',
      );
      expect(r.errors, isEmpty);
      final line = r.lines.single;
      expect(line.description, 'Plaster 12 mm, CM 1:4');
      expect(line.qty, 1250);
      expect(line.rate, 120000.5);
      expect(splitCsvLine('a,"b ""c""",d'), ['a', 'b "c"', 'd']);
    });

    test('section headings and blank rows are skipped', () {
      final r = parseBoqPaste(
        '2\tEARTHWORK\n'
        '\n'
        '2.1\tExcavation\tcum\t10\t400\n'
        '3, Concrete work\n',
      );
      expect(r.hasHeader, isFalse);
      expect(r.skippedHeadings, 2);
      expect(r.lines, hasLength(1));
    });

    test('bad rows are reported with their row number', () {
      final r = parseBoqPaste(
        '1.1\tExcavation\tcum\tabc\t450\n'
        '\tNo code\tcum\t5\t10\n'
        '1.3\tZero qty\tnos\t0\t-5\n',
      );
      expect(r.lines, isEmpty);
      expect(r.canImport, isFalse);
      expect(r.errors.map((e) => e.toString()), [
        'Row 1: qty "abc" is not a number',
        'Row 2: code is missing',
        'Row 3: qty must be more than 0, rate cannot be negative',
      ]);
    });

    test('rounds qty to 3 and money to 2 decimals', () {
      final line = parseBoqPaste(
        '1\tX\tkg\t1.23456\t9.999\t1.005',
      ).lines.single;
      expect(line.qty, 1.235);
      expect(line.rate, 10);
      expect(parseSheetNumber(' 12 345 '), 12345);
      expect(parseSheetNumber('INR 50'), 50);
      expect(parseSheetNumber('n/a'), isNull);
    });

    test('more than 500 lines cannot be imported at once', () {
      final text = [
        for (var i = 0; i < 501; i++) '$i\tLine $i\tnos\t1\t1',
      ].join('\n');
      final r = parseBoqPaste(text);
      expect(r.lines, hasLength(501));
      expect(r.errors.single.message, contains('at most 500'));
      expect(r.canImport, isFalse);
    });

    test('empty input', () {
      expect(parseBoqPaste('  \n\n').isEmpty, isTrue);
    });
  });
}
