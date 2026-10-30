import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../locations/locations_repository.dart';
import 'report_catalog.dart';
import 'report_widgets.dart';

/// `/reports` (registers, GST, ageing, valuation — plus links to the
/// financial statements when allowed) or `/financials` (the statements).
class ReportsHubScreen extends ConsumerWidget {
  const ReportsHubScreen({super.key, this.financials = false});

  final bool financials;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final reports = visibleReports(
      perms,
    ).where((r) => !financials || r.isFinancialStatement).toList();
    final groups = <String, List<ReportInfo>>{};
    for (final r in reports) {
      groups.putIfAbsent(r.group, () => []).add(r);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: financials ? 'Financial statements' : 'Reports',
          subtitle: financials
              ? 'Trial balance, profit & loss and balance sheet'
              : 'Registers, GST, outstanding and stock',
        ),
        Expanded(
          child: reports.isEmpty
              ? const EmptyView(
                  icon: Icons.lock_outline,
                  message: 'No reports are enabled for your role.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    for (final MapEntry(key: group, value: list)
                        in groups.entries) ...[
                      ReportSectionTitle(group),
                      _CardGrid(reports: list),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.reports});

  final List<ReportInfo> reports;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 12.0;
      final columns = (constraints.maxWidth / 320).floor().clamp(1, 4);
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final r in reports)
            SizedBox(
              width: width,
              child: Card(
                margin: EdgeInsets.zero,
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  leading: CircleAvatar(child: Icon(r.icon)),
                  title: Text(r.title),
                  subtitle: Text(r.description, maxLines: 2),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go(r.path),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// Location filter for registers and valuation; hidden without
/// `locations.view`.
class LocationFilter extends ConsumerWidget {
  const LocationFilter({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(permissionsProvider).can(Perm.locationsView)) {
      return const SizedBox.shrink();
    }
    final locations = ref.watch(locationsLookupProvider).value;
    if (locations == null || locations.length < 2) {
      return const SizedBox.shrink();
    }
    return FilterDropdown<String>(
      label: 'Location',
      value: value,
      anyLabel: 'All locations',
      width: 240,
      icon: Icons.location_on_outlined,
      options: {for (final l in locations) l.id: l.displayName},
      onChanged: onChanged,
    );
  }
}

/// Name of [id] among the user's locations, for export subtitles.
String? locationName(WidgetRef ref, String? id) {
  if (id == null) return null;
  for (final l in ref.read(locationsLookupProvider).value ?? const []) {
    if (l.id == id) return l.name;
  }
  return null;
}
