import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'accounting_models.dart';

final accountingRepositoryProvider = Provider<AccountingRepository>(
  (ref) => AccountingRepository(ref.watch(apiClientProvider)),
);

/// Every account (active and inactive) with today's balances, by code.
final chartOfAccountsProvider = FutureProvider.autoDispose<List<Account>>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchRevisions(const [
    ...moneyKinds,
    DataKind.accounts,
    DataKind.expenses,
  ]);
  return ref.watch(accountingRepositoryProvider).allAccounts();
});

typedef LedgerKey = ({
  String accountId,
  String from,
  String to,
  String? partyId,
});

final accountLedgerProvider = FutureProvider.autoDispose
    .family<Ledger, LedgerKey>((ref, key) {
      ref.watch(activeCompanyIdProvider);
      ref.watchRevisions(const [
        ...moneyKinds,
        DataKind.accounts,
        DataKind.expenses,
        DataKind.stock,
        DataKind.transfers,
      ]);
      return ref
          .watch(accountingRepositoryProvider)
          .ledger(
            key.accountId,
            from: key.from,
            to: key.to,
            partyId: key.partyId,
          );
    });

final journalEntryProvider = FutureProvider.autoDispose
    .family<JournalEntry, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(accountingRepositoryProvider).journal(id);
    });

class AccountingRepository {
  AccountingRepository(this._api);

  final ApiClient _api;

  /// `GET /accounts` returns the whole chart (ordered by code); later pages
  /// are fetched if a server ever pages it.
  Future<List<Account>> allAccounts({
    String? type,
    bool activeOnly = false,
  }) async {
    final result = <Account>[];
    var offset = 0;
    for (var guard = 0; guard < 20; guard++) {
      final page = await _api.getPage(
        '/accounts',
        Account.fromJson,
        query: {
          'type': type,
          if (activeOnly) 'activeOnly': true,
          'limit': 200,
          'offset': offset,
        },
      );
      result.addAll(page.data);
      offset += page.data.length;
      if (page.data.isEmpty || result.length >= page.total) break;
    }
    return result;
  }

  Future<Account> create(NewAccount account) async => Account.fromJson(
    await _api.postJson('/accounts', body: account.toJson()),
  );

  /// Sends only what changed. System accounts may only be renamed, so
  /// `code` and `isActive` are never sent for them.
  Future<Account> update(
    Account original, {
    String? name,
    String? code,
    bool? isActive,
  }) async {
    final body = <String, dynamic>{
      if (name != null && name != original.name) 'name': name,
      if (!original.isSystem && code != null && code != original.code)
        'code': code,
      if (!original.isSystem &&
          isActive != null &&
          isActive != original.isActive)
        'isActive': isActive,
    };
    if (body.isEmpty) return original;
    return Account.fromJson(
      await _api.patchJson('/accounts/${original.id}', body: body),
    );
  }

  /// `from`/`to` default to the financial year to date on the server.
  Future<Ledger> ledger(
    String accountId, {
    String? from,
    String? to,
    String? partyId,
  }) async => Ledger.fromJson(
    await _api.getJson(
      '/accounts/$accountId/ledger',
      query: {'from': from, 'to': to, 'partyId': partyId},
    ),
  );

  /// The day book, newest first.
  Future<Paged<JournalEntry>> journals({
    String? q,
    String? from,
    String? to,
    String? voucherType,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/journals',
    JournalEntry.fromJson,
    query: {
      'q': q,
      'from': from,
      'to': to,
      'voucherType': voucherType,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<JournalEntry> journal(String id) async =>
      JournalEntry.fromJson(await _api.getJson('/journals/$id'));

  Future<JournalEntry> createJournal(JournalDraft draft) async =>
      JournalEntry.fromJson(
        await _api.postJson('/journals', body: draft.toJson()),
      );

  /// Returns the reversing entry.
  Future<JournalEntry> cancelJournal(String id, String reason) async =>
      JournalEntry.fromJson(
        await _api.postJson('/journals/$id/cancel', body: {'reason': reason}),
      );
}
