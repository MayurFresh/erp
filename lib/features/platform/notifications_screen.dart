import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'platform_models.dart';
import 'platform_repository.dart';
import 'security_screen.dart' show formatStamp;

/// Unread notification count shown on the bell; `null` until first loaded.
final unreadCountProvider = NotifierProvider<UnreadCount, int?>(
  UnreadCount.new,
);

class UnreadCount extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? value) => state = value;
}

final notificationsProvider =
    FutureProvider.autoDispose<({List<AppNotification> data, int unread})>((
      ref,
    ) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(platformRepositoryProvider).notifications();
    });

/// App-bar bell with the unread badge. Polls every 60 s while the app is in
/// the foreground.
/// How often the bell asks for the unread count; null turns polling off
/// (widget tests that only need the shell).
final bellPollIntervalProvider = Provider<Duration?>(
  (ref) => const Duration(seconds: 60),
);

class NotificationBell extends ConsumerStatefulWidget {
  const NotificationBell({super.key});

  @override
  ConsumerState<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends ConsumerState<NotificationBell>
    with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final interval = ref.read(bellPollIntervalProvider);
    if (interval == null) return;
    _poll();
    _timer = Timer.periodic(interval, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final interval = ref.read(bellPollIntervalProvider);
    if (interval == null) return;
    if (state == AppLifecycleState.resumed) {
      _poll();
      _timer ??= Timer.periodic(interval, (_) => _poll());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _poll() async {
    try {
      final n = await ref.read(platformRepositoryProvider).unreadCount();
      if (mounted) ref.read(unreadCountProvider.notifier).set(n);
    } catch (_) {
      // Best effort; the next tick tries again.
    }
  }

  @override
  Widget build(BuildContext context) {
    final unread = ref.watch(unreadCountProvider) ?? 0;
    return IconButton(
      key: const Key('notifications.bell'),
      tooltip: unread > 0 ? 'Notifications ($unread unread)' : 'Notifications',
      onPressed: () => context.go('/notifications'),
      icon: Badge(
        isLabelVisible: unread > 0,
        label: Text(
          unread > 99 ? '99+' : '$unread',
          key: const Key('notifications.badge'),
        ),
        child: const Icon(Icons.notifications_outlined),
      ),
    );
  }
}

/// `/notifications`: the signed-in user's notifications.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(notificationsProvider);
    final repo = ref.read(platformRepositoryProvider);

    Future<void> refresh() async {
      ref.invalidate(notificationsProvider);
      try {
        ref.read(unreadCountProvider.notifier).set(await repo.unreadCount());
      } catch (_) {}
    }

    Future<void> open(AppNotification n) async {
      try {
        if (n.unread) {
          await repo.markRead(n.id);
          await refresh();
        }
      } catch (e) {
        if (context.mounted) showErrorSnackBar(context, e);
      }
      final link = n.link;
      if (link != null && link.isNotEmpty && context.mounted) context.go(link);
    }

    return AsyncValueView(
      value: value,
      onRetry: () => ref.invalidate(notificationsProvider),
      data: (page) => Column(
        children: [
          PageHeader(
            title: 'Notifications',
            subtitle: page.unread > 0 ? '${page.unread} unread' : null,
            actions: [
              OutlinedButton.icon(
                key: const Key('notifications.readAll'),
                onPressed: page.unread == 0
                    ? null
                    : () async {
                        try {
                          await repo.markAllRead();
                          await refresh();
                        } catch (e) {
                          if (context.mounted) showErrorSnackBar(context, e);
                        }
                      },
                icon: const Icon(Icons.done_all),
                label: const Text('Mark all read'),
              ),
            ],
          ),
          Expanded(
            child: page.data.isEmpty
                ? const EmptyView(
                    icon: Icons.notifications_none,
                    message: "You're all caught up.",
                  )
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: double.infinity,
                      ),
                      child: ListView.separated(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: page.data.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final n = page.data[i];
                          return ListTile(
                            key: Key('notification.${n.id}'),
                            leading: Icon(
                              n.unread ? Icons.circle : Icons.circle_outlined,
                              size: 12,
                            ),
                            title: Text(
                              n.title,
                              style: TextStyle(
                                fontWeight: n.unread
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                            subtitle: Text(
                              '${n.body}\n${formatStamp(n.createdAt)}',
                            ),
                            isThreeLine: true,
                            trailing: n.unread
                                ? IconButton(
                                    key: Key('notification.read.${n.id}'),
                                    tooltip: 'Mark read',
                                    icon: const Icon(Icons.check),
                                    onPressed: () async {
                                      try {
                                        await repo.markRead(n.id);
                                        await refresh();
                                      } catch (e) {
                                        if (context.mounted) {
                                          showErrorSnackBar(context, e);
                                        }
                                      }
                                    },
                                  )
                                : null,
                            onTap: () => open(n),
                          );
                        },
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
