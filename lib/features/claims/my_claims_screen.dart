import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'claims_repository.dart';
import 'claims_widgets.dart';

/// `/my-claims`: the signed-in person's claims, newest first.
class MyClaimsScreen extends ConsumerWidget {
  const MyClaimsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(claimsListProvider((mine: true, status: null)));
    final perms = ref.watch(permissionsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'My claims',
          subtitle: 'Expenses you paid for the business',
          actions: [
            FilledButton.icon(
              onPressed: () => context.go('/my-claims/new'),
              icon: const Icon(Icons.add),
              label: const Text('New claim'),
            ),
            if (perms.can(Perm.claimsApprove))
              OutlinedButton(
                onPressed: () => context.go('/claims/approvals'),
                child: const Text('Approvals'),
              ),
          ],
        ),
        Expanded(
          child: list.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(claimsListProvider)),
            data: (claims) => claims.isEmpty
                ? EmptyView(
                    message: 'You have no claims yet.\nTake a photo of a bill to start one.',
                    action: FilledButton(
                      onPressed: () => context.go('/my-claims/new'),
                      child: const Text('New claim'),
                    ),
                  )
                : ListView(
                    padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
                    children: [
                      for (final c in claims)
                        ClaimTile(claim: c, onTap: () => context.go('/claims/${c.id}')),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}
