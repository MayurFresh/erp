import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';

final tdsFormsRepositoryProvider = Provider<TdsFormsRepository>(
  (ref) => TdsFormsRepository(ref.watch(apiClientProvider)),
);

/// Query of the section map: the date the references are shown for.
final sectionMapProvider = FutureProvider.autoDispose.family<Json, String>((
  ref,
  date,
) {
  ref.watch(activeCompanyIdProvider);
  return ref.watch(tdsFormsRepositoryProvider).sectionMap(date);
});

/// (kind, fy, quarter): issued certificates. Quarter is 0 for salary.
typedef CertQuery = (String kind, String fy, int quarter);

final certificatesProvider = FutureProvider.autoDispose
    .family<List<Json>, CertQuery>((ref, q) {
      ref.watch(activeCompanyIdProvider);
      return ref
          .watch(tdsFormsRepositoryProvider)
          .certificates(q.$1, q.$2, q.$3);
    });

/// (kind, fy, quarter): return data with its checks.
final tdsReturnProvider = FutureProvider.autoDispose
    .family<Json, (String, String, int)>((ref, q) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(tdsFormsRepositoryProvider).tdsReturn(q.$1, q.$2, q.$3);
    });

class TdsFormsRepository {
  TdsFormsRepository(this._api);

  final ApiClient _api;

  Future<Json> sectionMap(String date) =>
      _api.getJson('/tds/section-map', query: {'date': date});

  Future<Json> updateMapRow(String id, Json body) =>
      _api.patchJson('/tds/section-map/$id', body: body);

  Future<List<Json>> certificates(String kind, String fy, int quarter) async {
    final res = await _api.getJson(
      '/tds/certificates',
      query: {'kind': kind, 'fy': fy, if (quarter > 0) 'quarter': quarter},
    );
    return asJsonList(res['data']);
  }

  /// Generates (or refreshes) certificates for everyone in the period.
  Future<Json> generate(String kind, String fy, int quarter) =>
      _api.postJson(
        '/tds/certificates/generate',
        body: {'kind': kind, 'fy': fy, if (quarter > 0) 'quarter': quarter},
      );

  Future<Json> tdsReturn(String kind, String fy, int quarter) => _api.getJson(
    '/tds/returns',
    query: {'kind': kind, 'fy': fy, 'quarter': quarter},
  );

  Future<String> tdsReturnCsv(String kind, String fy, int quarter) =>
      _api.getText(
        '/tds/returns',
        query: {'kind': kind, 'fy': fy, 'quarter': quarter, 'format': 'csv'},
      );
}
