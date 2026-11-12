import '../platform/notifications_screen.dart' show NotificationBell;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/business_profile.dart';

import '../../core/theme.dart';
import '../../widgets/brand.dart';
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

  /// Path segments whose plain capitalised form reads wrong.
  static const _crumbNames = {
    'ipd': 'In-patients',
    'boms': 'Bills of materials',
    'jobwork': 'Job work',
    'pos': 'POS',
    'hr': 'HR',
    'gst': 'GST',
    'tds': 'TDS',
    'itc-ageing': 'ITC ageing',
    'gst-returns': 'GST returns',
    'gst-rates': 'GST rates',
    'tds-sections': 'TDS sections',
    'itr-pack': 'ITR pack',
    'sku-mapping': 'SKU mapping',
  };

  /// Label for the last path segment in the breadcrumb.
  static String crumbFor(String segment) {
    if (segment == 'new') return 'New';
    if (segment == 'edit') return 'Edit';
    final named = _crumbNames[segment];
    if (named != null) return named;
    final looksLikeId = RegExp(r'\d').hasMatch(segment) || segment.length >= 20;
    if (looksLikeId) return 'Details';
    final text = segment.replaceAll(RegExp(r'[-_]'), ' ');
    return text[0].toUpperCase() + text.substring(1);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value ?? SessionState.signedOut;
    final profile = ref.watch(businessProfileProvider);
    final groups = visibleNavGroups(session.permissions, profile: profile);
    final body = TermsScope(profile: profile, child: child);
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
      session: session,
      embedded: wide,
    );

    final back = parent == null
        ? null
        : BackButton(
            onPressed: () =>
                context.canPop() ? context.pop() : context.go(parent),
          );
    final actions = [
      if (!wide && session.companies.length > 1)
        _CompanySwitcher(session: session, compact: true),
      if (session.user != null && session.company != null)
        const NotificationBell(),
      if (session.user != null)
        _UserMenu(user: session.user!, session: session),
      const SizedBox(width: Space.sm),
    ];

    if (wide) {
      final theme = Theme.of(context);
      final segments = Uri.parse(location).pathSegments;
      return Scaffold(
        body: Row(
          children: [
            SizedBox(width: _sidebarWidth, child: menu),
            Expanded(
              child: Column(
                children: [
                  Container(
                    height: 46,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      border: Border(
                        bottom: BorderSide(color: theme.dividerColor),
                      ),
                    ),
                    padding: const EdgeInsets.only(left: Space.sm),
                    child: Row(
                      children: [
                        ?back,
                        Expanded(
                          child: segments.length >= 2 && selected != null
                              ? _Breadcrumb(
                                  section: entries[selected],
                                  segments: segments,
                                )
                              : const SizedBox.shrink(),
                        ),
                        ...actions,
                      ],
                    ),
                  ),
                  Expanded(
                    child: Theme(data: AppTheme.dense(theme), child: body),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: back,
        title: Text(
          selected == null ? 'Progen' : entries[selected].label,
          overflow: TextOverflow.ellipsis,
        ),
        actions: actions,
      ),
      drawer: menu,
      body: selected == null
          ? body
          : ShellTitle(title: entries[selected].label, child: body),
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.section, required this.segments});

  final NavEntry section;
  final List<String> segments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Row(
      children: [
        Flexible(
          child: InkWell(
            borderRadius: Radii.smallAll,
            onTap: () => context.go(section.path),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.xs,
                vertical: Space.xs,
              ),
              child: Text(
                section.label,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.xs),
          child: Icon(
            Icons.chevron_right,
            size: 16,
            color: theme.colorScheme.outline,
          ),
        ),
        Flexible(
          child: Text(
            AppShell.crumbFor(segments.last),
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

const double _sidebarWidth = 240;

class _NavMenu extends StatelessWidget {
  const _NavMenu({
    required this.groups,
    required this.selectedIndex,
    required this.onSelected,
    required this.session,
    required this.embedded,
  });

  final List<NavGroup> groups;

  /// Index among all destinations (groups flattened).
  final int? selectedIndex;
  final ValueChanged<int> onSelected;
  final SessionState session;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final headingStyle = theme.textTheme.labelSmall?.copyWith(
      color: colors.onSidebarMuted,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.9,
    );
    // A destination's Row doesn't flex its label, so cap labels at the row
    // width (drawer - 80 padding) minus its leading gap, icon and gap
    // (16 + 24 + 12) to ellipsize long names instead of overflowing.
    final drawerWidth = embedded
        ? _sidebarWidth
        : math.min(360.0, MediaQuery.sizeOf(context).width);
    final labelMaxWidth = math.max(48.0, drawerWidth - 132);
    final company = session.company;
    // NavigationDrawer scrolls its children, so a tall menu stays usable.
    return NavigationDrawer(
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelected,
      backgroundColor: colors.sidebar,
      elevation: embedded ? 0 : null,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.lg + 4,
            Space.lg,
            Space.lg,
            Space.sm,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wordmark(
              size: 26,
              color: colors.onSidebar,
              markBackground: Colors.white,
              markForeground: theme.colorScheme.primary,
            ),
          ),
        ),
        if (session.companies.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              Space.xs,
              Space.lg,
              Space.xs,
            ),
            child: _CompanySwitcher(session: session, compact: false),
          )
        else if (company != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.lg + 4,
              Space.xs,
              Space.lg,
              Space.xs,
            ),
            child: Text(
              company.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSidebarMuted,
              ),
            ),
          ),
        for (final (index, group) in groups.indexed) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(
              Space.lg + 4,
              index == 0 ? Space.md : Space.lg,
              Space.lg,
              Space.xs,
            ),
            child: Text(group.label, style: headingStyle),
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
        const SizedBox(height: Space.md),
      ],
    );
  }
}

class _CompanySwitcher extends ConsumerWidget {
  const _CompanySwitcher({required this.session, required this.compact});

  final SessionState session;

  /// Icon only (phone app bar) versus a full-width company field (sidebar).
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = session.company;
    final theme = Theme.of(context);
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
      child: compact
          ? const Padding(
              padding: EdgeInsets.all(Space.sm),
              child: Icon(Icons.business_outlined),
            )
          : Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                borderRadius: Radii.mediumAll,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      active?.name ?? 'Company',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: context.colors.onSidebar,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.unfold_more,
                    size: 18,
                    color: context.colors.onSidebarMuted,
                  ),
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
      icon: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: Radii.mediumAll,
        ),
        child: Text(
          user.initials,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Theme.of(context).colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
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
            leading: Icon(Icons.logout_outlined),
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
