import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'crm_models.dart';

/// Bumped after every CRM write so lists reload.
final crmRevisionProvider = NotifierProvider<CrmRevision, int>(
  CrmRevision.new,
);

class CrmRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

extension CrmRefresh on WidgetRef {
  void bumpCrm() => read(crmRevisionProvider.notifier).bump();
}

final crmRepositoryProvider = Provider<CrmRepository>(
  (ref) => CrmRepository(ref.watch(apiClientProvider)),
);

/// Owner choice on the Today, Leads, Deals and Numbers screens. `null` is the
/// signed-in user, `all` is everyone (needs `crm.all`), else a user id.
final crmOwnerChoiceProvider = NotifierProvider<CrmOwnerChoice, String?>(
  CrmOwnerChoice.new,
);

class CrmOwnerChoice extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? v) => state = v;
}

FutureProvider<T> _watched<T>(Future<T> Function(CrmRepository r) load) =>
    FutureProvider<T>((ref) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(crmRevisionProvider);
      return load(ref.watch(crmRepositoryProvider));
    });

final crmTodayProvider = _watchedOwner((r, owner) => r.today(owner));
final crmPipelineProvider = _watchedOwner((r, owner) => r.pipeline(owner));
final crmStagesProvider = _watched((r) => r.stages());
final crmSettingsProvider = _watched((r) => r.settings());
final crmOwnersProvider = _watched((r) => r.owners());

FutureProvider<T> _watchedOwner<T>(
  Future<T> Function(CrmRepository r, String? owner) load,
) => FutureProvider<T>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(crmRevisionProvider);
  final owner = ref.watch(crmOwnerChoiceProvider);
  return load(ref.watch(crmRepositoryProvider), owner);
});

/// Leads; the key is `status|source|q`.
final crmLeadsProvider = FutureProvider.family<List<CrmLead>, String>((
  ref,
  key,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(crmRevisionProvider);
  final owner = ref.watch(crmOwnerChoiceProvider);
  final p = key.split('|');
  return ref
      .watch(crmRepositoryProvider)
      .leads(status: p[0], source: p[1], q: p[2], owner: owner);
});

/// Deals; the key is the status.
final crmDealsProvider = FutureProvider.family<List<CrmDeal>, String>((
  ref,
  status,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(crmRevisionProvider);
  final owner = ref.watch(crmOwnerChoiceProvider);
  return ref.watch(crmRepositoryProvider).deals(status: status, owner: owner);
});

final crmLeadProvider = FutureProvider.family<LeadDetail, String>((ref, id) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(crmRevisionProvider);
  return ref.watch(crmRepositoryProvider).lead(id);
});

final crmDealProvider = FutureProvider.family<DealDetail, String>((ref, id) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(crmRevisionProvider);
  return ref.watch(crmRepositoryProvider).deal(id);
});

final crmOverviewProvider = FutureProvider.family<PartyOverview, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(crmRevisionProvider);
  return ref.watch(crmRepositoryProvider).overview(id);
});

/// Stats for the signed-in choice of owner; the key is `from|to`.
final crmStatsProvider = FutureProvider.family<CrmStats, String>((ref, key) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(crmRevisionProvider);
  final owner = ref.watch(crmOwnerChoiceProvider);
  final p = key.split('|');
  return ref
      .watch(crmRepositoryProvider)
      .stats(from: p[0], to: p[1], owner: owner);
});

/// Targets for a month, `YYYY-MM`.
final crmTargetsProvider = FutureProvider.family<List<TargetRow>, String>((
  ref,
  month,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(crmRevisionProvider);
  return ref.watch(crmRepositoryProvider).targets(month);
});

class CrmRepository {
  CrmRepository(this._api);

  final ApiClient _api;

  static const _b = '/crm';

  Map<String, dynamic> _owner(String? owner) => {
    if (owner != null && owner.isNotEmpty) 'ownerId': owner,
  };

  Future<TodayData> today(String? owner) async =>
      TodayData.fromJson(await _api.getJson('$_b/today', query: _owner(owner)));

  Future<Pipeline> pipeline(String? owner) async => Pipeline.fromJson(
    await _api.getJson('$_b/pipeline', query: owner == 'all' ? null : _owner(owner)),
  );

  Future<List<CrmStage>> stages() async =>
      asJsonList((await _api.getJson('$_b/stages'))['data'])
          .map(CrmStage.fromJson)
          .toList();

  Future<void> saveStages(List<Json> stages) =>
      _api.patch('$_b/stages', body: {'stages': stages});

  Future<CrmSettings> settings() async =>
      CrmSettings.fromJson(await _api.getJson('$_b/settings'));

  Future<void> saveSettings(Json body) => _api.patch('$_b/settings', body: body);

  Future<List<CrmOwner>> owners() async => [
    for (final o in asJsonList((await _api.getJson('$_b/owners'))['data']))
      CrmOwner(asString(o['id']), asString(o['name'])),
  ];

  Future<List<TargetRow>> targets(String month) async => asJsonList(
    (await _api.getJson('$_b/targets', query: {'month': month}))['rows'],
  ).map(TargetRow.fromJson).toList();

  Future<void> saveTargets(String month, List<Json> rows) =>
      _api.patch('$_b/targets', body: {'month': month, 'rows': rows});

  Future<IndiamartResult> pullIndiamart() async {
    final r = await _api.postJson('$_b/indiamart/pull', body: const {});
    return IndiamartResult(asInt(r['added']), asInt(r['skipped']));
  }

  Future<List<CrmLead>> leads({
    String status = '',
    String source = '',
    String q = '',
    String? owner,
  }) async => (await _api.getPage(
    '$_b/leads',
    CrmLead.fromJson,
    query: {
      if (status.isNotEmpty) 'status': status,
      if (source.isNotEmpty) 'source': source,
      if (q.isNotEmpty) 'q': q,
      ..._owner(owner == 'all' ? null : owner),
      'limit': 100,
    },
  )).data;

  Future<LeadDetail> lead(String id) async =>
      LeadDetail.fromJson(await _api.getJson('$_b/leads/$id'));

  Future<CrmLead> addLead(Json body) async =>
      CrmLead.fromJson(await _api.postJson('$_b/leads', body: body));

  Future<void> convertLead(String id, Json body) =>
      _api.post('$_b/leads/$id/convert', body: body);

  Future<Json> convertLeadResult(String id, Json body) =>
      _api.postJson('$_b/leads/$id/convert', body: body);

  Future<void> loseLead(String id, String reason) =>
      _api.post('$_b/leads/$id/lost', body: {'reason': reason});

  Future<void> reopenLead(String id) =>
      _api.post('$_b/leads/$id/reopen', body: const {});

  Future<List<CrmDeal>> deals({String status = 'open', String? owner}) async =>
      (await _api.getPage(
        '$_b/deals',
        CrmDeal.fromJson,
        query: {
          'status': status,
          ..._owner(owner == 'all' ? null : owner),
          'limit': 200,
        },
      )).data;

  Future<DealDetail> deal(String id) async =>
      DealDetail.fromJson(await _api.getJson('$_b/deals/$id'));

  Future<void> addDeal(Json body) => _api.post('$_b/deals', body: body);

  Future<void> changeStage(String id, String stageId) =>
      _api.post('$_b/deals/$id/stage', body: {'stageId': stageId});

  Future<void> winDeal(String id, double? value) =>
      _api.post('$_b/deals/$id/won', body: {'value': ?value});

  Future<void> loseDeal(String id, String reason) =>
      _api.post('$_b/deals/$id/lost', body: {'reason': reason});

  Future<void> reopenDeal(String id) =>
      _api.post('$_b/deals/$id/reopen', body: const {});

  Future<void> addActivity(Json body) => _api.post('$_b/activities', body: body);

  Future<void> markDone(String id, Json body) =>
      _api.post('$_b/activities/$id/done', body: body);

  Future<PartyOverview> overview(String partyId) async =>
      PartyOverview.fromJson(await _api.getJson('$_b/parties/$partyId/overview'));

  Future<CrmStats> stats({String from = '', String to = '', String? owner}) async =>
      CrmStats.fromJson(
        await _api.getJson(
          '$_b/stats',
          query: {
            if (from.isNotEmpty) 'from': from,
            if (to.isNotEmpty) 'to': to,
            ..._owner(owner),
          },
        ),
      );
}
