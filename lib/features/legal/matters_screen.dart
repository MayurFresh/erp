import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../construction/common/c_widgets.dart';
import 'legal_dialogs.dart';
import 'legal_models.dart';
import 'legal_repository.dart';
import 'legal_widgets.dart';

/// `/legal/matters`: filter by status, advocate and court.
class MattersScreen extends ConsumerStatefulWidget {
  const MattersScreen({super.key});

  @override
  ConsumerState<MattersScreen> createState() => _MattersScreenState();
}

class _MattersScreenState extends ConsumerState<MattersScreen> {
  String _query = '';
  String? _status = 'open';
  String? _advocate;
  String _court = '';
  late final PagedController<Matter> _paged = PagedController(
    (offset, limit) => ref
        .read(legalRepositoryProvider)
        .matters(
          q: _query,
          status: _status,
          advocateId: _advocate,
          court: _court.isEmpty ? null : _court,
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

  Future<void> _create() async {
    final saved = await showFormDialog<Matter>(
      context: context,
      builder: (_) => MatterFormDialog(canManage: ref.legalCanManage),
    );
    if (saved == null || !mounted) return;
    ref.bumpLegal();
    context.go('/legal/matters/${saved.id}');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(legalRevisionProvider, (_, _) => _paged.refresh());
    final staff = ref.watch(legalStaffProvider).value ?? const <Person>[];
    return CGate(
      anyOf: const [Perm.legalView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Matters',
            actions: [
              if (ref.legalCanWork)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: _create,
                  icon: const Icon(Icons.add),
                  label: const Text('New matter'),
                ),
            ],
          ),
          FilterBar(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320, minWidth: 200),
                child: SearchField(
                  hintText: 'Title, client, case number',
                  onChanged: (q) {
                    _query = q;
                    _paged.refresh();
                  },
                ),
              ),
              FilterDropdown<String>(
                label: 'Status',
                value: _status,
                options: matterStatuses,
                width: 150,
                onChanged: (v) {
                  _status = v;
                  _paged.refresh();
                  setState(() {});
                },
              ),
              if (staff.length > 1)
                FilterDropdown<String>(
                  label: 'Advocate',
                  value: _advocate,
                  options: {for (final p in staff) p.id: p.name},
                  width: 180,
                  onChanged: (v) {
                    _advocate = v;
                    _paged.refresh();
                    setState(() {});
                  },
                ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200, minWidth: 150),
                child: SearchField(
                  hintText: 'Court',
                  onChanged: (q) {
                    _court = q;
                    _paged.refresh();
                  },
                ),
              ),
            ],
          ),
          Expanded(
            child: AdaptiveDataList<Matter>(
              controller: _paged,
              emptyMessage: 'No matters found.',
              emptyIcon: Icons.gavel_outlined,
              onTap: (m) => context.go('/legal/matters/${m.id}'),
              columns: [
                TableColumnSpec('Matter', (m) => Text(m.matterNo)),
                TableColumnSpec('Title', (m) => Text(m.title), maxWidth: 280),
                TableColumnSpec(
                  'Client',
                  (m) => Text(m.clientName),
                  maxWidth: 200,
                ),
                TableColumnSpec(
                  'Court',
                  (m) => Text(m.court ?? ''),
                  maxWidth: 200,
                ),
                TableColumnSpec('Advocate', (m) => Text(m.advocateName)),
                TableColumnSpec(
                  'Next date',
                  (m) => Text(
                    m.nextHearingDate == null
                        ? 'None'
                        : formatDate(m.nextHearingDate),
                  ),
                ),
                TableColumnSpec('Status', (m) => MatterStatusChip(m.status)),
              ],
              cardBuilder: (context, m) => ListCard(
                title: Text(
                  m.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    m.matterNo,
                    m.clientName,
                    m.nextHearingDate == null
                        ? 'No next date'
                        : 'Next ${formatDate(m.nextHearingDate)}',
                  ].join('  |  '),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/legal/matters/${m.id}'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
