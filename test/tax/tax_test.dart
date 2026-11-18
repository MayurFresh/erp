import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/whatsapp.dart';
import 'package:onematrix/features/tax/tax_models.dart';
import 'package:onematrix/features/tax/tax_pickers.dart';
import 'package:onematrix/features/tax/tax_repository.dart';

void main() {
  group('whatsapp', () {
    test('normalizes Indian phones', () {
      expect(normalizeIndianPhone('98765 43210'), '919876543210');
      expect(normalizeIndianPhone('+91-9876543210'), '919876543210');
      expect(normalizeIndianPhone('09876543210'), '919876543210');
      expect(normalizeIndianPhone('12345'), isNull);
      expect(normalizeIndianPhone(null), isNull);
    });

    test('wa.me url', () {
      final u = whatsAppUri(phone: '9876543210', text: 'Hi & bye');
      expect(u.host, 'wa.me');
      expect(u.path, '/919876543210');
      expect(u.queryParameters['text'], 'Hi & bye');
      expect(whatsAppUri(text: 'x').path, '/');
    });

    test('texts', () {
      final t = invoiceWhatsAppText(
        companyName: 'Acme',
        number: 'INV-1',
        invoiceDate: '2026-04-01',
        amountDue: 1180,
        upiLink: 'upi://pay?pa=a@b',
      );
      expect(t, contains('Invoice INV-1 from Acme'));
      expect(t, contains('Pay by UPI: upi://pay?pa=a@b'));
      expect(
        invoiceWhatsAppText(
          companyName: 'Acme',
          number: 'INV-1',
          invoiceDate: null,
          amountDue: 0,
        ),
        contains('Paid in full'),
      );
      expect(
        duesReminderText(companyName: 'Acme', partyName: 'Ravi', amountDue: 50),
        startsWith('Dear Ravi,'),
      );
    });

    test('upi uri', () {
      expect(
        buildUpiUri(
          upiId: 'acme@upi',
          payeeName: 'Acme Co',
          amount: 1180.5,
          note: 'INV 1',
        ),
        'upi://pay?pa=acme@upi&pn=Acme%20Co&am=1180.50&tn=INV%201&cu=INR',
      );
    });
  });

  group('models', () {
    test('GstRate.fromJson', () {
      final r = GstRate.fromJson({
        'id': 'g1',
        'rate': '18',
        'kind': 'goods',
        'label': '18%',
        'effectiveFrom': '2025-09-22',
        'isLegacy': true,
      });
      expect(r.rate, 18);
      expect(r.kind, 'goods');
      expect(r.isLegacy, isTrue);
      expect(r.effectiveTo, isNull);
    });

    test('TdsCalc.fromJson', () {
      final c = TdsCalc.fromJson({
        'sectionId': 's1',
        'sectionCode': '194C',
        'rate': 1,
        'gross': '100000',
        'base': 100000,
        'amount': '1000',
        'fyGross': 150000,
        'threshold': 30000,
        'reason': 'single',
      });
      expect(c.amount, 1000);
      expect(c.threshold, 30000);
      expect(c.reasonText, contains('threshold'));
    });
  });

  testWidgets('GstRatePicker shows offered rates and legacy value', (
    tester,
  ) async {
    double? picked;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gstRatesProvider.overrideWith(
            (ref, q) async => [
              const GstRate(
                id: '1',
                rate: 5,
                kind: 'any',
                label: '5%',
                effectiveFrom: '2025-09-22',
              ),
              const GstRate(
                id: '2',
                rate: 18,
                kind: 'any',
                label: '18%',
                effectiveFrom: '2025-09-22',
              ),
            ],
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: GstRatePicker(value: 12, onChanged: (v) => picked = v),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('(legacy)'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<double>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('18%').last);
    await tester.pumpAndSettle();
    expect(picked, 18);
  });
}
