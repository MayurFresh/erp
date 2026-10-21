import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/amount_in_words.dart';

void main() {
  group('amountInWords', () {
    test('small amounts', () {
      expect(amountInWords(0), 'Rupees Zero Only');
      expect(amountInWords(1), 'Rupees One Only');
      expect(amountInWords(15), 'Rupees Fifteen Only');
      expect(amountInWords(20), 'Rupees Twenty Only');
      expect(amountInWords(64), 'Rupees Sixty-Four Only');
      expect(amountInWords(100), 'Rupees One Hundred Only');
      expect(amountInWords(110), 'Rupees One Hundred Ten Only');
    });

    test('Indian grouping (thousand, lakh, crore)', () {
      expect(amountInWords(1000), 'Rupees One Thousand Only');
      expect(amountInWords(100000), 'Rupees One Lakh Only');
      expect(
        amountInWords(264910),
        'Rupees Two Lakh Sixty-Four Thousand Nine Hundred Ten Only',
      );
      expect(amountInWords(10000000), 'Rupees One Crore Only');
      expect(amountInWords(100000001), 'Rupees Ten Crore One Only');
      expect(
        amountInWords(12000000000),
        'Rupees One Thousand Two Hundred Crore Only',
      );
    });

    test('paise', () {
      expect(
        amountInWords(123456789.50),
        'Rupees Twelve Crore Thirty-Four Lakh Fifty-Six Thousand Seven '
        'Hundred Eighty-Nine and Fifty Paise Only',
      );
      expect(amountInWords(0.5), 'Fifty Paise Only');
      expect(amountInWords(1.01), 'Rupees One and One Paise Only');
      // Rounded to paise.
      expect(amountInWords(99.999), 'Rupees One Hundred Only');
    });

    test('negative amounts', () {
      expect(amountInWords(-15), 'Minus Rupees Fifteen Only');
      expect(amountInWords(-0.001), 'Rupees Zero Only');
    });
  });

  test('integerInWords', () {
    expect(integerInWords(0), 'Zero');
    expect(integerInWords(999), 'Nine Hundred Ninety-Nine');
    expect(integerInWords(-21), 'Minus Twenty-One');
  });
}
