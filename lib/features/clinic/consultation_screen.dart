import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:printing/printing.dart';

import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_fonts.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import 'bill_dialog.dart';
import 'clinic_models.dart';
import 'clinic_repository.dart';
import 'clinic_widgets.dart';
import 'rx_pdf.dart';

class _RxRow {
  _RxRow({
    this.itemId,
    String medicine = '',
    String? dose,
    String? frequency,
    int? days,
    String? instructions,
  }) : medicine = TextEditingController(text: medicine),
       dose = TextEditingController(text: dose),
       frequency = TextEditingController(text: frequency),
       days = TextEditingController(text: days?.toString()),
       instructions = TextEditingController(text: instructions);

  String? itemId;
  final TextEditingController medicine;
  final TextEditingController dose;
  final TextEditingController frequency;
  final TextEditingController days;
  final TextEditingController instructions;

  void dispose() {
    for (final c in [medicine, dose, frequency, days, instructions]) {
      c.dispose();
    }
  }
}

/// `/clinic/visits/:id`: the consultation form for the doctor; for front
/// desk only the visit header and the Bill action.
class ConsultationScreen extends ConsumerWidget {
  const ConsultationScreen({super.key, required this.visitId});

  final String visitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CGate(
    anyOf: const [Perm.clinicView],
    child: AsyncValueView<Visit>(
      value: ref.watch(clinicVisitProvider(visitId)),
      onRetry: () => ref.invalidate(clinicVisitProvider(visitId)),
      data: (v) => v.clinical
          ? _ConsultationForm(
              key: ValueKey('${v.id}-${v.updatedAt}-form'),
              visit: v,
            )
          : _HeaderOnly(visit: v),
    ),
  );
}

class _HeaderOnly extends ConsumerWidget {
  const _HeaderOnly({required this.visit});

  final Visit visit;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FormPage(
    children: [
      Text(
        visit.patient.name,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 8),
      SectionCard(
        title: 'Visit',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Fact('Date', formatDate(visit.date)),
            Fact('Doctor', visit.doctorName),
            Fact(
              'Status',
              visit.closed ? 'Consultation finished' : 'With the doctor',
            ),
            Fact('Bill', visit.billed ? visit.invoice!.number : 'Not billed'),
            const SizedBox(height: 8),
            const Text('Clinical notes are only shown to clinical staff.'),
            const SizedBox(height: 12),
            if (!visit.billed &&
                ref.watch(permissionsProvider).can(Perm.invoicesCreate))
              FilledButton.icon(
                style: bigButton,
                onPressed: () async {
                  final ok = await showFormDialog<bool>(
                    context: context,
                    builder: (_) => BillDialog(visitId: visit.id),
                  );
                  if (ok == true) {
                    ref.bumpClinic(const [
                      ClinicKind.visits,
                      ClinicKind.appointments,
                    ], money: true);
                  }
                },
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('Bill the visit'),
              ),
          ],
        ),
      ),
    ],
  );
}

class _ConsultationForm extends ConsumerStatefulWidget {
  const _ConsultationForm({super.key, required this.visit});

  final Visit visit;

  @override
  ConsumerState<_ConsultationForm> createState() => _ConsultationFormState();
}

class _ConsultationFormState extends ConsumerState<_ConsultationForm>
    with ServerFieldErrors, DirtyTracking<_ConsultationForm> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _v;
  late final _complaints = TextEditingController(text: widget.visit.complaints);
  late final _findings = TextEditingController(text: widget.visit.findings);
  late final _diagnosis = TextEditingController(text: widget.visit.diagnosis);
  late final _tests = TextEditingController(text: widget.visit.testsAdvised);
  late final _advice = TextEditingController(text: widget.visit.advice);
  late DateTime? _followup = parseApiDate(widget.visit.followupDate);
  late final List<_RxRow> _rx = [
    for (final r in widget.visit.rx)
      _RxRow(
        itemId: r.itemId,
        medicine: r.medicine,
        dose: r.dose,
        frequency: r.frequency,
        days: r.days,
        instructions: r.instructions,
      ),
  ];
  bool _saving = false;
  late String? _updatedAt = widget.visit.updatedAt;

  @override
  void initState() {
    super.initState();
    final v = widget.visit.vitals;
    String? t(double? x) => x == null ? null : formatPlain(x);
    _v = {
      'bpSys': TextEditingController(text: t(v.bpSys)),
      'bpDia': TextEditingController(text: t(v.bpDia)),
      'pulse': TextEditingController(text: t(v.pulse)),
      'tempC': TextEditingController(text: t(v.tempC)),
      'spo2': TextEditingController(text: t(v.spo2)),
      'weightKg': TextEditingController(text: t(v.weightKg)),
      'heightCm': TextEditingController(text: t(v.heightCm)),
    };
  }

  @override
  void dispose() {
    for (final c in [
      ..._v.values,
      _complaints,
      _findings,
      _diagnosis,
      _tests,
      _advice,
    ]) {
      c.dispose();
    }
    for (final r in _rx) {
      r.dispose();
    }
    super.dispose();
  }

  Map<String, Object?> _body() => {
    'vitals': {for (final e in _v.entries) e.key: parseNumber(e.value.text)},
    'complaints': trimmedOrNull(_complaints.text),
    'findings': trimmedOrNull(_findings.text),
    'diagnosis': trimmedOrNull(_diagnosis.text),
    'testsAdvised': trimmedOrNull(_tests.text),
    'advice': trimmedOrNull(_advice.text),
    'followupDate': _followup == null ? null : apiDate(_followup!),
    'rx': [
      for (final r in _rx)
        if (r.medicine.text.trim().isNotEmpty)
          {
            'itemId': r.itemId,
            'medicine': r.medicine.text.trim(),
            'dose': trimmedOrNull(r.dose.text),
            'frequency': trimmedOrNull(r.frequency.text),
            'days': int.tryParse(r.days.text.trim()),
            'instructions': trimmedOrNull(r.instructions.text),
          },
    ],
    'expectedUpdatedAt': _updatedAt,
  };

  /// Saves; returns false when it failed (the error is shown).
  Future<bool> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return false;
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(clinicRepositoryProvider)
          .saveVisit(widget.visit.id, _body());
      _updatedAt = saved.updatedAt;
      markSaved();
      return true;
    } catch (e) {
      if (mounted) {
        showSubmitError(
          e,
          onReload: () => ref.invalidate(clinicVisitProvider(widget.visit.id)),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveOnly() async {
    if (await _save() && mounted) showSuccess(context, 'Consultation saved');
  }

  Future<void> _print() async {
    if (!await _save() || !mounted) return;
    setState(() => _saving = true);
    try {
      final data = await ref
          .read(clinicRepositoryProvider)
          .prescription(widget.visit.id);
      Company? company;
      try {
        company = await ref.read(companyRepositoryProvider).get();
      } catch (_) {
        company = ref.read(sessionProvider).value?.company;
      }
      final brand = company == null
          ? null
          : await loadPdfBrand(ref.read(apiClientProvider), company);
      final bytes = await buildPrescriptionPdf(
        data,
        brand: brand,
        theme: await pdfTheme(),
      );
      await Printing.layoutPdf(
        onLayout: (_) async => Uint8List.fromList(bytes),
        name: rxFileName(data),
        format: PdfPageFormat.a5,
      );
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _bill() async {
    if (!await _save() || !mounted) return;
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (_) => BillDialog(visitId: widget.visit.id),
    );
    if (ok == true) {
      ref.bumpClinic(const [
        ClinicKind.visits,
        ClinicKind.appointments,
      ], money: true);
    }
  }

  Future<void> _complete() async {
    if (!await _save() || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref.read(clinicRepositoryProvider).complete(widget.visit.id);
      ref.bumpClinic(const [ClinicKind.visits, ClinicKind.appointments]);
      if (mounted) {
        showSuccess(context, 'Consultation finished');
        context.go('/clinic/doctor');
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addFromItem() async {
    final item = await pickItem(context, ref);
    if (item == null) return;
    setState(() => _rx.add(_RxRow(itemId: item.id, medicine: item.name)));
    markDirty();
  }

  Widget _vital(String key, String label, {String? suffix, int decimals = 0}) =>
      TextField(
        controller: _v[key],
        keyboardType: decimalKeyboard,
        inputFormatters: [decimalInput(decimals: decimals == 0 ? 2 : decimals)],
        decoration: InputDecoration(labelText: label, suffixText: suffix),
      );

  @override
  Widget build(BuildContext context) {
    final v = widget.visit;
    final theme = Theme.of(context);
    final canBill = ref.watch(permissionsProvider).can(Perm.invoicesCreate);
    return track(
      BottomBarLayout(
        maxWidth: 900,
        bar: Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              style: bigOutlinedButton,
              onPressed: _saving ? null : () => leave('/clinic/doctor'),
              child: const Text('Back'),
            ),
            if (canBill)
              OutlinedButton(
                style: bigOutlinedButton,
                onPressed: _saving ? null : _bill,
                child: Text(v.billed ? 'Billed ${v.invoice!.number}' : 'Bill'),
              ),
            OutlinedButton(
              style: bigOutlinedButton,
              onPressed: _saving ? null : _print,
              child: const Text('Save and print'),
            ),
            if (!v.closed)
              OutlinedButton(
                style: bigOutlinedButton,
                onPressed: _saving ? null : _complete,
                child: const Text('Finish'),
              ),
            BusyButton(
              busy: _saving,
              onPressed: _saving ? null : _saveOnly,
              label: 'Save',
            ),
          ],
        ),
        child: Form(
          key: _formKey,
          onChanged: markDirty,
          child: FormPage(
            maxWidth: 900,
            children: [
              Text(v.patient.name, style: theme.textTheme.headlineSmall),
              Text(
                '${v.patient.line}   ${v.patient.phone}   ${formatDate(v.date)}',
                style: theme.textTheme.bodyMedium,
              ),
              if (v.allergies != null && v.allergies!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Allergies: ${v.allergies}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'Vitals',
                child: FormRow(
                  minCellWidth: 120,
                  maxColumns: 4,
                  children: [
                    _vital('bpSys', 'BP upper', suffix: 'mmHg'),
                    _vital('bpDia', 'BP lower', suffix: 'mmHg'),
                    _vital('pulse', 'Pulse', suffix: '/min'),
                    _vital('tempC', 'Temperature', suffix: 'C', decimals: 1),
                    _vital('spo2', 'SpO2', suffix: '%'),
                    _vital('weightKg', 'Weight', suffix: 'kg', decimals: 1),
                    _vital('heightCm', 'Height', suffix: 'cm', decimals: 1),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'Notes',
                child: Column(
                  children: [
                    TextFormField(
                      controller: _complaints,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Complaints',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _findings,
                      maxLines: 2,
                      decoration: const InputDecoration(labelText: 'Findings'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _diagnosis,
                      decoration: InputDecoration(
                        labelText: 'Diagnosis',
                        errorText: serverError('diagnosis'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'Prescription',
                trailing: TextButton.icon(
                  onPressed: _saving
                      ? null
                      : () => setState(() => _rx.add(_RxRow())),
                  icon: const Icon(Icons.add),
                  label: const Text('Add line'),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_rx.isEmpty) const Text('No medicines yet.'),
                    for (final (i, r) in _rx.indexed)
                      Padding(
                        key: ObjectKey(r),
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: r.medicine,
                                    decoration: InputDecoration(
                                      labelText: 'Medicine ${i + 1}',
                                      helperText: r.itemId == null
                                          ? null
                                          : 'From the item list',
                                    ),
                                    onChanged: (_) => r.itemId = null,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Remove medicine ${i + 1}',
                                  onPressed: _saving
                                      ? null
                                      : () {
                                          setState(
                                            () => _rx.removeAt(i).dispose(),
                                          );
                                          markDirty();
                                        },
                                  icon: const Icon(Icons.close),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            FormRow(
                              minCellWidth: 120,
                              maxColumns: 4,
                              children: [
                                TextFormField(
                                  controller: r.dose,
                                  decoration: const InputDecoration(
                                    labelText: 'Dose',
                                  ),
                                ),
                                TextFormField(
                                  controller: r.frequency,
                                  decoration: const InputDecoration(
                                    labelText: 'Frequency',
                                  ),
                                ),
                                TextFormField(
                                  controller: r.days,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Days',
                                  ),
                                  validator: (t) {
                                    final s = (t ?? '').trim();
                                    if (s.isEmpty) return null;
                                    final n = int.tryParse(s);
                                    return n == null || n < 1
                                        ? 'Enter days'
                                        : null;
                                  },
                                ),
                                TextFormField(
                                  controller: r.instructions,
                                  decoration: const InputDecoration(
                                    labelText: 'Instructions',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _saving ? null : _addFromItem,
                        icon: const Icon(Icons.search),
                        label: const Text('Pick medicine from items'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'Advice and follow-up',
                child: Column(
                  children: [
                    TextFormField(
                      controller: _tests,
                      decoration: const InputDecoration(
                        labelText: 'Tests advised',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _advice,
                      maxLines: 3,
                      decoration: const InputDecoration(labelText: 'Advice'),
                    ),
                    const SizedBox(height: 12),
                    DateField(
                      label: 'Follow-up date',
                      value: _followup,
                      firstDate: parseApiDate(v.date) ?? today(),
                      lastDate: today().add(const Duration(days: 730)),
                      onChanged: (d) {
                        setState(() => _followup = d);
                        markDirty();
                      },
                      onCleared: () {
                        setState(() => _followup = null);
                        markDirty();
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
