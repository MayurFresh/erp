import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/validators.dart';

TextEditingValue _type(TextInputFormatter f, String from, String to) =>
    f.formatEditUpdate(
      TextEditingValue(text: from),
      TextEditingValue(
        text: to,
        selection: TextSelection.collapsed(offset: to.length),
      ),
    );

void main() {
  gstinChecksumTests();
  group('identifiers', () {
    test('GSTIN', () {
      expect(validateGstin('27AAPFU0939F1ZV'), isNull);
      expect(validateGstin(''), isNull);
    // An unchanged saved value is not re-checked.
    expect(validateGstin('24AAACD1234F1Z5', original: '24aaacd1234f1z5'), isNull);
    expect(validateGstin('24AABCP1234C1Z9', original: '24AAACD1234F1Z5'), isNotNull);
      expect(validateGstin('', required: true), isNotNull);
      expect(validateGstin('27AAPFU0939F1Z'), isNotNull);
      expect(validateGstin('99AAPFU0939F1ZV'), isNotNull);
      expect(gstinChecksumValid('27AAPFU0939F1ZV'), isTrue);
      expect(gstinChecksumValid('27AAPFU0939F1ZX'), isFalse);
    });

    test('PAN, TAN, IFSC, pincode, Udyam', () {
      expect(validatePan('ABCDE1234F'), isNull);
      expect(validatePan('abcde1234f'), isNull);
      expect(validatePan('ABCDE12345'), isNotNull);
      expect(validatePan('', isRequired: true), isNotNull);
      expect(validateTan('DELA12345B'), isNull);
      expect(validateTan('DEL12345B'), isNotNull);
      expect(validateIfsc('HDFC0001234'), isNull);
      expect(validateIfsc('HDFC1001234'), isNotNull);
      expect(validatePincode('560001'), isNull);
      expect(validatePincode('060001'), isNotNull);
      expect(validatePincode('5600'), isNotNull);
      expect(validateUdyam('UDYAM-KA-01-1234567'), isNull);
      expect(validateUdyam('UDYAM-KA-1-1234567'), isNotNull);
    });

    test('empty optional values pass', () {
      expect(validatePan(''), isNull);
      expect(validateTan(null), isNull);
      expect(validateIfsc(' '), isNull);
      expect(validatePincode(''), isNull);
      expect(validateUdyam(''), isNull);
      expect(validateMobile(''), isNull);
      expect(validatePhone(''), isNull);
      expect(validatePincode('', isRequired: true), 'PIN code is required');
    });

    test('mobile, phone, email', () {
      expect(validateMobile('9876543210'), isNull);
      expect(validateMobile('+91 98765 43210'), isNull);
      expect(validateMobile('1234567890'), isNotNull);
      expect(validateMobile('98765'), isNotNull);
      expect(validateMobile('', isRequired: true), isNotNull);
      expect(validatePhone('080 2345 6789'), isNull);
      expect(validatePhone('abc'), isNotNull);
      expect(validateEmail('a@b.in'), isNull);
      expect(validateEmail('a@b'), isNotNull);
      expect(validateEmail('', required: false), isNull);
      expect(validateEmail(''), isNotNull);
    });

    test('required and max length', () {
      expect(requiredValue('  ', 'Name'), 'Name is required');
      expect(requiredValue('x'), isNull);
      expect(maxLength('abc', 2), isNotNull);
      expect(maxLength('ab', 2), isNull);
      expect(validateName('a' * 201), isNotNull);
      expect(validateNotes('a' * 2001), isNotNull);
    });
  });

  group('parseIndianNumber', () {
    test('accepts Indian grouping and currency symbol', () {
      expect(parseIndianNumber('1,00,000'), 100000);
      expect(parseIndianNumber('₹ 12,34,567.50'), 1234567.5);
      expect(parseIndianNumber('-5'), -5);
      expect(parseIndianNumber('.5'), 0.5);
    });

    test('rejects letters and garbage', () {
      expect(parseIndianNumber('12a'), isNull);
      expect(parseIndianNumber('1e5'), isNull);
      expect(parseIndianNumber('1.2.3'), isNull);
      expect(parseIndianNumber(''), isNull);
      expect(parseIndianNumber(null), isNull);
      expect(parseIndianNumber('abc'), isNull);
    });
  });

  group('NumberInputFormatter', () {
    test('strips grouping so controllers keep plain digits', () {
      expect(_type(moneyInput(), '', '1,00,000').text, '100000');
    });

    test('rejects letters', () {
      expect(_type(moneyInput(), '12', '12a').text, '12');
    });

    test('money caps at 2 decimals, quantity at 3', () {
      expect(_type(moneyInput(), '1.25', '1.255').text, '1.25');
      expect(_type(qtyInput(), '1.255', '1.2555').text, '1.255');
      expect(_type(qtyInput(), '1.25', '1.255').text, '1.255');
    });

    test('percent stays within 0-100', () {
      expect(_type(percentInput(), '10', '100').text, '100');
      expect(_type(percentInput(), '100', '1000').text, '100');
      expect(_type(percentInput(), '5', '-5').text, '5');
    });

    test('number validators enforce limits', () {
      expect(validatePercent('101'), isNotNull);
      expect(validatePercent('18'), isNull);
      expect(validateMoney('abc'), isNotNull);
      expect(validateMoney('10.50'), isNull);
      expect(validateQty('1.2345'), isNotNull);
    });
  });

  group('document dates', () {
    test('bounded to 2000-01-01 .. today + 365', () {
      final now = DateTime(2026, 10, 30);
      expect(isDocDateAllowed(DateTime(1999, 12, 31), now), isFalse);
      expect(isDocDateAllowed(DateTime(2000, 1, 1), now), isTrue);
      expect(isDocDateAllowed(DateTime(2027, 10, 30), now), isTrue);
      expect(isDocDateAllowed(DateTime(2027, 11, 1), now), isFalse);
    });
  });
}

void gstinChecksumTests() {
  test('GSTIN check digit is enforced by the form validator', () {
    expect(validateGstin('24AAACD1234F1ZD'), isNull);
    expect(validateGstin('24AAACD1234F1Z5'), isNotNull);
    expect(validateGstin(''), isNull);
  });
}
