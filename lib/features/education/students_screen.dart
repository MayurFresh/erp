import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../auth/session.dart';
import 'education_models.dart';
import 'education_repository.dart';
import 'education_widgets.dart';
import 'student_form_dialog.dart';

/// `/education/students`: search by name, admission number or parent phone.
class StudentsScreen extends ConsumerStatefulWidget {
  const StudentsScreen({super.key});

  @override
  ConsumerState<StudentsScreen> createState() => _StudentsScreenState();
}

class _StudentsScreenState extends ConsumerState<StudentsScreen> {
  String _query = '';
  String? _classId;
  String _status = 'active';
  late final PagedController<StudentBrief> _paged = PagedController(
    (offset, limit) => ref
        .read(eduRepositoryProvider)
        .students(
          q: _query,
          classId: _classId,
          status: _status,
          offset: offset,
          limit: limit,
        ),
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

  Future<void> _admit() async {
    final saved = await showFormDialog<Student>(
      context: context,
      builder: (_) => StudentFormDialog(classId: _classId),
    );
    if (saved == null || !mounted) return;
    ref.bumpEdu(const [EduKind.students], money: true);
    showSuccess(context, '${saved.name} admitted, ${saved.brief.admissionNo}');
    context.go('/education/students/${saved.id}');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      eduRevisionProvider(EduKind.students),
      (_, _) => _paged.refresh(),
    );
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final admit = ref.watch(permissionsProvider).canAny(const [
      Perm.educationAdmissions,
      Perm.educationManage,
    ]);
    return CGate(
      anyOf: const [Perm.educationView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Students',
            actions: [
              if (admit)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: _admit,
                  icon: const Icon(Icons.person_add_alt_outlined),
                  label: const Text('Admit student'),
                ),
            ],
          ),
          FilterBar(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360, minWidth: 220),
                child: SearchField(
                  hintText: 'Name, admission no. or parent phone',
                  onChanged: (q) {
                    _query = q;
                    _paged.refresh();
                  },
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240, minWidth: 180),
                child: ClassDropdown(
                  value: _classId,
                  allowAll: true,
                  onChanged: (v) {
                    setState(() => _classId = v);
                    _paged.refresh();
                  },
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180, minWidth: 140),
                child: DropdownButtonFormField<String>(
                  initialValue: _status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: const [
                    DropdownMenuItem(value: 'active', child: Text('Active')),
                    DropdownMenuItem(value: 'left', child: Text('Left')),
                    DropdownMenuItem(
                      value: 'passed_out',
                      child: Text('Passed out'),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() => _status = v ?? 'active');
                    _paged.refresh();
                  },
                ),
              ),
            ],
          ),
          Expanded(
            child: AdaptiveDataList<StudentBrief>(
              controller: _paged,
              emptyMessage: 'No students found.',
              emptyIcon: Icons.groups_outlined,
              onTap: (s) => context.go('/education/students/${s.id}'),
              columns: [
                TableColumnSpec('Admission no.', (s) => Text(s.admissionNo)),
                TableColumnSpec('Name', (s) => Text(s.name), maxWidth: 260),
                TableColumnSpec('Class', (s) => Text(s.className ?? '')),
                TableColumnSpec('Roll', (s) => Text(s.rollNo ?? '')),
                TableColumnSpec('Parent', (s) => Text(s.guardianName)),
                TableColumnSpec('Phone', (s) => Text(s.guardianPhone)),
              ],
              cardBuilder: (context, s) => ListCard(
                title: Text(
                  s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${s.line}\n${s.guardianName}  ${s.guardianPhone}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/education/students/${s.id}'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
