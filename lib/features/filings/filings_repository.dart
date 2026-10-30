import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'filing_models.dart';

/// Bumped after a filing is recorded or cancelled.
final filingsRevisionProvider = NotifierProvider<FilingsRevision, int>(
  FilingsRevision.new,
);

class FilingsRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final filingsRepositoryProvider = Provider<FilingsRepository>(
  (ref) => FilingsRepository(ref.watch(apiClientProvider)),
);

final filingCalendarProvider = FutureProvider.autoDispose
    .family<List<FilingCalendarRow>, String>((ref, fy) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(filingsRevisionProvider);
      return ref.watch(filingsRepositoryProvider).calendar(fy);
    });

class FilingsRepository {
  FilingsRepository(this._api);

  final ApiClient _api;

  Future<List<Filing>> list({String? returnType, String? fy}) async {
    final page = await _api.getPage(
      '/filings',
      Filing.fromJson,
      query: {
        if (returnType != null && returnType.isNotEmpty)
          'returnType': returnType,
        if (fy != null && fy.isNotEmpty) 'fy': fy,
      },
    );
    return page.data;
  }

  Future<Filing> create(Map<String, dynamic> body) async =>
      Filing.fromJson(await _api.postJson('/filings', body: body));

  Future<Filing> cancel(String id, String reason) async => Filing.fromJson(
    await _api.postJson('/filings/$id/cancel', body: {'reason': reason}),
  );

  Future<List<FilingCalendarRow>> calendar(String fy) async {
    final j = await _api.getJson('/filings/calendar', query: {'fy': fy});
    return asJsonList(j['rows']).map(FilingCalendarRow.fromJson).toList();
  }
}
