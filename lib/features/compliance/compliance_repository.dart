import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'compliance_models.dart';

/// Bumped after a statutory write so lists and details reload.
final complianceRevisionProvider = NotifierProvider<ComplianceRevision, int>(
  ComplianceRevision.new,
);

class ComplianceRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

class AccountOption {
  const AccountOption({
    required this.id,
    required this.code,
    required this.name,
    this.subtype = '',
  });

  factory AccountOption.fromJson(Json j) => AccountOption(
    id: asString(j['id']),
    code: asString(j['code']),
    name: asString(j['name']),
    subtype: asString(j['subtype']),
  );

  final String id;
  final String code;
  final String name;
  final String subtype;

  String get label => '$code · $name';
}

class PurchaseOption {
  const PurchaseOption({
    required this.id,
    required this.number,
    required this.partyName,
    required this.supplierInvoiceNo,
    required this.total,
    required this.billDate,
  });

  factory PurchaseOption.fromJson(Json j) => PurchaseOption(
    id: asString(j['id']),
    number: asString(j['number']),
    partyName: asString(j['partyName']),
    supplierInvoiceNo: asString(j['supplierInvoiceNo']),
    total: asDouble(j['total']),
    billDate: asString(j['billDate']),
  );

  final String id;
  final String number;
  final String partyName;
  final String supplierInvoiceNo;
  final double total;
  final String billDate;
}

final complianceRepositoryProvider = Provider<ComplianceRepository>(
  (ref) => ComplianceRepository(ref.watch(apiClientProvider)),
);

/// Re-runs a provider when the company or a statutory write changes.
extension _Watch on Ref {
  void base() {
    watch(activeCompanyIdProvider);
    watch(complianceRevisionProvider);
  }
}

final gstr1Provider = FutureProvider.autoDispose.family<Gstr1, String>((
  ref,
  period,
) {
  ref.base();
  return ref.watch(complianceRepositoryProvider).gstr1(period);
});

final gstr3bProvider = FutureProvider.autoDispose.family<Gstr3b, String>((
  ref,
  period,
) {
  ref.base();
  return ref.watch(complianceRepositoryProvider).gstr3b(period);
});

final reconProvider = FutureProvider.autoDispose.family<Recon, String>((
  ref,
  period,
) {
  ref.base();
  return ref.watch(complianceRepositoryProvider).recon(period);
});

final itcAgeingProvider = FutureProvider.autoDispose<ItcAgeing>((ref) {
  ref.base();
  return ref.watch(complianceRepositoryProvider).itcAgeing();
});

final tdsSummaryProvider = FutureProvider.autoDispose
    .family<TdsSummary, String>((ref, fy) {
      ref.base();
      return ref.watch(complianceRepositoryProvider).tdsSummary(fy);
    });

final tdsChallanProvider = FutureProvider.autoDispose
    .family<TdsChallan, String>((ref, id) {
      ref.base();
      return ref.watch(complianceRepositoryProvider).tdsChallan(id);
    });

final tdsStatementProvider = FutureProvider.autoDispose
    .family<TdsStatement, (String, int)>((ref, key) {
      ref.base();
      return ref
          .watch(complianceRepositoryProvider)
          .tdsStatement(key.$1, key.$2);
    });

final bankStatementProvider = FutureProvider.autoDispose
    .family<BankStatement, String>((ref, id) {
      ref.base();
      return ref.watch(complianceRepositoryProvider).bankStatement(id);
    });

final msmeDuesProvider = FutureProvider.autoDispose.family<MsmeDues, String>((
  ref,
  asOf,
) {
  ref.base();
  return ref.watch(complianceRepositoryProvider).msmeDues(asOf);
});

final complianceDocProvider = FutureProvider.autoDispose
    .family<ComplianceDoc, String>((ref, id) {
      ref.base();
      return ref.watch(complianceRepositoryProvider).doc(id);
    });

final setupHealthProvider = FutureProvider.autoDispose<SetupHealth>((ref) {
  ref.base();
  return ref.watch(complianceRepositoryProvider).health();
});

/// Cash, bank and (with [subtype] `null`) every active account.
final accountOptionsProvider = FutureProvider.autoDispose<List<AccountOption>>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(revisionProvider(DataKind.accounts));
  return ref.watch(complianceRepositoryProvider).accounts();
});

/// Alerts for the dashboard; `null` when hidden (403 or none).
final alertsProvider = FutureProvider.autoDispose<List<Alert>>((ref) async {
  ref.base();
  try {
    return await ref.watch(complianceRepositoryProvider).alerts();
  } catch (_) {
    return const [];
  }
});

class ComplianceRepository {
  ComplianceRepository(this._api);

  final ApiClient _api;

  Future<Gstr1> gstr1(String period) async => Gstr1.fromJson(
    await _api.getJson('/gst/gstr1', query: {'period': period}),
  );

  Future<String> gstr1Gstn(String period) =>
      _api.getText('/gst/gstr1', query: {'period': period, 'format': 'gstn'});

  Future<Gstr3b> gstr3b(String period) async => Gstr3b.fromJson(
    await _api.getJson('/gst/gstr3b', query: {'period': period}),
  );

  Future<Recon> recon(String period) async => Recon.fromJson(
    await _api.getJson('/gst/2b-recon', query: {'period': period}),
  );

  /// Exactly one of [data] (parsed GSTR-2B JSON) or [csv].
  Future<Json> import2b({
    required String period,
    String? fileName,
    Object? data,
    String? csv,
  }) => _api.postJson(
    '/gst/2b-imports',
    body: withoutNulls({
      'period': period,
      'fileName': fileName,
      'data': data,
      'csv': csv,
    }),
  );

  Future<ReconRow> patch2bLine(String id, Json body) async =>
      ReconRow.fromJson(await _api.patchJson('/gst/2b-lines/$id', body: body));

  Future<ItcAgeing> itcAgeing() async =>
      ItcAgeing.fromJson(await _api.getJson('/gst/itc-ageing'));

  // ---- TDS

  Future<Paged<TdsDeduction>> tdsDeductions({
    String? fy,
    int? quarter,
    String? sectionCode,
    bool notDeposited = false,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/tds/deductions',
    TdsDeduction.fromJson,
    query: {
      'fy': ?fy,
      'quarter': ?quarter,
      if (sectionCode != null && sectionCode.isNotEmpty)
        'sectionCode': sectionCode,
      if (notDeposited) 'challan': 'none',
      'status': 'active',
      'offset': offset,
      'limit': limit,
    },
  );

  Future<TdsSummary> tdsSummary(String fy) async => TdsSummary.fromJson(
    await _api.getJson('/tds/summary', query: {'fy': fy}),
  );

  Future<Paged<TdsChallan>> tdsChallans({String? fy}) =>
      _api.getPage('/tds/challans', TdsChallan.fromJson, query: {'fy': ?fy});

  Future<TdsChallan> tdsChallan(String id) async =>
      TdsChallan.fromJson(await _api.getJson('/tds/challans/$id'));

  Future<TdsChallan> createChallan(Json body) async =>
      TdsChallan.fromJson(await _api.postJson('/tds/challans', body: body));

  Future<TdsChallan> cancelChallan(String id, String reason) async =>
      TdsChallan.fromJson(
        await _api.postJson(
          '/tds/challans/$id/cancel',
          body: {'reason': reason},
        ),
      );

  Future<TdsStatement> tdsStatement(String fy, int quarter) async =>
      TdsStatement.fromJson(
        await _api.getJson(
          '/tds/statement',
          query: {'fy': fy, 'quarter': quarter, 'format': 'json'},
        ),
      );

  Future<String> tdsStatementCsv(String fy, int quarter) => _api.getText(
    '/tds/statement',
    query: {'fy': fy, 'quarter': quarter, 'format': 'csv'},
  );

  // ---- Bank reconciliation

  Future<Paged<BankStatement>> bankStatements() =>
      _api.getPage('/bank-statements', BankStatement.fromJson);

  Future<BankStatement> importStatement({
    required String accountId,
    required String csv,
    String? fileName,
  }) async => BankStatement.fromJson(
    await _api.postJson(
      '/bank-statements',
      body: withoutNulls({
        'accountId': accountId,
        'fileName': fileName,
        'csv': csv,
      }),
    ),
  );

  Future<BankStatement> bankStatement(String id) async =>
      BankStatement.fromJson(await _api.getJson('/bank-statements/$id'));

  Future<int> autoMatch(String id) async => asInt(
    (await _api.postJson('/bank-statements/$id/auto-match'))['matched'],
  );

  Future<List<BankCandidate>> candidates(String lineId) async => asJsonList(
    (await _api.getJson('/bank-lines/$lineId/candidates'))['data'],
  ).map(BankCandidate.fromJson).toList();

  Future<BankLine> matchLine(String lineId, String journalLineId) async =>
      BankLine.fromJson(
        await _api.postJson(
          '/bank-lines/$lineId/match',
          body: {'journalLineId': journalLineId},
        ),
      );

  Future<BankLine> lineAction(String lineId, String action) async =>
      BankLine.fromJson(await _api.postJson('/bank-lines/$lineId/$action'));

  Future<BankLine> createEntry(String lineId, Json body) async =>
      BankLine.fromJson(
        await _api.postJson('/bank-lines/$lineId/create-entry', body: body),
      );

  // ---- Compliance

  Future<MsmeDues> msmeDues(String asOf) async => MsmeDues.fromJson(
    await _api.getJson('/reports/msme-dues', query: {'asOf': asOf}),
  );

  Future<Paged<ComplianceDoc>> docs({
    String? status,
    String? category,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/compliance-docs',
    ComplianceDoc.fromJson,
    query: {
      'status': ?status,
      'category': ?category,
      'page': offset ~/ limit + 1,
      'pageSize': limit,
    },
  );

  Future<ComplianceDoc> doc(String id) async =>
      ComplianceDoc.fromJson(await _api.getJson('/compliance-docs/$id'));

  Future<ComplianceDoc> saveDoc(String? id, Json body) async =>
      ComplianceDoc.fromJson(
        id == null
            ? await _api.postJson('/compliance-docs', body: body)
            : await _api.patchJson('/compliance-docs/$id', body: body),
      );

  Future<List<Alert>> alerts() async => asJsonList(
    (await _api.getJson('/compliance/alerts', query: {'days': 30}))['data'],
  ).map(Alert.fromJson).toList();

  Future<SetupHealth> health() async =>
      SetupHealth.fromJson(await _api.getJson('/setup/health'));

  Future<String> exportCsv(String dataset, {String? from, String? to}) =>
      _api.getText('/export/$dataset', query: {'from': ?from, 'to': ?to});

  // ---- Pickers

  Future<List<AccountOption>> accounts() async {
    final page = await _api.getPage(
      '/accounts',
      AccountOption.fromJson,
      query: {'activeOnly': true, 'limit': 500},
    );
    return page.data;
  }

  Future<List<PurchaseOption>> purchases({String? q, String? partyId}) async {
    final page = await _api.getPage(
      '/purchases',
      PurchaseOption.fromJson,
      query: {
        if (q != null && q.isNotEmpty) 'q': q,
        'partyId': ?partyId,
        'limit': 30,
      },
    );
    return page.data;
  }
}

final tdsChallansProvider = FutureProvider.autoDispose
    .family<List<TdsChallan>, String>((ref, fy) async {
      ref.base();
      return (await ref.watch(complianceRepositoryProvider).tdsChallans(fy: fy))
          .data;
    });

final bankStatementsProvider = FutureProvider.autoDispose<List<BankStatement>>((
  ref,
) async {
  ref.base();
  return (await ref.watch(complianceRepositoryProvider).bankStatements()).data;
});
