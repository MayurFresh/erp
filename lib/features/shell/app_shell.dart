import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/auth_models.dart';
import '../auth/session.dart';
import 'nav.dart';

/// Responsive scaffold: a permanent, grouped sidebar from [kWideLayout] up,
/// an app bar with a drawer (same groups) below it. Only permitted sections
/// are listed and groups without any are hidden.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.location, required this.child});

  /// Current path, e.g. `/items/new`.
  final String location;
  final Widget child;

  /// One level up: `/parties/p1/edit` → `/parties/p1`; `null` for sections.
  static String? parentPath(String location) {
    final segments = Uri.parse(location).pathSegments;
    if (segments.length < 2) return null;
    return '/${segments.sublist(0, segments.length - 1).join('/')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value ?? SessionState.signedOut;
    final groups = visibleNavGroups(session.permissions);
    final entries = [for (final group in groups) ...group.entries];
    final selected = navIndexFor(entries, location);
    final wide = MediaQuery.sizeOf(context).width >= kWideLayout;
    final parent = parentPath(location);

    void open(int index) {
      if (!wide) Navigator.of(context).pop(); // close the drawer
      context.go(entries[index].path);
    }

    final menu = _NavMenu(
      groups: groups,
      selectedIndex: selected,
      onSelected: open,
      company: session.company,
      embedded: wide,
    );

    final appBar = AppBar(
      leading: parent == null
          ? null
          : BackButton(
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go(parent),
            ),
      title: Text(
        wide || selected == null ? 'Progen ERP' : entries[selected].label,
      ),
      actions: [
        if (session.companies.length > 1)
          _CompanySwitcher(session: session, wide: wide)
        else if (wide && session.company != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(child: Text(session.company!.name)),
          ),
        if (session.user != null)
          _UserMenu(user: session.user!, session: session),
        const SizedBox(width: 8),
      ],
    );

    if (wide) {
      return Scaffold(
        appBar: appBar,
        body: Row(
          children: [
            SizedBox(width: _sidebarWidth, child: menu),
            const VerticalDivider(width: 1),
            Expanded(child: child),
          ],
        ),
      );
    }
    return Scaffold(appBar: appBar, drawer: menu, body: child);
  }
}

const double _sidebarWidth = 256;

class _NavMenu extends StatelessWidget {
  const _NavMenu({
    required this.groups,
    required this.selectedIndex,
    required this.onSelected,
    required this.company,
    required this.embedded,
  });

  final List<NavGroup> groups;

  /// Index among all destinations (groups flattened).
  final int? selectedIndex;
  final ValueChanged<int> onSelected;
  final Membership? company;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headingStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.6,
    );
    // A destination's Row doesn't flex its label, so cap labels at the row
    // width (drawer − 80 padding) minus its leading gap, icon and gap
    // (16 + 24 + 12) to ellipsize long names instead of overflowing.
    final drawerWidth = embedded
        ? _sidebarWidth
        : math.min(360.0, MediaQuery.sizeOf(context).width);
    final labelMaxWidth = math.max(48.0, drawerWidth - 132);
    // NavigationDrawer scrolls its children, so a tall menu stays usable.
    return NavigationDrawer(
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelected,
      backgroundColor: embedded ? theme.colorScheme.surface : null,
      elevation: embedded ? 0 : null,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!embedded)
                Text('Progen ERP', style: theme.textTheme.titleLarge),
              if (company != null)
                Text(
                  company!.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        for (final (index, group) in groups.indexed) ...[
          if (index > 0)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 28),
              child: Divider(height: 16),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 16, 6),
            child: Text(group.label.toUpperCase(), style: headingStyle),
          ),
          for (final entry in group.entries)
            NavigationDrawerDestination(
              icon: Icon(entry.icon),
              selectedIcon: Icon(entry.selectedIcon),
              label: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: labelMaxWidth),
                child: Text(
                  entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }
}

class _CompanySwitcher extends ConsumerWidget {
  const _CompanySwitcher({required this.session, required this.wide});

  final SessionState session;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = session.company;
    return PopupMenuButton<String>(
      tooltip: 'Switch company',
      onSelected: (id) async {
        if (id == active?.id) return;
        try {
          await ref.read(sessionProvider.notifier).switchCompany(id);
          if (context.mounted) context.go('/');
        } catch (e) {
          if (context.mounted) showErrorSnackBar(context, e);
        }
      },
      itemBuilder: (context) => [
        for (final company in session.companies)
          CheckedPopupMenuItem<String>(
            value: company.id,
            checked: company.id == active?.id,
            child: Text(company.name),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.business_outlined),
            if (wide) ...[
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  active?.name ?? 'Company',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

class _UserMenu extends ConsumerWidget {
  const _UserMenu({required this.user, required this.session});

  final User user;
  final SessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roles = session.company?.roles.map((r) => r.name).join(', ') ?? '';
    return PopupMenuButton<String>(
      tooltip: 'Account',
      icon: CircleAvatar(radius: 16, child: Text(user.initials)),
      onSelected: (value) {
        if (value == 'account') context.go('/account');
        if (value == 'logout') ref.read(sessionProvider.notifier).logout();
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(user.name),
            subtitle: Text(
              roles.isEmpty ? user.email : '${user.email}\n$roles',
            ),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'account',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.person_outline),
            title: Text('My account'),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'logout',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout),
            title: Text('Sign out'),
          ),
        ),
      ],
    );
  }
}

class NoAccessScreen extends StatelessWidget {
  const NoAccessScreen({super.key});

  @override
  Widget build(BuildContext context) => const EmptyView(
    icon: Icons.lock_outline,
    message:
        'Your role has no screens enabled in this company.\n'
        'Ask an administrator for access.',
  );
}
