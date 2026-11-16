import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'receivables_models.dart';

/// Bumped after any write here so lists and details reload.
final receivablesRevisionProvider =
    NotifierProvider<ReceivablesRevision, int>(ReceivablesRevision.new);

class ReceivablesRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final receivablesRepositoryProvider = Provider<ReceivablesRepository>(
  (ref) => ReceivablesRepository(ref.watch(apiClientProvider)),
);

typedef PartyStatementKey = ({String partyId, String? from, String? to});

final partyStatementFullProvider = FutureProvider.autoDispose
    .family<PartyStatement, PartyStatementKey>((ref, key) {
      ref.watch(activeCompanyIdProvider);
      ref.watchRevisions(moneyKinds);
      return ref
          .watch(receivablesRepositoryProvider)
          .statement(key.partyId, from: key.from, to: key.to);
    });

final reminderSettingsProvider =
    FutureProvider.autoDispose<ReminderSettings>((ref) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(receivablesRevisionProvider);
      return ref.watch(receivablesRepositoryProvider).reminderSettings();
    });

final excludedPartiesProvider =
    FutureProvider.autoDispose<List<ExcludedParty>>((ref) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(receivablesRevisionProvider);
      return ref.watch(receivablesRepositoryProvider).excluded();
    });

final reminderLogProvider =
    FutureProvider.autoDispose<List<ReminderLogEntry>>((ref) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(receivablesRevisionProvider);
      return ref.watch(receivablesRepositoryProvider).reminderLog();
    });

final recurringListProvider =
    FutureProvider.autoDispose.family<List<RecurringInvoice>, String?>((
      ref,
      status,
    ) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(receivablesRevisionProvider);
      return ref.watch(receivablesRepositoryProvider).recurring(status: status);
    });

final recurringProvider = FutureProvider.autoDispose
    .family<RecurringInvoice, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(receivablesRevisionProvider);
      return ref.watch(receivablesRepositoryProvider).recurringOne(id);
    });

class ReceivablesRepository {
  ReceivablesRepository(this._api);

  final ApiClient _api;

  Future<PartyStatement> statement(String partyId, {String? from, String? to}) async =>
      PartyStatement.fromJson(
        await _api.getJson(
          '/parties/$partyId/statement',
          query: {'from': from, 'to': to},
        ),
      );

  Future<ReminderSettings> reminderSettings() async =>
      ReminderSettings.fromJson(await _api.getJson('/reminders/settings'));

  Future<ReminderSettings> saveReminderSettings(ReminderSettings s) async =>
      ReminderSettings.fromJson(
        await _api.patchJson('/reminders/settings', body: s.toJson()),
      );

  Future<List<ExcludedParty>> excluded() async => asJsonList(
    (await _api.getJson('/reminders/excluded'))['data'],
  ).map(ExcludedParty.fromJson).toList();

  Future<void> setDoNotRemind(String partyId, bool value) => _api.patchJson(
    '/parties/$partyId/reminders',
    body: {'doNotRemind': value},
  );

  Future<ReminderRunResult> runReminders() async =>
      ReminderRunResult.fromJson(await _api.postJson('/reminders/run'));

  Future<List<ReminderLogEntry>> reminderLog({int limit = 100}) async =>
      asJsonList(
        (await _api.getJson('/reminders/log', query: {'limit': limit}))['data'],
      ).map(ReminderLogEntry.fromJson).toList();

  Future<List<RecurringInvoice>> recurring({String? status}) async =>
      asJsonList(
        (await _api.getJson(
          '/recurring-invoices',
          query: {'status': status, 'limit': 200},
        ))['data'],
      ).map(RecurringInvoice.fromJson).toList();

  Future<RecurringInvoice> recurringOne(String id) async =>
      RecurringInvoice.fromJson(await _api.getJson('/recurring-invoices/$id'));

  Future<RecurringInvoice> createRecurring(Json body) async =>
      RecurringInvoice.fromJson(
        await _api.postJson('/recurring-invoices', body: body),
      );

  Future<RecurringInvoice> updateRecurring(String id, Json body) async =>
      RecurringInvoice.fromJson(
        await _api.patchJson('/recurring-invoices/$id', body: body),
      );

  Future<RecurringInvoice> action(String id, String action) async =>
      RecurringInvoice.fromJson(
        await _api.postJson('/recurring-invoices/$id/$action'),
      );

  Future<RecurringRunResult> runRecurring() async =>
      RecurringRunResult.fromJson(await _api.postJson('/recurring-invoices/run'));
}
