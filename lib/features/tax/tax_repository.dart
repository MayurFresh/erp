import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'tax_models.dart';

final taxRepositoryProvider = Provider<TaxRepository>(
  (ref) => TaxRepository(ref.watch(apiClientProvider)),
);

/// Query of the rate pickers: (date, kind, includeLegacy). Records compare by
/// value, so equal queries share one request.
typedef GstRateQuery = (String? date, String? kind, bool includeLegacy);

final gstRatesProvider = FutureProvider.autoDispose
    .family<List<GstRate>, GstRateQuery>((ref, q) {
      ref.watch(activeCompanyIdProvider);
      return ref
          .watch(taxRepositoryProvider)
          .gstRates(date: q.$1, kind: q.$2, includeLegacy: q.$3);
    });

/// Query of the section pickers: (date, activeOnly).
typedef TdsSectionQuery = (String? date, bool activeOnly);

final tdsSectionsProvider = FutureProvider.autoDispose
    .family<List<TdsSection>, TdsSectionQuery>((ref, q) {
      ref.watch(activeCompanyIdProvider);
      return ref
          .watch(taxRepositoryProvider)
          .tdsSections(date: q.$1, activeOnly: q.$2);
    });

class TaxRepository {
  TaxRepository(this._api);

  final ApiClient _api;

  Future<List<GstRate>> gstRates({
    String? date,
    String? kind,
    bool includeLegacy = false,
  }) async {
    final res = await _api.getJson(
      '/gst-rates',
      query: {
        'date': date,
        'kind': kind,
        if (includeLegacy) 'includeLegacy': true,
      },
    );
    return asJsonList(res['data']).map(GstRate.fromJson).toList();
  }

  Future<GstRate> createGstRate(Json body) async =>
      GstRate.fromJson(await _api.postJson('/gst-rates', body: body));

  Future<GstRate> updateGstRate(String id, Json body) async =>
      GstRate.fromJson(await _api.patchJson('/gst-rates/$id', body: body));

  Future<List<TdsSection>> tdsSections({
    String? date,
    bool activeOnly = false,
  }) async {
    final res = await _api.getJson(
      '/tds-sections',
      query: {'date': date, if (activeOnly) 'activeOnly': true},
    );
    return asJsonList(res['data']).map(TdsSection.fromJson).toList();
  }

  Future<TdsSection> createTdsSection(Json body) async =>
      TdsSection.fromJson(await _api.postJson('/tds-sections', body: body));

  Future<TdsSection> updateTdsSection(String id, Json body) async =>
      TdsSection.fromJson(
        await _api.patchJson('/tds-sections/$id', body: body),
      );

  Future<TdsCalc> previewTds({
    required String partyId,
    required String sectionId,
    required String date,
    required double gross,
    String? excludeSourceId,
  }) async => TdsCalc.fromJson(
    await _api.postJson(
      '/tds/preview',
      body: {
        'partyId': partyId,
        'sectionId': sectionId,
        'date': date,
        'gross': gross,
        'excludeSourceId': ?excludeSourceId,
      },
    ),
  );
}
