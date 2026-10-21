/// GST state codes (the first two digits of a GSTIN).
class IndiaState {
  const IndiaState(this.code, this.name);

  final String code;
  final String name;

  String get label => '$code · $name';
}

const List<IndiaState> indiaStates = [
  IndiaState('01', 'Jammu & Kashmir'),
  IndiaState('02', 'Himachal Pradesh'),
  IndiaState('03', 'Punjab'),
  IndiaState('04', 'Chandigarh'),
  IndiaState('05', 'Uttarakhand'),
  IndiaState('06', 'Haryana'),
  IndiaState('07', 'Delhi'),
  IndiaState('08', 'Rajasthan'),
  IndiaState('09', 'Uttar Pradesh'),
  IndiaState('10', 'Bihar'),
  IndiaState('11', 'Sikkim'),
  IndiaState('12', 'Arunachal Pradesh'),
  IndiaState('13', 'Nagaland'),
  IndiaState('14', 'Manipur'),
  IndiaState('15', 'Mizoram'),
  IndiaState('16', 'Tripura'),
  IndiaState('17', 'Meghalaya'),
  IndiaState('18', 'Assam'),
  IndiaState('19', 'West Bengal'),
  IndiaState('20', 'Jharkhand'),
  IndiaState('21', 'Odisha'),
  IndiaState('22', 'Chhattisgarh'),
  IndiaState('23', 'Madhya Pradesh'),
  IndiaState('24', 'Gujarat'),
  IndiaState('25', 'Daman & Diu (old code)'),
  IndiaState('26', 'Dadra & Nagar Haveli and Daman & Diu'),
  IndiaState('27', 'Maharashtra'),
  IndiaState('28', 'Andhra Pradesh (old code)'),
  IndiaState('29', 'Karnataka'),
  IndiaState('30', 'Goa'),
  IndiaState('31', 'Lakshadweep'),
  IndiaState('32', 'Kerala'),
  IndiaState('33', 'Tamil Nadu'),
  IndiaState('34', 'Puducherry'),
  IndiaState('35', 'Andaman & Nicobar Islands'),
  IndiaState('36', 'Telangana'),
  IndiaState('37', 'Andhra Pradesh'),
  IndiaState('38', 'Ladakh'),
  IndiaState('97', 'Other Territory'),
];

final Map<String, IndiaState> _byCode = {
  for (final state in indiaStates) state.code: state,
};

final RegExp gstinPattern = RegExp(
  r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$',
);

bool isValidStateCode(String? code) =>
    code != null && _byCode.containsKey(code);

String? stateName(String? code) => code == null ? null : _byCode[code]?.name;

/// `27 · Maharashtra`, or the bare code if unknown.
String stateLabel(String? code) =>
    code == null ? '' : (_byCode[code]?.label ?? code);

/// Format check only (the checksum digit is not verified).
bool isValidGstin(String? gstin) =>
    gstin != null && gstinPattern.hasMatch(gstin.trim().toUpperCase());

/// State code from a GSTIN's first two digits, if it is a known state.
String? stateCodeFromGstin(String? gstin) {
  final value = gstin?.trim();
  if (value == null || value.length < 2) return null;
  final code = value.substring(0, 2);
  return isValidStateCode(code) ? code : null;
}

/// Form validator for an optional GSTIN field.
String? validateGstin(String? value, {bool required = false}) {
  final text = value?.trim().toUpperCase() ?? '';
  if (text.isEmpty) return required ? 'GSTIN is required' : null;
  if (!isValidGstin(text)) return 'Enter a valid 15-character GSTIN';
  if (stateCodeFromGstin(text) == null) return 'Unknown state code in GSTIN';
  return null;
}
