import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../auth/session.dart';
import '../locations/location_model.dart';
import '../locations/locations_repository.dart';
import 'user_models.dart';
import 'users_repository.dart';

class UsersScreen extends ConsumerStatefulWidget {
  const UsersScreen({super.key});

  @override
  ConsumerState<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends ConsumerState<UsersScreen> {
  String _query = '';
  late final PagedController<UserRow> _paged = PagedController(
    (offset, limit) => ref
        .read(usersRepositoryProvider)
        .users(q: _query, offset: offset, limit: limit),
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

  @override
  Widget build(BuildContext context) {
    ref.listen(revisionProvider(DataKind.users), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final locations = ref.watch(locationsLookupProvider).value ?? const [];
    String assignments(UserRow u) => describeAssignments(u, locations);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Users',
          subtitle: 'People in this company and their roles',
          actions: [
            FilledButton.icon(
              onPressed: () => context.go('/users/new'),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('New user'),
            ),
          ],
        ),
        FilterBar(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: SearchField(
                hintText: 'Search name or email',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<UserRow>(
            controller: _paged,
            emptyMessage: 'No users found.',
            emptyIcon: Icons.group_outlined,
            columns: [
              TableColumnSpec('Name', (u) => Text(u.name)),
              TableColumnSpec('Email', (u) => Text(u.email)),
              TableColumnSpec('Phone', (u) => Text(u.phone ?? '—')),
              TableColumnSpec(
                'Roles',
                (u) => ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Text(assignments(u), overflow: TextOverflow.ellipsis),
                ),
              ),
              TableColumnSpec(
                'Status',
                (u) => u.isActive
                    ? const Pill('Active', color: Colors.green)
                    : Pill(
                        'Inactive',
                        color: Theme.of(context).colorScheme.outline,
                      ),
              ),
            ],
            cardBuilder: (context, u) => ListCard(
              leading: CircleAvatar(
                child: Text(u.name.isEmpty ? '?' : u.name[0].toUpperCase()),
              ),
              title: Text(u.name, overflow: TextOverflow.ellipsis),
              subtitle: Text('${u.email}\n${assignments(u)}'),
              trailing: u.isActive
                  ? null
                  : Pill(
                      'Inactive',
                      color: Theme.of(context).colorScheme.outline,
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

/// `Owner · All locations; Site Supervisor · Site A`.
String describeAssignments(UserRow user, List<Location> locations) {
  if (user.assignments.isEmpty) return 'No role';
  final names = {for (final l in locations) l.id: l.name};
  return user.assignments
      .map((a) {
        final ids = a.locationIds;
        final scope = ids == null
            ? 'All locations'
            : ids.isEmpty
            ? 'No locations'
            : ids.map((id) => names[id] ?? '1 location').join(', ');
        return '${a.roleName} · $scope';
      })
      .join('; ');
}
