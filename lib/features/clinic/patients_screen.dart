import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'clinic_dialogs.dart';
import 'clinic_models.dart';
import 'clinic_repository.dart';
import 'clinic_widgets.dart';

/// `/clinic/patients`: search by name, phone or UHID.
class PatientsScreen extends ConsumerStatefulWidget {
  const PatientsScreen({super.key});

  @override
  ConsumerState<PatientsScreen> createState() => _PatientsScreenState();
}

class _PatientsScreenState extends ConsumerState<PatientsScreen> {
  String _query = '';
  late final PagedController<PatientBrief> _paged = PagedController(
    (offset, limit) => ref
        .read(clinicRepositoryProvider)
        .patients(q: _query, offset: offset, limit: limit),
  );

  @override
  void initState() {
    super.initState();
    _paged.refresh();
  }

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    final saved = await showFormDialog<Patient>(
      context: context,
      builder: (_) => PatientFormDialog(
        canEditNotes: ref.read(permissionsProvider).can(Perm.clinicConsult),
      ),
    );
    if (saved == null || !mounted) return;
    ref.bumpClinic(const [ClinicKind.patients], money: true);
    showSuccess(context, '${saved.name} registered, ${saved.brief.uhid}');
    context.go('/clinic/patients/${saved.id}');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      clinicRevisionProvider(ClinicKind.patients),
      (_, _) => _paged.refresh(),
    );
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final desk = ref.watch(permissionsProvider).canAny(const [
      Perm.clinicFrontDesk,
      Perm.clinicManage,
    ]);
    return CGate(
      anyOf: const [Perm.clinicView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Patients',
            actions: [
              if (desk)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: _register,
                  icon: const Icon(Icons.person_add_alt_outlined),
                  label: const Text('Register patient'),
                ),
            ],
          ),
          FilterBar(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360, minWidth: 220),
                child: SearchField(
                  hintText: 'Name, phone or UHID',
                  onChanged: (q) {
                    _query = q;
                    _paged.refresh();
                  },
                ),
              ),
            ],
          ),
          Expanded(
            child: AdaptiveDataList<PatientBrief>(
              controller: _paged,
              emptyMessage: 'No patients found.',
              emptyIcon: Icons.groups_outlined,
              onTap: (p) => context.go('/clinic/patients/${p.id}'),
              columns: [
                TableColumnSpec('UHID', (p) => Text(p.uhid)),
                TableColumnSpec('Name', (p) => Text(p.name), maxWidth: 260),
                TableColumnSpec(
                  'Age',
                  (p) => Text(ageLabel(p.ageYears)),
                  numeric: true,
                ),
                TableColumnSpec('Sex', (p) => Text(sexLabel(p.sex))),
                TableColumnSpec('Phone', (p) => Text(p.phone)),
              ],
              cardBuilder: (context, p) => ListCard(
                title: Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${p.line}  |  ${p.phone}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/clinic/patients/${p.id}'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `/clinic/patients/:id`: details, upcoming appointments and history.
class PatientScreen extends ConsumerWidget {
  const PatientScreen({super.key, required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CGate(
    anyOf: const [Perm.clinicView],
    child: AsyncValueView<PatientHistory>(
      value: ref.watch(clinicPatientProvider(patientId)),
      onRetry: () => ref.invalidate(clinicPatientProvider(patientId)),
      data: (h) => _PatientBody(history: h),
    ),
  );
}

class _PatientBody extends ConsumerWidget {
  const _PatientBody({required this.history});

  final PatientHistory history;

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final saved = await showFormDialog<Patient>(
      context: context,
      builder: (_) => PatientFormDialog(
        patient: history.patient,
        canEditNotes: ref.read(permissionsProvider).can(Perm.clinicConsult),
      ),
    );
    if (saved != null) ref.bumpClinic(const [ClinicKind.patients]);
  }

  Future<void> _book(
    BuildContext context,
    WidgetRef ref, {
    bool walkIn = false,
  }) async {
    final appt = await showFormDialog<Appointment>(
      context: context,
      builder: (_) =>
          BookDialog(patient: history.patient.brief, walkIn: walkIn),
    );
    if (appt != null) {
      ref.bumpClinic(const [ClinicKind.appointments]);
      if (context.mounted) {
        showSuccess(
          context,
          appt.startTime == null
              ? 'Token ${appt.tokenNo}'
              : 'Booked at ${appt.startTime}',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = history.patient;
    final theme = Theme.of(context);
    final perms = ref.watch(permissionsProvider);
    final desk = perms.canAny(const [Perm.clinicFrontDesk, Perm.clinicManage]);
    final consult = perms.can(Perm.clinicConsult);
    final upcoming = [
      for (final a in history.appointments)
        if (a.status.isOpen) a,
    ];
    return FormPage(
      maxWidth: 900,
      children: [
        Text(p.name, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('${p.brief.line}   ${p.brief.phone}'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (desk)
              FilledButton.icon(
                onPressed: () => _book(context, ref),
                icon: const Icon(Icons.event_outlined),
                label: const Text('Book appointment'),
              ),
            if (desk)
              OutlinedButton.icon(
                onPressed: () => _book(context, ref, walkIn: true),
                icon: const Icon(Icons.confirmation_number_outlined),
                label: const Text('Walk-in token'),
              ),
            if (desk)
              OutlinedButton.icon(
                onPressed: () => _edit(context, ref),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Details',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Fact('Date of birth', p.dob == null ? null : formatDate(p.dob)),
              Fact('Blood group', p.bloodGroup),
              Fact('Address', p.address),
              Fact(
                'Emergency contact',
                [
                  p.emergencyName,
                  p.emergencyPhone,
                ].whereType<String>().join('  '),
              ),
              if (p.allergies != null && p.allergies!.isNotEmpty)
                Text(
                  'Allergies: ${p.allergies}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (p.canSeeNotes) Fact('Notes', p.notes),
            ],
          ),
        ),
        if (upcoming.isNotEmpty) ...[
          const SizedBox(height: 12),
          SectionCard(
            title: 'Appointments',
            child: Column(
              children: [
                for (final a in upcoming)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${formatDate(a.date)}  ${a.when}'),
                    subtitle: Text(a.doctorName),
                    trailing: ApptStatusChip(a.status),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        SectionCard(
          title: 'Visits and bills',
          child: history.visits.isEmpty
              ? const Text('No visits yet.')
              : Column(
                  children: [
                    for (final v in history.visits)
                      ListTile(
                        key: ValueKey('visit-${v.id}'),
                        contentPadding: EdgeInsets.zero,
                        onTap: consult
                            ? () => context.go('/clinic/visits/${v.id}')
                            : null,
                        title: Text('${formatDate(v.date)}  ${v.doctorName}'),
                        subtitle: Text(
                          [
                            if (v.diagnosis != null && v.diagnosis!.isNotEmpty)
                              v.diagnosis!,
                            if (v.rxCount != null && v.rxCount! > 0)
                              '${v.rxCount} medicines',
                            if (v.feeKind == 'follow_up') 'Follow-up',
                          ].join('  |  '),
                        ),
                        trailing: v.invoice == null
                            ? const Text('Not billed')
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(v.invoice!.number),
                                  Text(
                                    v.invoice!.cancelled
                                        ? 'Cancelled'
                                        : v.invoice!.due > 0.004
                                        ? 'Due ${formatMoney(v.invoice!.due)}'
                                        : 'Paid ${formatMoney(v.invoice!.total)}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
