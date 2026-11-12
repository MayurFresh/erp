import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:printing/printing.dart';

import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_fonts.dart';
import '../../core/providers.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/search_picker.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import 'education_models.dart';
import 'education_repository.dart';
import 'receipt_pdf.dart';

export '../construction/common/c_widgets.dart'
    show
        BottomBarLayout,
        CGate,
        DateField,
        bigButton,
        bigOutlinedButton,
        confirm,
        isPhone,
        parseApiDate,
        showSuccess,
        today;

/// A label and value on one line, wrapped for narrow screens.
class Fact extends StatelessWidget {
  const Fact(this.label, this.value, {super.key});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    if (value == null || value!.trim().isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label  ',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}

const modeItems = [
  DropdownMenuItem(value: 'cash', child: Text('Cash')),
  DropdownMenuItem(value: 'upi', child: Text('UPI')),
  DropdownMenuItem(value: 'cheque', child: Text('Cheque')),
  DropdownMenuItem(value: 'bank', child: Text('Bank transfer')),
  DropdownMenuItem(value: 'card', child: Text('Card')),
];

/// "2026-27" for the month a date falls in, e.g. "Nov 2026" for a heading.
String monthLabel(String month) {
  const names = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final y = month.substring(0, 4);
  final m = int.parse(month.substring(5, 7));
  return '${names[m - 1]} $y';
}

/// Dropdown of classes or batches; [allowAll] adds an "All classes" choice.
class ClassDropdown extends ConsumerWidget {
  const ClassDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    this.allowAll = false,
    this.label = 'Class or batch',
    this.errorText,
    this.enabled = true,
    this.exclude,
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final bool allowAll;
  final String label;
  final String? errorText;
  final bool enabled;
  final String? exclude;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final classes = ref.watch(eduClassesProvider).value ?? const <EduClass>[];
    final shown = [
      for (final c in classes)
        if ((c.isActive || c.id == value) && c.id != exclude) c,
    ];
    return DropdownButtonFormField<String?>(
      key: ValueKey('class-$value-${shown.length}'),
      initialValue: shown.any((c) => c.id == value) ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, errorText: errorText),
      validator: (v) => !allowAll && v == null ? 'Choose one' : null,
      items: [
        if (allowAll)
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('All classes'),
          ),
        for (final c in shown)
          DropdownMenuItem<String?>(
            value: c.id,
            child: Text(c.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }
}

/// A read-only field that opens the student search.
class StudentPickerField extends ConsumerWidget {
  const StudentPickerField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'Student',
  });

  final StudentBrief? value;
  final ValueChanged<StudentBrief> onChanged;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PickerField(
    label: label,
    value: value == null ? null : '${value!.name}  (${value!.admissionNo})',
    validator: () => value == null ? 'Choose a student' : null,
    onTap: () async {
      final picked = await showSearchPicker<StudentBrief>(
        context: context,
        title: 'Find student',
        hintText: 'Name, admission no. or parent phone',
        emptyMessage: 'No student found.',
        search: (q) async =>
            (await ref.read(eduRepositoryProvider).students(q: q, limit: 30))
                .data,
        titleBuilder: (_, s) => Text(s.name),
        subtitleBuilder: (_, s) =>
            Text('${s.line}  ${s.guardianName}  ${s.guardianPhone}'),
      );
      if (picked != null) onChanged(picked);
    },
  );
}

/// Loads the receipt and opens the print dialog (A5).
Future<void> printFeeReceipt(
  BuildContext context,
  WidgetRef ref,
  String paymentId,
) async {
  try {
    final data = await ref.read(eduRepositoryProvider).receipt(paymentId);
    Company? company;
    try {
      company = await ref.read(companyRepositoryProvider).get();
    } catch (_) {
      company = ref.read(sessionProvider).value?.company;
    }
    final brand = company == null
        ? null
        : await loadPdfBrand(ref.read(apiClientProvider), company);
    final bytes = await buildFeeReceiptPdf(
      data,
      brand: brand,
      theme: await pdfTheme(),
    );
    await Printing.layoutPdf(
      onLayout: (_) async => Uint8List.fromList(bytes),
      name: receiptFileName(data),
      format: PdfPageFormat.a5,
    );
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
  }
}

/// Text such as "Rs 4,000 due" for lists.
String dueLine(double due, double overdue) => overdue > 0.004
    ? '${formatMoney(overdue)} overdue'
    : due > 0.004
    ? '${formatMoney(due)} due'
    : 'Nothing due';
