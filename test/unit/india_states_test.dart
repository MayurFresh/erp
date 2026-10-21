import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/india_states.dart';

void main() {
  test('state list covers 01–38 and 97', () {
    final codes = indiaStates.map((s) => s.code).toList();
    expect(codes.first, '01');
    expect(codes, containsAll(['07', '27', '29', '36', '37', '38', '97']));
    expect(codes.toSet(), hasLength(codes.length));
    expect(stateName('01'), 'Jammu & Kashmir');
    expect(stateName('38'), 'Ladakh');
    expect(stateName('97'), 'Other Territory');
    expect(stateName('99'), isNull);
    expect(stateLabel('27'), '27 · Maharashtra');
  });

  group('GSTIN', () {
    test('valid formats', () {
      expect(isValidGstin('27AAPFU0939F1ZV'), isTrue);
      expect(isValidGstin('29AAACD1234E1Z5'), isTrue);
      expect(isValidGstin(' 27aapfu0939f1zv '), isTrue);
    });

    test('invalid formats', () {
      expect(isValidGstin(null), isFalse);
      expect(isValidGstin(''), isFalse);
      expect(isValidGstin('27AAPFU0939F1Z'), isFalse); // 14 chars
      expect(isValidGstin('27AAPFU0939F0ZV'), isFalse); // 13th char 0
      expect(isValidGstin('27AAPFU0939F1XV'), isFalse); // 14th must be Z
      expect(isValidGstin('2AAAPFU0939F1ZV'), isFalse);
    });

    test('derives the state code from the first two digits', () {
      expect(stateCodeFromGstin('27AAPFU0939F1ZV'), '27');
      expect(stateCodeFromGstin('07AAAAA0000A1Z5'), '07');
      expect(stateCodeFromGstin('99AAPFU0939F1ZV'), isNull);
      expect(stateCodeFromGstin('2'), isNull);
      expect(stateCodeFromGstin(null), isNull);
    });

    test('form validator', () {
      expect(validateGstin(''), isNull);
      expect(validateGstin('', required: true), 'GSTIN is required');
      expect(validateGstin('27AAPFU0939F1ZV'), isNull);
      expect(validateGstin('NOTAGSTIN'), 'Enter a valid 15-character GSTIN');
      expect(validateGstin('99AAPFU0939F1ZV'), 'Unknown state code in GSTIN');
    });
  });
}
