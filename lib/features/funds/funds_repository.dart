import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'funds_models.dart';

/// Bumped after every write so lists and the home screens reload.
final fundsRevisionProvider = NotifierProvider<FundsRevision, int>(
  FundsRevision.new,
);

class FundsRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

extension FundsBump on WidgetRef {
  void bumpFunds() => read(fundsRevisionProvider.notifier).bump();
}

final fundsRepositoryProvider = Provider<FundsRepository>(
  (ref) => FundsRepository(ref.watch(apiClientProvider)),
);

void _watch(Ref ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(fundsRevisionProvider);
}

final fundsHomeProvider = FutureProvider.autoDispose.family<FundsHome, String?>(
  (ref, fy) {
    _watch(ref);
    return ref.watch(fundsRepositoryProvider).home(fy);
  },
);

final headsProvider = FutureProvider.autoDispose.family<HeadsData, String?>((
  ref,
  fy,
) {
  _watch(ref);
  return ref.watch(fundsRepositoryProvider).heads(fy);
});

final fundsListProvider = FutureProvider.autoDispose<List<FundRow>>((ref) {
  _watch(ref);
  return ref.watch(fundsRepositoryProvider).funds();
});

final sanctionsProvider = FutureProvider.autoDispose
    .family<List<Sanction>, String?>((ref, status) {
      _watch(ref);
      return ref.watch(fundsRepositoryProvider).sanctions(status);
    });

final reappsProvider = FutureProvider.autoDispose.family<List<Reapp>, String?>((
  ref,
  fy,
) {
  _watch(ref);
  return ref.watch(fundsRepositoryProvider).reapps(fy);
});

final spendableProvider = FutureProvider.autoDispose
    .family<List<Spendable>, ({String type, String q})>((ref, key) {
      _watch(ref);
      return ref.watch(fundsRepositoryProvider).spendable(key.type, key.q);
    });

final spendLinksProvider = FutureProvider.autoDispose<List<SpendLink>>((ref) {
  _watch(ref);
  return ref.watch(fundsRepositoryProvider).links();
});

final fundsSettingsProvider = FutureProvider.autoDispose<FundsSettings>((ref) {
  _watch(ref);
  return ref.watch(fundsRepositoryProvider).settings();
});

final donationHomeProvider = FutureProvider.autoDispose<DonationHome>((ref) {
  _watch(ref);
  return ref.watch(fundsRepositoryProvider).donationHome();
});

final donationsProvider = FutureProvider.autoDispose
    .family<List<Donation>, String>((ref, q) {
      _watch(ref);
      return ref.watch(fundsRepositoryProvider).donations(q);
    });

final donorsProvider = FutureProvider.autoDispose.family<List<Donor>, String>((
  ref,
  q,
) {
  _watch(ref);
  return ref.watch(fundsRepositoryProvider).donors(q);
});

class FundsRepository {
  FundsRepository(this._api);

  final ApiClient _api;

  // ---- funds
  Future<FundsHome> home(String? fy) async =>
      FundsHome.fromJson(await _api.getJson('/funds/home', query: {'fy': fy}));

  Future<HeadsData> heads(String? fy) async =>
      HeadsData.fromJson(await _api.getJson('/funds/heads', query: {'fy': fy}));

  Future<HeadRow> saveHead(String? id, Json body) async => HeadRow.fromJson(
    id == null
        ? await _api.postJson('/funds/heads', body: body)
        : await _api.patchJson('/funds/heads/$id', body: body),
  );

  Future<List<FundRow>> funds() async =>
      (await _api.getPage('/funds/funds', FundRow.fromJson)).data;

  Future<FundRow> saveFund(String? id, Json body) async => FundRow.fromJson(
    id == null
        ? await _api.postJson('/funds/funds', body: body)
        : await _api.patchJson('/funds/funds/$id', body: body),
  );

  Future<void> grantReceived(String fundId, Json body) async {
    await _api.postJson('/funds/funds/$fundId/receipts', body: body);
  }

  Future<List<Reapp>> reapps(String? fy) async => (await _api.getPage(
    '/funds/reappropriations',
    Reapp.fromJson,
    query: {'fy': fy},
  )).data;

  Future<Reapp> createReapp(Json body) async => Reapp.fromJson(
    await _api.postJson('/funds/reappropriations', body: body),
  );

  Future<void> decideReapp(String id, bool approve) async {
    await _api.postJson(
      '/funds/reappropriations/$id/${approve ? 'approve' : 'reject'}',
      body: const {},
    );
  }

  Future<List<Sanction>> sanctions(String? status) async => (await _api.getPage(
    '/funds/sanctions',
    Sanction.fromJson,
    query: {'status': status},
  )).data;

  /// Returns the sanction; `warnings` of the response are read with [warningsOf].
  Future<Json> createSanction(Json body) =>
      _api.postJson('/funds/sanctions', body: body);

  Future<Json> approveSanction(String id, Json body) =>
      _api.postJson('/funds/sanctions/$id/approve', body: body);

  Future<void> sanctionAction(String id, String action, {String? note}) async {
    await _api.postJson(
      '/funds/sanctions/$id/$action',
      body: {if (note != null && note.isNotEmpty) 'note': note},
    );
  }

  Future<List<Spendable>> spendable(String type, String q) async =>
      (await _api.getPage(
        '/funds/spendable',
        Spendable.fromJson,
        query: {'type': type, if (q.isNotEmpty) 'q': q},
      )).data;

  Future<List<SpendLink>> links() async =>
      (await _api.getPage('/funds/links', SpendLink.fromJson)).data;

  Future<Json> link(Json body) => _api.postJson('/funds/links', body: body);

  Future<void> unlink(String id) async {
    await _api.delete('/funds/links/$id');
  }

  Future<FundsSettings> settings() async =>
      FundsSettings.fromJson(await _api.getJson('/funds/settings'));

  Future<FundsSettings> saveSettings(Json body) async => FundsSettings.fromJson(
    await _api.patchJson('/funds/settings', body: body),
  );

  Future<({List<HeadRow> data, Totals totals})> budgetVsActual(
    String? fy,
  ) async {
    final j = await _api.getJson(
      '/funds/reports/budget-vs-actual',
      query: {'fy': fy},
    );
    return (
      data: asJsonList(j['data']).map(HeadRow.fromJson).toList(),
      totals: Totals.fromJson(asJson(j['totals'])),
    );
  }

  Future<List<FundWiseRow>> fundWise(String from, String to) async {
    final j = await _api.getJson(
      '/funds/reports/fund-wise',
      query: {'from': from, 'to': to},
    );
    return asJsonList(j['data']).map(FundWiseRow.fromJson).toList();
  }

  Future<UcData> utilisation(String fundId, String from, String to) async =>
      UcData.fromJson(
        await _api.getJson(
          '/funds/funds/$fundId/utilisation',
          query: {'from': from, 'to': to},
        ),
      );

  // ---- donations
  Future<DonationHome> donationHome() async =>
      DonationHome.fromJson(await _api.getJson('/donations/home'));

  Future<List<Donation>> donations(String q) async => (await _api.getPage(
    '/donations',
    Donation.fromJson,
    query: {if (q.isNotEmpty) 'q': q, 'limit': 100},
  )).data;

  Future<Donation> createDonation(Json body) async =>
      Donation.fromJson(await _api.postJson('/donations', body: body));

  Future<ReceiptData> receipt(String id) async =>
      ReceiptData.fromJson(await _api.getJson('/donations/$id'));

  Future<void> cancelDonation(String id, String reason) async {
    await _api.postJson('/donations/$id/cancel', body: {'reason': reason});
  }

  Future<List<Donor>> donors(String q) async => (await _api.getPage(
    '/donors',
    Donor.fromJson,
    query: {if (q.isNotEmpty) 'q': q, 'limit': 100},
  )).data;

  /// Throws an `ApiException` with code `DUPLICATE_DONOR` unless forced.
  Future<Donor> saveDonor(String? id, Json body) async => Donor.fromJson(
    id == null
        ? await _api.postJson('/donors', body: body)
        : await _api.patchJson('/donors/$id', body: body),
  );

  Future<Json> statement(String donorId, String fy) =>
      _api.getJson('/donors/$donorId/statement', query: {'fy': fy});

  Future<Form10bd> form10bd(String fy) async => Form10bd.fromJson(
    await _api.getJson('/donations/form-10bd', query: {'fy': fy}),
  );

  Future<String> form10bdCsv(String fy) =>
      _api.getText('/donations/form-10bd', query: {'fy': fy, 'format': 'csv'});
}

List<String> warningsOf(Json response) => asStringList(response['warnings']);
