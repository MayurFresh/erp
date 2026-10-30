import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Page for a top-level section inside the shell (no transition, so
/// switching sections from the menu is instant). Use it in `pageBuilder`
/// of a section's root `GoRoute`; sub-pages use a plain `builder`.
Page<void> sectionPage(GoRouterState state, Widget child) =>
    NoTransitionPage<void>(key: state.pageKey, child: child);

/// Key for screens that read their query string, so they start afresh
/// when only the query changes (e.g. `/receipts/new?partyId=…`).
Key queryKey(GoRouterState state) => ValueKey(state.uri.query);
