import 'dart:typed_data';

import 'package:dio/dio.dart' show DioMediaType, FormData, MultipartFile;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_client.dart';
import '../../../core/api_exception.dart';
import '../../../core/json.dart';
import '../../../core/providers.dart';
import '../../accounts/account_model.dart';
import '../../auth/session.dart';
import '../../locations/location_model.dart';
import '../../locations/locations_repository.dart';
import '../common/c_revisions.dart';
import '../models/common_models.dart';
import '../models/dpr_models.dart';
import '../models/labour_models.dart';
import '../models/material_models.dart';
import '../models/project_models.dart';
import 'construction_http.dart';
import 'photo_source.dart';

final constructionRepositoryProvider = Provider<ConstructionRepository>(
  (ref) => ConstructionRepository(
    ref.watch(apiClientProvider),
    ref.watch(constructionHttpProvider),
  ),
);

/// All construction endpoints (API v1.2).
class ConstructionRepository {
  ConstructionRepository(this._api, this._http);

  final ApiClient _api;
  final ConstructionHttp _http;

  // ---------------------------------------------------------------- projects

  Future<Paged<Project>> projects({
    String? q,
    ProjectStatus? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/projects',
    Project.fromJson,
    query: {
      'q': q,
      'status': status?.api,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Project> project(String id) async =>
      Project.fromJson(await _api.getJson('/projects/$id'));

  /// [body] as produced by [Project.toInputJson]; nulls are omitted.
  Future<Project> createProject(Json body) async => Project.fromJson(
    await _api.postJson('/projects', body: withoutNulls(body)),
  );

  /// Sends only fields that changed from [original] (`siteIds` compared as
  /// a set); `null` clears an optional field.
  Future<Project> updateProject(Project original, Json body) async {
    final before = original.toInputJson();
    final changes = changedFields(
      Map.of(before)..remove('siteIds'),
      Map.of(body)..remove('siteIds'),
    );
    final oldSites = (before['siteIds'] as List).toSet();
    final newSites = ((body['siteIds'] as List?) ?? const []).toSet();
    if (body.containsKey('siteIds') &&
        (oldSites.length != newSites.length ||
            !oldSites.containsAll(newSites))) {
      changes['siteIds'] = body['siteIds'];
    }
    if (changes.isEmpty) return original;
    return Project.fromJson(
      await _api.patchJson('/projects/${original.id}', body: changes),
    );
  }

  Future<List<BoqLine>> boq(String projectId) async {
    final page = await _api.getPage(
      '/projects/$projectId/boq',
      BoqLine.fromJson,
    );
    return page.data;
  }

  Future<BoqLine> addBoqLine(String projectId, BoqLineInput input) async =>
      BoqLine.fromJson(
        await _api.postJson('/projects/$projectId/boq', body: input.toJson()),
      );

  /// Bulk add (max 500).
  Future<List<BoqLine>> addBoqLines(
    String projectId,
    List<BoqLineInput> lines,
  ) async {
    final json = await _api.postJson(
      '/projects/$projectId/boq',
      body: {
        'lines': [for (final line in lines) line.toJson()],
      },
    );
    return Paged.fromJson(json, BoqLine.fromJson).data;
  }

  /// Sends only the fields that changed from [original].
  Future<BoqLine> updateBoqLine(BoqLine original, BoqLineInput input) async {
    final changes = changedFields(
      original.toInput().toJson(),
      input.toJson(),
    );
    if (changes.isEmpty) return original;
    return BoqLine.fromJson(
      await _api.patchJson('/boq/${original.id}', body: changes),
    );
  }

  /// `409 IN_USE` if a DPR entry, issue or indent line refers to it.
  Future<void> deleteBoqLine(String id) => _http.delete('/boq/$id');

  Future<ProjectCosts> costs(
    String projectId, {
    String? from,
    String? to,
  }) async => ProjectCosts.fromJson(
    await _api.getJson(
      '/projects/$projectId/costs',
      query: {'from': from, 'to': to},
    ),
  );

  // ----------------------------------------------------------------- indents

  Future<Paged<Indent>> indents({
    String? q,
    IndentStatus? status,
    String? locationId,
    String? projectId,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/indents',
    Indent.fromJson,
    query: {
      'q': q,
      'status': status?.name,
      'locationId': locationId,
      'projectId': projectId,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Indent> indent(String id) async =>
      Indent.fromJson(await _api.getJson('/indents/$id'));

  Future<Indent> createIndent(IndentDraft draft) async =>
      Indent.fromJson(await _api.postJson('/indents', body: draft.toJson()));

  Future<Indent> submitIndent(String id) async =>
      Indent.fromJson(await _api.postJson('/indents/$id/submit'));

  /// [approvedQty] is lineId → qty; empty approves the requested qty.
  Future<Indent> approveIndent(
    String id, [
    Map<String, double> approvedQty = const {},
  ]) async => Indent.fromJson(
    await _api.postJson(
      '/indents/$id/approve',
      body: approvedQty.isEmpty
          ? const <String, dynamic>{}
          : {
              'lines': [
                for (final MapEntry(:key, :value) in approvedQty.entries)
                  {'lineId': key, 'approvedQty': value},
              ],
            },
    ),
  );

  Future<Indent> rejectIndent(String id, String reason) async =>
      Indent.fromJson(
        await _api.postJson('/indents/$id/reject', body: {'reason': reason}),
      );

  Future<Indent> closeIndent(String id) async =>
      Indent.fromJson(await _api.postJson('/indents/$id/close'));

  // ------------------------------------------------------------------ issues

  Future<Paged<Issue>> issues({
    String? q,
    String? locationId,
    String? projectId,
    String? boqLineId,
    String? from,
    String? to,
    IssueStatus? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/issues',
    Issue.fromJson,
    query: {
      'q': q,
      'locationId': locationId,
      'projectId': projectId,
      'boqLineId': boqLineId,
      'from': from,
      'to': to,
      'status': status?.name,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Issue> issue(String id) async =>
      Issue.fromJson(await _api.getJson('/issues/$id'));

  /// `409 INSUFFICIENT_STOCK` if the site does not have the stock.
  Future<Issue> createIssue(IssueDraft draft) async =>
      Issue.fromJson(await _api.postJson('/issues', body: draft.toJson()));

  Future<Issue> cancelIssue(String id, String reason) async => Issue.fromJson(
    await _api.postJson('/issues/$id/cancel', body: {'reason': reason}),
  );

  // ------------------------------------------------------------------- files

  /// `POST /files` as `multipart/form-data` (field `file`).
  Future<FileRef> uploadPhoto(PickedPhoto photo) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        photo.bytes,
        filename: photo.name,
        contentType: DioMediaType.parse(photo.mimeType),
      ),
    });
    return FileRef.fromJson(asJson(await _api.post('/files', body: form)));
  }

  Future<Uint8List> fileBytes(String fileId) =>
      _http.getBytes('/files/$fileId');

  // -------------------------------------------------------------------- DPRs

  Future<Paged<Dpr>> dprs({
    String? q,
    String? locationId,
    String? projectId,
    String? from,
    String? to,
    DprStatus? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/dprs',
    Dpr.fromJson,
    query: {
      'q': q,
      'locationId': locationId,
      'projectId': projectId,
      'from': from,
      'to': to,
      'status': status?.name,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Dpr> dpr(String id) async =>
      Dpr.fromJson(await _api.getJson('/dprs/$id'));

  /// `409 CONFLICT` if the site already has a DPR for that date.
  Future<Dpr> createDpr(DprDraft draft) async =>
      Dpr.fromJson(await _api.postJson('/dprs', body: draft.toCreateJson()));

  Future<Dpr> updateDpr(String id, DprDraft draft) async => Dpr.fromJson(
    await _api.patchJson('/dprs/$id', body: draft.toPatchJson()),
  );

  Future<Dpr> submitDpr(String id) async =>
      Dpr.fromJson(await _api.postJson('/dprs/$id/submit'));

  Future<Dpr> approveDpr(String id) async =>
      Dpr.fromJson(await _api.postJson('/dprs/$id/approve'));

  /// The site's latest DPR, or `null` if it has none.
  Future<Dpr?> previousDpr(String locationId) async {
    try {
      return Dpr.fromJson(
        await _api.getJson(
          '/dprs/previous',
          query: {'locationId': locationId},
        ),
      );
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  // ----------------------------------------------------------------- workers

  Future<Paged<Worker>> workers({
    String? q,
    String? siteId,
    String? contractorId,
    Trade? trade,
    bool activeOnly = false,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/workers',
    Worker.fromJson,
    query: {
      'q': q,
      'siteId': siteId,
      'contractorId': contractorId,
      'trade': trade?.api,
      if (activeOnly) 'activeOnly': true,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Worker> worker(String id) async =>
      Worker.fromJson(await _api.getJson('/workers/$id'));

  /// [body] as produced by [Worker.toInputJson]; nulls and `isActive` are
  /// omitted.
  Future<Worker> createWorker(Json body) async => Worker.fromJson(
    await _api.postJson(
      '/workers',
      body: withoutNulls(Map.of(body)..remove('isActive')),
    ),
  );

  Future<Worker> updateWorker(Worker original, Json body) async {
    final changes = changedFields(original.toInputJson(), body);
    if (changes.isEmpty) return original;
    return Worker.fromJson(
      await _api.patchJson('/workers/${original.id}', body: changes),
    );
  }

  // -------------------------------------------------------------- attendance

  Future<AttendanceSheet> attendance(String siteId, String date) async =>
      AttendanceSheet.fromJson(
        await _api.getJson(
          '/attendance',
          query: {'siteId': siteId, 'date': date},
        ),
      );

  /// `PUT /attendance`; `409 LOCKED` inside an approved or paid wage sheet.
  Future<AttendanceSheet> saveAttendance(
    String siteId,
    String date,
    Iterable<AttendanceRow> rows,
  ) async => AttendanceSheet.fromJson(
    await _http.putJson(
      '/attendance',
      body: {
        'siteId': siteId,
        'date': date,
        'entries': [for (final row in rows) ?row.toEntry()],
      },
    ),
  );

  // ------------------------------------------------------------- wage sheets

  Future<Paged<WageSheet>> wageSheets({
    String? q,
    String? siteId,
    WageSheetStatus? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/wage-sheets',
    WageSheet.fromJson,
    query: {
      'q': q,
      'siteId': siteId,
      'status': status?.name,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<WageSheet> wageSheet(String id) async =>
      WageSheet.fromJson(await _api.getJson('/wage-sheets/$id'));

  /// `409` if it overlaps another non-cancelled sheet of the site.
  Future<WageSheet> createWageSheet({
    required String siteId,
    required String from,
    required String to,
  }) async => WageSheet.fromJson(
    await _api.postJson(
      '/wage-sheets',
      body: {'siteId': siteId, 'from': from, 'to': to},
    ),
  );

  /// [advances] is workerId → advance (draft only).
  Future<WageSheet> saveAdvances(
    String id,
    Map<String, double> advances,
  ) async => WageSheet.fromJson(
    await _api.patchJson(
      '/wage-sheets/$id',
      body: {
        'rows': [
          for (final MapEntry(:key, :value) in advances.entries)
            {'workerId': key, 'advance': value},
        ],
      },
    ),
  );

  Future<WageSheet> recomputeWageSheet(String id) async =>
      WageSheet.fromJson(await _api.postJson('/wage-sheets/$id/recompute'));

  Future<WageSheet> approveWageSheet(String id) async =>
      WageSheet.fromJson(await _api.postJson('/wage-sheets/$id/approve'));

  Future<WageSheet> payWageSheet(
    String id, {
    required String paidFromAccountId,
    String? date,
  }) async => WageSheet.fromJson(
    await _api.postJson(
      '/wage-sheets/$id/pay',
      body: withoutNulls({'paidFromAccountId': paidFromAccountId, 'date': date}),
    ),
  );

  Future<WageSheet> cancelWageSheet(String id, String reason) async =>
      WageSheet.fromJson(
        await _api.postJson(
          '/wage-sheets/$id/cancel',
          body: {'reason': reason},
        ),
      );

  // ---------------------------------------------------------------- lookups

  /// Active cash and bank accounts (`GET /accounts?subtype=cash|bank`).
  Future<List<Account>> cashAndBankAccounts() async {
    final results = await Future.wait([
      for (final subtype in const ['cash', 'bank'])
        _api.getPage(
          '/accounts',
          Account.fromJson,
          query: {'subtype': subtype, 'activeOnly': true, 'limit': 200},
        ),
    ]);
    final accounts = [
      for (final page in results) ...page.data.where((a) => a.isCashOrBank),
    ]..sort((a, b) => a.code.compareTo(b.code));
    return accounts;
  }
}

// ------------------------------------------------------------------ providers

ConstructionRepository _repo(Ref ref) =>
    ref.watch(constructionRepositoryProvider);

final projectProvider = FutureProvider.autoDispose.family<Project, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchC(const [CKind.projects, CKind.boq]);
  return _repo(ref).project(id);
});

/// Up to 200 projects in the user's scope (for site → project lookups).
final projectsLookupProvider = FutureProvider.autoDispose<List<Project>>((
  ref,
) async {
  ref.watch(activeCompanyIdProvider);
  ref.watchC(const [CKind.projects]);
  return (await _repo(ref).projects(limit: 200)).data;
});

/// The project a site belongs to (a site is in at most one project).
final projectForSiteProvider = FutureProvider.autoDispose
    .family<Project?, String>((ref, siteId) async {
      final projects = await ref.watch(projectsLookupProvider.future);
      for (final p in projects) {
        if (p.hasSite(siteId)) return p;
      }
      return null;
    });

final boqProvider = FutureProvider.autoDispose.family<List<BoqLine>, String>((
  ref,
  projectId,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchC(const [CKind.boq, CKind.dprs]);
  return _repo(ref).boq(projectId);
});

/// BOQ lines of the project that owns [siteId] (empty if none).
final boqForSiteProvider = FutureProvider.autoDispose
    .family<List<BoqLine>, String>((ref, siteId) async {
      final project = await ref.watch(projectForSiteProvider(siteId).future);
      if (project == null) return const [];
      return ref.watch(boqProvider(project.id).future);
    });

final projectCostsProvider = FutureProvider.autoDispose
    .family<ProjectCosts, String>((ref, projectId) {
      ref.watch(activeCompanyIdProvider);
      ref.watchC(const [CKind.boq, CKind.issues, CKind.wages]);
      ref.watch(revisionProvider(DataKind.expenses));
      return _repo(ref).costs(projectId);
    });

final indentProvider = FutureProvider.autoDispose.family<Indent, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchC(const [CKind.indents]);
  ref.watch(revisionProvider(DataKind.transfers));
  ref.watch(revisionProvider(DataKind.purchases));
  return _repo(ref).indent(id);
});

final issueProvider = FutureProvider.autoDispose.family<Issue, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchC(const [CKind.issues]);
  return _repo(ref).issue(id);
});

final dprProvider = FutureProvider.autoDispose.family<Dpr, String>((ref, id) {
  ref.watch(activeCompanyIdProvider);
  ref.watchC(const [CKind.dprs]);
  return _repo(ref).dpr(id);
});

final workerProvider = FutureProvider.autoDispose.family<Worker, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watchC(const [CKind.workers]);
  return _repo(ref).worker(id);
});

final wageSheetProvider = FutureProvider.autoDispose.family<WageSheet, String>(
  (ref, id) {
    ref.watch(activeCompanyIdProvider);
    ref.watchC(const [CKind.wages]);
    return _repo(ref).wageSheet(id);
  },
);

/// Bytes of an uploaded file (photo thumbnails), fetched with auth.
final fileBytesProvider = FutureProvider.autoDispose.family<Uint8List, String>(
  (ref, fileId) => _repo(ref).fileBytes(fileId),
);

final payAccountsProvider = FutureProvider.autoDispose<List<Account>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(revisionProvider(DataKind.accounts));
  return _repo(ref).cashAndBankAccounts();
});

/// Locations of type `site` in the user's scope, active first. Falls back
/// to the sites of visible projects when locations cannot be listed.
final sitesProvider = FutureProvider.autoDispose<List<NamedRef>>((ref) async {
  try {
    final locations = await ref.watch(locationsLookupProvider.future);
    return _sites(locations, const {'site'});
  } catch (_) {
    final projects = await ref.watch(projectsLookupProvider.future);
    final seen = <String>{};
    return [
      for (final p in projects)
        for (final s in p.sites)
          if (seen.add(s.id)) s,
    ];
  }
});

/// Sites and stores (where an indent may deliver).
final indentLocationsProvider = FutureProvider.autoDispose<List<NamedRef>>((
  ref,
) async {
  try {
    final locations = await ref.watch(locationsLookupProvider.future);
    return _sites(locations, const {'site', 'store', 'warehouse'});
  } catch (_) {
    return ref.watch(sitesProvider.future);
  }
});

List<NamedRef> _sites(List<Location> locations, Set<String> types) => [
  for (final l in locations)
    if (types.contains(l.type) && l.isActive)
      NamedRef(id: l.id, name: l.displayName),
];
