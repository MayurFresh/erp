import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/search_picker.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../items/item_model.dart';
import '../items/items_repository.dart';
import 'clinic_models.dart';
import 'clinic_repository.dart';

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
        showReasonDialog,
        showSuccess,
        today;

/// The chip on a queue row.
class ApptStatusChip extends StatelessWidget {
  const ApptStatusChip(this.status, {super.key});

  final ApptStatus status;

  @override
  Widget build(BuildContext context) => StatusChip(
    status.name,
    label: status.label,
    tone: switch (status) {
      ApptStatus.booked => StatusTone.neutral,
      ApptStatus.arrived => StatusTone.warning,
      ApptStatus.inConsultation => StatusTone.info,
      ApptStatus.done => StatusTone.success,
      ApptStatus.cancelled || ApptStatus.noShow => StatusTone.danger,
    },
  );
}

/// "Mon, 12 Nov" for the day bar.
String dayLabel(DateTime d) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${days[d.weekday - 1]}, ${d.day} ${months[d.month - 1]}';
}

/// A read-only field that opens the patient search.
class PatientPickerField extends ConsumerWidget {
  const PatientPickerField({
    super.key,
    required this.value,
    required this.onChanged,
    this.errorText,
    this.enabled = true,
  });

  final PatientBrief? value;
  final ValueChanged<PatientBrief> onChanged;
  final String? errorText;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PickerField(
    label: 'Patient',
    value: value == null ? null : '${value!.name}  (${value!.uhid})',
    errorText: errorText,
    enabled: enabled,
    validator: () => value == null ? 'Choose a patient' : null,
    onTap: () async {
      final picked = await showSearchPicker<PatientBrief>(
        context: context,
        title: 'Find patient',
        hintText: 'Name, phone or UHID',
        emptyMessage: 'No patient found.',
        search: (q) async =>
            (await ref.read(clinicRepositoryProvider).patients(q: q, limit: 30))
                .data,
        titleBuilder: (_, p) => Text(p.name),
        subtitleBuilder: (_, p) => Text('${p.line}  ${p.phone}'),
      );
      if (picked != null) onChanged(picked);
    },
  );
}

/// Dropdown of active doctors; [allowAll] adds an "All doctors" choice.
class DoctorDropdown extends ConsumerWidget {
  const DoctorDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    this.allowAll = false,
    this.errorText,
    this.enabled = true,
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final bool allowAll;
  final String? errorText;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doctors = ref.watch(clinicDoctorsProvider).value ?? const <Doctor>[];
    final active = [
      for (final d in doctors)
        if (d.isActive || d.id == value) d,
    ];
    return DropdownButtonFormField<String?>(
      key: ValueKey('doctor-$value-${active.length}'),
      initialValue: active.any((d) => d.id == value) ? value : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: allowAll ? 'Doctor' : 'Doctor',
        errorText: errorText,
      ),
      validator: (v) => !allowAll && v == null ? 'Choose a doctor' : null,
      items: [
        if (allowAll)
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('All doctors'),
          ),
        for (final d in active)
          DropdownMenuItem<String?>(
            value: d.id,
            child: Text(
              d.speciality == null ? d.name : '${d.name}  (${d.speciality})',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }
}

/// Picks an item (medicine or service) by search.
Future<Item?> pickItem(BuildContext context, WidgetRef ref) =>
    showSearchPicker<Item>(
      context: context,
      title: 'Choose item',
      hintText: 'Search name or SKU',
      emptyMessage: 'No item found.',
      search: (q) async =>
          (await ref
                  .read(itemsRepositoryProvider)
                  .list(q: q, activeOnly: true, limit: 30))
              .data,
      titleBuilder: (_, i) => Text(i.name),
      subtitleBuilder: (_, i) => Text(formatMoney(i.salePrice)),
    );

/// Shows who the server thinks is already registered and asks whether to go on.
Future<bool> confirmDuplicate(BuildContext context, ApiException e) async {
  final matches = asJsonList(e.details['matches']);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Possible duplicate'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.message),
            const SizedBox(height: 8),
            for (final m in matches)
              Text(
                '${asString(m['name'])}  ${asString(m['uhid'])}  ${asString(m['phone'])}',
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Go back'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Register anyway'),
        ),
      ],
    ),
  );
  return ok == true;
}

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

/// A [Pill] row for small facts such as blood group.
Widget pillRow(List<String> labels) => Wrap(
  spacing: 6,
  runSpacing: 4,
  children: [
    for (final l in labels)
      if (l.isNotEmpty) Pill(l),
  ],
);

/// Runs [call]; shows the error and returns false when it fails.
Future<bool> guarded(BuildContext context, Future<void> Function() call) async {
  try {
    await call();
    return true;
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
    return false;
  }
}
