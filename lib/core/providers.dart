import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'config.dart';
import 'token_store.dart';

final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(
    baseUrl: AppConfig.apiBaseUrl,
    tokenStore: ref.watch(tokenStoreProvider),
  );
  ref.onDispose(client.close);
  return client;
});

/// Kinds of data whose lists should reload after a write elsewhere.
enum DataKind {
  items,
  parties,
  locations,
  stock,
  invoices,
  users,
  company,
  purchases,
  payments,
  creditNotes,
  transfers,
  expenses,
  accounts,
}

/// Bumped after a successful write so lists and details of that kind reload.
final revisionProvider =
    NotifierProvider.family<RevisionNotifier, int, DataKind>(
      RevisionNotifier.new,
    );

class RevisionNotifier extends Notifier<int> {
  RevisionNotifier(this.kind);

  final DataKind kind;

  @override
  int build() => 0;

  void bump() => state++;
}

/// Documents that change a party's balance and open documents.
const moneyKinds = [
  DataKind.parties,
  DataKind.invoices,
  DataKind.purchases,
  DataKind.payments,
  DataKind.creditNotes,
];

extension WatchRevisions on Ref {
  /// Re-runs the provider after a write to any of [kinds].
  void watchRevisions(Iterable<DataKind> kinds) {
    for (final kind in kinds) {
      watch(revisionProvider(kind));
    }
  }
}

extension RevisionRef on WidgetRef {
  void bump(Iterable<DataKind> kinds) {
    for (final kind in kinds) {
      read(revisionProvider(kind).notifier).bump();
    }
  }
}
