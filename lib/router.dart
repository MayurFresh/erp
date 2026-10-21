import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/audit/audit_screen.dart';
import 'features/credit_notes/credit_note_create_screen.dart';
import 'features/credit_notes/credit_note_detail_screen.dart';
import 'features/credit_notes/credit_notes_screen.dart';
import 'features/expenses/expense_create_screen.dart';
import 'features/expenses/expense_detail_screen.dart';
import 'features/expenses/expenses_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/session.dart';
import 'features/auth/signup_screen.dart';
import 'features/auth/splash_screen.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/invoices/invoice_create_screen.dart';
import 'features/invoices/invoice_detail_screen.dart';
import 'features/invoices/invoices_screen.dart';
import 'features/items/item_form_screen.dart';
import 'features/items/items_screen.dart';
import 'features/locations/locations_screen.dart';
import 'features/parties/parties_screen.dart';
import 'features/parties/party_detail_screen.dart';
import 'features/parties/party_form_screen.dart';
import 'features/payments/payment_create_screen.dart';
import 'features/payments/payment_detail_screen.dart';
import 'features/payments/payment_model.dart';
import 'features/payments/payments_screen.dart';
import 'features/purchases/purchase_create_screen.dart';
import 'features/purchases/purchase_detail_screen.dart';
import 'features/purchases/purchases_screen.dart';
import 'features/shell/app_shell.dart';
import 'features/shell/nav.dart';
import 'features/stock/stock_moves_screen.dart';
import 'features/stock/stock_screen.dart';
import 'features/transfers/transfer_create_screen.dart';
import 'features/transfers/transfer_detail_screen.dart';
import 'features/transfers/transfers_screen.dart';
import 'features/users/user_form_screen.dart';
import 'features/users/users_screen.dart';
import 'widgets/states.dart';

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');
final _shellKey = GlobalKey<NavigatorState>(debugLabel: 'shell');

/// Where to send the user for [uri] given the session, or `null` to stay.
String? sessionRedirect(AsyncValue<SessionState> session, Uri uri) {
  final path = uri.path;
  final isAuthPage = path == '/login' || path == '/signup';
  final from = uri.queryParameters['from'];
  final s = session.value;

  if (s == null) {
    // Restoring (or failed to restore) the session.
    if (path == '/splash') return null;
    return _withFrom('/splash', uri);
  }
  if (!s.isSignedIn) {
    if (isAuthPage) return null;
    return path == '/splash' && from != null
        ? '/login?from=${Uri.encodeComponent(from)}'
        : _withFrom('/login', uri);
  }

  final home = homePath(s.permissions);
  if (isAuthPage || path == '/splash' || path == '/') {
    final target = from == null ? null : Uri.tryParse(from);
    if (target != null && _allowed(s, target.path)) return from;
    return home;
  }
  if (!_allowed(s, path)) return path == home ? null : home;
  return null;
}

bool _allowed(SessionState s, String path) {
  if (path == '/' || path == '/login' || path == '/signup') return false;
  if (path == '/splash') return false;
  final permission = requiredPermission(path);
  return permission == null || s.can(permission);
}

String _withFrom(String target, Uri uri) {
  final current = uri.toString();
  if (uri.path == '/' || uri.path == '/splash' || uri.path == '/login') {
    return target;
  }
  return '$target?from=${Uri.encodeComponent(current)}';
}

Page<void> _section(GoRouterState state, Widget child) =>
    NoTransitionPage<void>(key: state.pageKey, child: child);

/// Screens that read their query string start afresh when it changes.
Key _queryKey(GoRouterState state) => ValueKey(state.uri.query);

/// `/receipts` or `/payments`: list, new (optionally pre-filled with
/// `partyId`, `docId` and `amount`) and detail.
GoRoute _paymentsRoute(PaymentKind kind) => GoRoute(
  path: kind.basePath,
  pageBuilder: (_, state) => _section(state, PaymentsScreen(kind: kind)),
  routes: [
    GoRoute(
      path: 'new',
      builder: (_, state) => PaymentCreateScreen(
        key: _queryKey(state),
        kind: kind,
        initialPartyId: state.uri.queryParameters['partyId'],
        initialDocId: state.uri.queryParameters['docId'],
        initialAmount: state.uri.queryParameters['amount'],
      ),
    ),
    GoRoute(
      path: ':id',
      builder: (_, state) =>
          PaymentDetailScreen(paymentId: state.pathParameters['id']!),
    ),
  ],
);

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(sessionProvider, (_, _) => refresh.value++);

  final router = GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) =>
        sessionRedirect(ref.read(sessionProvider), state.uri),
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('Not found')),
      body: EmptyView(
        icon: Icons.search_off,
        message: 'No page at ${state.uri.path}',
        action: FilledButton(
          onPressed: () => context.go('/'),
          child: const Text('Go home'),
        ),
      ),
    ),
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/signup', builder: (_, _) => const SignupScreen()),
      ShellRoute(
        navigatorKey: _shellKey,
        builder: (context, state, child) =>
            AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/no-access',
            pageBuilder: (_, state) => _section(state, const NoAccessScreen()),
          ),
          GoRoute(
            path: '/dashboard',
            pageBuilder: (_, state) => _section(state, const DashboardScreen()),
          ),
          GoRoute(
            path: '/invoices',
            pageBuilder: (_, state) => _section(state, const InvoicesScreen()),
            routes: [
              GoRoute(
                path: 'new',
                builder: (_, state) => InvoiceCreateScreen(
                  key: _queryKey(state),
                  initialPartyId: state.uri.queryParameters['partyId'],
                ),
              ),
              GoRoute(
                path: ':id',
                builder: (_, state) =>
                    InvoiceDetailScreen(invoiceId: state.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: '/credit-notes',
            pageBuilder: (_, state) =>
                _section(state, const CreditNotesScreen()),
            routes: [
              GoRoute(
                path: 'new',
                builder: (_, state) => CreditNoteCreateScreen(
                  key: _queryKey(state),
                  initialInvoiceId: state.uri.queryParameters['invoiceId'],
                ),
              ),
              GoRoute(
                path: ':id',
                builder: (_, state) => CreditNoteDetailScreen(
                  creditNoteId: state.pathParameters['id']!,
                ),
              ),
            ],
          ),
          _paymentsRoute(PaymentKind.receipt),
          GoRoute(
            path: '/purchases',
            pageBuilder: (_, state) => _section(state, const PurchasesScreen()),
            routes: [
              GoRoute(
                path: 'new',
                builder: (_, state) => PurchaseCreateScreen(
                  key: _queryKey(state),
                  initialPartyId: state.uri.queryParameters['partyId'],
                ),
              ),
              GoRoute(
                path: ':id',
                builder: (_, state) => PurchaseDetailScreen(
                  purchaseId: state.pathParameters['id']!,
                ),
              ),
            ],
          ),
          _paymentsRoute(PaymentKind.payment),
          GoRoute(
            path: '/expenses',
            pageBuilder: (_, state) => _section(state, const ExpensesScreen()),
            routes: [
              GoRoute(
                path: 'new',
                builder: (_, _) => const ExpenseCreateScreen(),
              ),
              GoRoute(
                path: ':id',
                builder: (_, state) =>
                    ExpenseDetailScreen(expenseId: state.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: '/transfers',
            pageBuilder: (_, state) => _section(state, const TransfersScreen()),
            routes: [
              GoRoute(
                path: 'new',
                builder: (_, _) => const TransferCreateScreen(),
              ),
              GoRoute(
                path: ':id',
                builder: (_, state) => TransferDetailScreen(
                  transferId: state.pathParameters['id']!,
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/items',
            pageBuilder: (_, state) => _section(state, const ItemsScreen()),
            routes: [
              GoRoute(path: 'new', builder: (_, _) => const ItemFormScreen()),
              GoRoute(
                path: ':id',
                builder: (_, state) =>
                    ItemFormScreen(itemId: state.pathParameters['id']),
              ),
            ],
          ),
          GoRoute(
            path: '/stock',
            pageBuilder: (_, state) => _section(
              state,
              StockScreen(
                initialLowOnly: state.uri.queryParameters['lowOnly'] == 'true',
              ),
            ),
            routes: [
              GoRoute(
                path: 'moves',
                builder: (_, state) => StockMovesScreen(
                  key: _queryKey(state),
                  itemId: state.uri.queryParameters['itemId'],
                  locationId: state.uri.queryParameters['locationId'],
                  title: state.uri.queryParameters['title'],
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/parties',
            pageBuilder: (_, state) => _section(state, const PartiesScreen()),
            routes: [
              GoRoute(path: 'new', builder: (_, _) => const PartyFormScreen()),
              GoRoute(
                path: ':id',
                builder: (_, state) =>
                    PartyDetailScreen(partyId: state.pathParameters['id']!),
                routes: [
                  GoRoute(
                    path: 'edit',
                    builder: (_, state) =>
                        PartyFormScreen(partyId: state.pathParameters['id']),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: '/locations',
            pageBuilder: (_, state) => _section(state, const LocationsScreen()),
          ),
          GoRoute(
            path: '/users',
            pageBuilder: (_, state) => _section(state, const UsersScreen()),
            routes: [
              GoRoute(path: 'new', builder: (_, _) => const UserFormScreen()),
            ],
          ),
          GoRoute(
            path: '/audit',
            pageBuilder: (_, state) => _section(state, const AuditScreen()),
          ),
        ],
      ),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});
