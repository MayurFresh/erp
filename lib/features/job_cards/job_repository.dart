import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'job_models.dart';

/// Bumped after any job card write so the board and the open job reload.
final jobRevisionProvider = NotifierProvider<JobRevision, int>(JobRevision.new);

class JobRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

extension JobBump on WidgetRef {
  void bumpJobs({bool money = false}) {
    read(jobRevisionProvider.notifier).bump();
    if (money) {
      bump(const [
        DataKind.invoices,
        DataKind.payments,
        DataKind.parties,
        DataKind.stock,
      ]);
    }
  }
}

final jobRepositoryProvider = Provider<JobRepository>(
  (ref) => JobRepository(ref.watch(apiClientProvider)),
);

final jobBoardProvider = FutureProvider.autoDispose
    .family<JobBoard, ({bool mine, String q})>((ref, key) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(jobRevisionProvider);
      return ref.watch(jobRepositoryProvider).board(mine: key.mine, q: key.q);
    });

final jobDetailProvider = FutureProvider.autoDispose.family<JobDetail, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(jobRevisionProvider);
  ref.watchRevisions(const [DataKind.invoices, DataKind.payments]);
  return ref.watch(jobRepositoryProvider).detail(id);
});

final technicianListProvider = FutureProvider.autoDispose<List<Technician>>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  return ref.watch(jobRepositoryProvider).technicians();
});

class JobRepository {
  JobRepository(this._api);

  final ApiClient _api;

  Future<JobBoard> board({bool mine = false, String q = ''}) async =>
      JobBoard.fromJson(
        await _api.getJson(
          '/job-cards',
          query: {
            'open': 'true',
            if (mine) 'mine': 'true',
            if (q.isNotEmpty) 'q': q,
            'limit': 200,
          },
        ),
      );

  Future<JobDetail> detail(String id) async =>
      JobDetail.fromJson(await _api.getJson('/job-cards/$id'));

  Future<JobDetail> create(Json body) async =>
      JobDetail.fromJson(await _api.postJson('/job-cards', body: body));

  Future<JobDetail> update(String id, Json body) async =>
      JobDetail.fromJson(await _api.patchJson('/job-cards/$id', body: body));

  Future<JobDetail> addLine(String id, Json body) async => JobDetail.fromJson(
    await _api.postJson('/job-cards/$id/lines', body: body),
  );

  Future<JobDetail> removeLine(String id, String lineId) async =>
      JobDetail.fromJson(
        asJson(await _api.delete('/job-cards/$id/lines/$lineId')),
      );

  Future<JobDetail> setStatus(String id, Json body) async => JobDetail.fromJson(
    await _api.postJson('/job-cards/$id/status', body: body),
  );

  Future<JobDetail> issueParts(String id) async =>
      JobDetail.fromJson(await _api.postJson('/job-cards/$id/issue', body: {}));

  Future<JobDetail> bill(String id, Json body) async {
    final out = await _api.postJson('/job-cards/$id/bill', body: body);
    return JobDetail.fromJson(asJson(out['job']));
  }

  Future<Json> receipt(String id, Json body) =>
      _api.postJson('/job-cards/$id/receipt', body: body);

  Future<List<Technician>> technicians() async => asJsonList(
    (await _api.getJson('/job-cards/technicians'))['data'],
  ).map(Technician.fromJson).toList();
}
