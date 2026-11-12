import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import 'platform_models.dart';

final platformRepositoryProvider = Provider<PlatformRepository>(
  (ref) => PlatformRepository(ref.watch(apiClientProvider)),
);

/// Calls of the v1.7 enterprise platform that are not about signing in.
class PlatformRepository {
  PlatformRepository(this._api);

  final ApiClient _api;

  // Security and sessions.
  Future<SecurityInfo> security() async =>
      SecurityInfo.fromJson(await _api.getJson('/me/security'));

  Future<TotpSetup> setup2fa() async =>
      TotpSetup.fromJson(await _api.postJson('/me/2fa/setup'));

  Future<List<String>> enable2fa(String code) async => asStringList(
    (await _api.postJson(
      '/me/2fa/enable',
      body: {'code': code},
    ))['recoveryCodes'],
  );

  Future<void> disable2fa(String password, String code) =>
      _api.post('/me/2fa/disable', body: {'password': password, 'code': code});

  Future<List<String>> newRecoveryCodes(String password, String code) async =>
      asStringList(
        (await _api.postJson(
          '/me/2fa/recovery-codes',
          body: {'password': password, 'code': code},
        ))['recoveryCodes'],
      );

  Future<List<UserSession>> sessions() async => asJsonList(
    (await _api.getJson('/me/sessions'))['data'],
  ).map(UserSession.fromJson).toList();

  Future<void> revokeSession(String id) => _api.delete('/me/sessions/$id');

  Future<void> revokeOtherSessions() => _api.post('/me/sessions/revoke-others');

  Future<void> reset2fa(String userId) => _api.post('/users/$userId/2fa/reset');

  Future<void> unlockUser(String userId) => _api.post('/users/$userId/unlock');

  Future<bool> companyRequires2fa() async =>
      asBool((await _api.getJson('/company'))['require2fa']);

  Future<void> setRequire2fa(bool value) =>
      _api.patch('/company', body: {'require2fa': value});

  // SSO providers.
  Future<List<SsoProvider>> ssoProviders() async => asJsonList(
    (await _api.getJson('/sso-providers'))['data'],
  ).map(SsoProvider.fromJson).toList();

  Future<SsoProvider> saveSsoProvider(String? id, Json body) async =>
      SsoProvider.fromJson(
        id == null
            ? await _api.postJson('/sso-providers', body: body)
            : await _api.patchJson('/sso-providers/$id', body: body),
      );

  Future<Json> testSsoProvider(String id) =>
      _api.postJson('/sso-providers/$id/test');

  Future<void> deleteSsoProvider(String id) =>
      _api.delete('/sso-providers/$id');

  // Jobs and outbox.
  Future<Paged<Job>> jobs({String? status, int offset = 0}) => _api.getPage(
    '/jobs',
    Job.fromJson,
    query: {'status': status, 'limit': 50, 'offset': offset},
  );

  Future<void> retryJob(String id) => _api.post('/jobs/$id/retry');

  Future<Paged<OutboxRow>> outbox({
    String? status,
    String? channel,
    int offset = 0,
  }) => _api.getPage(
    '/notifications/outbox',
    OutboxRow.fromJson,
    query: {
      'status': status,
      'channel': channel,
      'limit': 50,
      'offset': offset,
    },
  );

  // Notifications.
  Future<int> unreadCount() async =>
      asInt((await _api.getJson('/notifications/unread-count'))['unread']);

  Future<({List<AppNotification> data, int unread})> notifications({
    bool unreadOnly = false,
  }) async {
    final j = await _api.getJson(
      '/notifications',
      query: {'unread': unreadOnly ? true : null, 'limit': 50},
    );
    return (
      data: asJsonList(j['data']).map(AppNotification.fromJson).toList(),
      unread: asInt(j['unread']),
    );
  }

  Future<void> markRead(String id) => _api.post('/notifications/$id/read');

  Future<void> markAllRead() => _api.post('/notifications/read-all');

  Future<List<NotificationPref>> prefs() async => asJsonList(
    (await _api.getJson('/me/notification-prefs'))['data'],
  ).map(NotificationPref.fromJson).toList();

  Future<List<NotificationPref>> savePref(
    String template, {
    bool? email,
    bool? whatsapp,
  }) async => asJsonList(
    asJson(
      await _api.patch(
        '/me/notification-prefs',
        body: {
          'prefs': [
            {'template': template, 'email': ?email, 'whatsapp': ?whatsapp},
          ],
        },
      ),
    )['data'],
  ).map(NotificationPref.fromJson).toList();

  Future<void> remind(String partyId, String channel) =>
      _api.post('/parties/$partyId/remind', body: {'channel': channel});

  // Companies.
  Future<List<({String id, String name, String? gstin, String stateCode})>>
  companies() async => asJsonList((await _api.getJson('/companies'))['data'])
      .map(
        (c) => (
          id: asString(c['id']),
          name: asString(c['name']),
          gstin: asStringOrNull(c['gstin']),
          stateCode: asString(c['stateCode']),
        ),
      )
      .toList();

  Future<Json> createCompany(Json body) =>
      _api.postJson('/companies', body: body);

  Future<Paged<IntercompanyEntry>> intercompany({
    String? status,
    int offset = 0,
  }) => _api.getPage(
    '/intercompany-entries',
    IntercompanyEntry.fromJson,
    query: {'status': status, 'limit': 50, 'offset': offset},
  );

  Future<IntercompanyEntry> createIntercompany(Json body) async =>
      IntercompanyEntry.fromJson(
        await _api.postJson('/intercompany-entries', body: body),
      );

  Future<void> cancelIntercompany(String id, String reason) =>
      _api.post('/intercompany-entries/$id/cancel', body: {'reason': reason});

  Future<IntercompanyBalances> intercompanyBalances() async =>
      IntercompanyBalances.fromJson(
        await _api.getJson('/reports/intercompany'),
      );

  /// Active accounts of [companyId] (the picker of the inter-company form).
  /// `ApiClient` always sends the active company's header, so it is swapped
  /// for the duration of the call.
  Future<List<({String id, String label})>> accountsOf(String companyId) {
    // Calls queue up so two swaps never overlap and the header is restored.
    final run = _swapLock.then((_) => _accountsOf(companyId));
    _swapLock = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  static Future<void> _swapLock = Future.value();

  Future<List<({String id, String label})>> _accountsOf(
    String companyId,
  ) async {
    final previous = _api.companyId;
    _api.companyId = companyId;
    try {
      final page = await _api.getJson(
        '/accounts',
        query: {'activeOnly': true, 'limit': 200},
      );
      return asJsonList(page['data'])
          .map(
            (a) => (
              id: asString(a['id']),
              label: '${asString(a['code'])} ${asString(a['name'])}',
            ),
          )
          .toList();
    } finally {
      _api.companyId = previous;
    }
  }

  Future<ConsolidatedReport> consolidated(
    String kind,
    List<String> companyIds, {
    String? from,
    String? to,
  }) async => ConsolidatedReport.fromJson(
    kind,
    await _api.getJson(
      '/reports/consolidated/$kind',
      query: {
        'companyIds': companyIds.join(','),
        if (kind == 'profit-loss') ...{'from': from, 'to': to} else 'asOf': to,
      },
    ),
  );

  // GSP.
  Future<GspSettings> gsp() async =>
      GspSettings.fromJson(await _api.getJson('/company/gsp'));

  Future<GspSettings> saveGsp(Json body) async =>
      GspSettings.fromJson(await _api.patchJson('/company/gsp', body: body));

  Future<Json> testGsp() => _api.postJson('/company/gsp/test');

  Future<GspSubmission> uploadGstr1(
    String period, {
    bool force = false,
  }) async => GspSubmission.fromJson(
    await _api.postJson(
      '/gst/gstr1/upload',
      body: {'period': period, if (force) 'acknowledgeFailures': true},
    ),
  );

  Future<List<GspSubmission>> submissions({String? period}) async => asJsonList(
    (await _api.getJson('/gst/submissions', query: {'period': period}))['data'],
  ).map(GspSubmission.fromJson).toList();
}
