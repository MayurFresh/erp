import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';

// Models -------------------------------------------------------------------

class SearchItem {
  const SearchItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.route,
  });

  factory SearchItem.fromJson(Json j) => SearchItem(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    subtitle: j['subtitle'] as String? ?? '',
    route: j['route'] as String? ?? '/',
  );

  final String id;
  final String title;
  final String subtitle;
  final String route;
}

class SearchGroup {
  const SearchGroup({
    required this.kind,
    required this.label,
    required this.items,
  });

  factory SearchGroup.fromJson(Json j) => SearchGroup(
    kind: j['kind'] as String,
    label: j['label'] as String? ?? '',
    items: asJsonList(j['items']).map(SearchItem.fromJson).toList(),
  );

  final String kind;
  final String label;
  final List<SearchItem> items;
}

class ScheduledReport {
  const ScheduledReport({
    this.id,
    required this.name,
    required this.report,
    this.reportLabel = '',
    this.period,
    required this.frequency,
    this.weekday,
    this.monthDay,
    required this.time,
    this.recipientEmails = const [],
    this.recipientUserIds = const [],
    this.isActive = true,
    this.nextRunAt,
    this.lastRunAt,
  });

  factory ScheduledReport.fromJson(Json j) => ScheduledReport(
    id: j['id'] as String?,
    name: j['name'] as String? ?? '',
    report: j['report'] as String? ?? 'sales_register',
    reportLabel: j['reportLabel'] as String? ?? '',
    period: (j['filters'] as Map?)?['period'] as String?,
    frequency: j['frequency'] as String? ?? 'daily',
    weekday: (j['weekday'] as num?)?.toInt(),
    monthDay: (j['monthDay'] as num?)?.toInt(),
    time: j['time'] as String? ?? '08:00',
    recipientEmails: [
      for (final e in (j['recipientEmails'] as List? ?? const [])) '$e',
    ],
    recipientUserIds: [
      for (final e in (j['recipientUserIds'] as List? ?? const [])) '$e',
    ],
    isActive: j['isActive'] as bool? ?? true,
    nextRunAt: DateTime.tryParse('${j['nextRunAt'] ?? ''}')?.toLocal(),
    lastRunAt: DateTime.tryParse('${j['lastRunAt'] ?? ''}')?.toLocal(),
  );

  final String? id;
  final String name;
  final String report;
  final String reportLabel;
  final String? period;
  final String frequency;
  final int? weekday;
  final int? monthDay;
  final String time;
  final List<String> recipientEmails;
  final List<String> recipientUserIds;
  final bool isActive;
  final DateTime? nextRunAt;
  final DateTime? lastRunAt;

  Json toJson() => {
    'name': name,
    'report': report,
    'filters': {if (period != null) 'period': period},
    'frequency': frequency,
    if (frequency == 'weekly') 'weekday': weekday ?? 1,
    if (frequency == 'monthly') 'monthDay': monthDay ?? 1,
    'time': time,
    'recipientEmails': recipientEmails,
    'recipientUserIds': recipientUserIds,
    'isActive': isActive,
  };

  String get when {
    const days = [
      'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
    ];
    return switch (frequency) {
      'weekly' => 'Every ${days[(weekday ?? 1) % 7]} at $time',
      'monthly' => 'On day ${monthDay ?? 1} of each month at $time',
      _ => 'Every day at $time',
    };
  }
}

class ReportRun {
  const ReportRun({
    required this.trigger,
    required this.status,
    required this.recipients,
    required this.rowCount,
    this.error,
    this.ranAt,
  });

  factory ReportRun.fromJson(Json j) => ReportRun(
    trigger: j['trigger'] as String? ?? 'schedule',
    status: j['status'] as String? ?? 'sent',
    recipients: (j['recipients'] as num?)?.toInt() ?? 0,
    rowCount: (j['rowCount'] as num?)?.toInt() ?? 0,
    error: j['error'] as String?,
    ranAt: DateTime.tryParse('${j['ranAt'] ?? ''}')?.toLocal(),
  );

  final String trigger;
  final String status;
  final int recipients;
  final int rowCount;
  final String? error;
  final DateTime? ranAt;
}

class CatalogueReport {
  const CatalogueReport(this.key, this.label, this.allowed);
  final String key;
  final String label;
  final bool allowed;
}

class SmsTemplateSetting {
  const SmsTemplateSetting({
    required this.template,
    required this.label,
    this.dltTemplateId,
    this.text,
  });

  factory SmsTemplateSetting.fromJson(Json j) => SmsTemplateSetting(
    template: j['template'] as String,
    label: j['label'] as String? ?? '',
    dltTemplateId: j['dltTemplateId'] as String?,
    text: j['text'] as String?,
  );

  final String template;
  final String label;
  final String? dltTemplateId;
  final String? text;
}

class SmsSettings {
  const SmsSettings({
    required this.driver,
    required this.enabled,
    this.dltEntityId,
    this.senderId,
    this.templates = const [],
  });

  factory SmsSettings.fromJson(Json j) => SmsSettings(
    driver: j['driver'] as String? ?? 'log',
    enabled: j['enabled'] as bool? ?? false,
    dltEntityId: j['dltEntityId'] as String?,
    senderId: j['senderId'] as String?,
    templates: asJsonList(j['templates']).map(SmsTemplateSetting.fromJson).toList(),
  );

  final String driver;
  final bool enabled;
  final String? dltEntityId;
  final String? senderId;
  final List<SmsTemplateSetting> templates;
}

class GatewayField {
  const GatewayField(this.key, this.label, this.secret, this.isSet);
  final String key;
  final String label;
  final bool secret;
  final bool isSet;
}

class GatewaySettings {
  const GatewaySettings({
    required this.isActive,
    this.accountId,
    this.mode,
    this.fields = const [],
    this.webhookUrl,
  });

  factory GatewaySettings.fromJson(Json j) => GatewaySettings(
    isActive: j['isActive'] as bool? ?? false,
    accountId: j['accountId'] as String?,
    mode: j['mode'] as String?,
    webhookUrl: j['webhookUrl'] as String?,
    fields: [
      for (final f in asJsonList(j['credentials']))
        GatewayField(
          f['key'] as String,
          f['label'] as String? ?? '',
          f['secret'] as bool? ?? false,
          f['set'] as bool? ?? false,
        ),
    ],
  );

  final bool isActive;
  final String? accountId;
  final String? mode;
  final List<GatewayField> fields;
  final String? webhookUrl;
}

class PaymentLink {
  const PaymentLink({
    required this.id,
    required this.invoiceId,
    required this.invoiceNumber,
    required this.partyName,
    required this.amount,
    required this.status,
    this.shortUrl,
    this.whatsappUrl,
    this.expiresAt,
    this.paidAt,
    this.fee = 0,
    this.error,
  });

  factory PaymentLink.fromJson(Json j) => PaymentLink(
    id: j['id'] as String,
    invoiceId: j['invoiceId'] as String? ?? '',
    invoiceNumber: j['invoiceNumber'] as String? ?? '',
    partyName: j['partyName'] as String? ?? '',
    amount: (j['amount'] as num?)?.toDouble() ?? 0,
    status: j['status'] as String? ?? 'created',
    shortUrl: j['shortUrl'] as String?,
    whatsappUrl: j['whatsappUrl'] as String?,
    expiresAt: DateTime.tryParse('${j['expiresAt'] ?? ''}')?.toLocal(),
    paidAt: DateTime.tryParse('${j['paidAt'] ?? ''}')?.toLocal(),
    fee: (j['fee'] as num?)?.toDouble() ?? 0,
    error: j['error'] as String?,
  );

  final String id;
  final String invoiceId;
  final String invoiceNumber;
  final String partyName;
  final double amount;
  final String status;
  final String? shortUrl;
  final String? whatsappUrl;
  final DateTime? expiresAt;
  final DateTime? paidAt;
  final double fee;
  final String? error;

  String get statusLabel => switch (status) {
    'created' => 'Waiting for payment',
    'paid' => 'Paid',
    'expired' => 'Expired',
    'cancelled' => 'Cancelled',
    _ => 'Failed',
  };
}

// Repository ---------------------------------------------------------------

final extrasRepositoryProvider = Provider<ExtrasRepository>(
  (ref) => ExtrasRepository(ref.watch(apiClientProvider)),
);

/// Bumped after any write so lists reload.
final extrasRevisionProvider = NotifierProvider<ExtrasRevision, int>(
  ExtrasRevision.new,
);

class ExtrasRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final searchResultsProvider = FutureProvider.autoDispose
    .family<List<SearchGroup>, String>((ref, q) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(extrasRepositoryProvider).search(q);
    });

final scheduledReportsProvider =
    FutureProvider.autoDispose<List<ScheduledReport>>((ref) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(extrasRevisionProvider);
      return ref.watch(extrasRepositoryProvider).reports();
    });

final reportRunsProvider = FutureProvider.autoDispose
    .family<List<ReportRun>, String>((ref, id) {
      ref.watch(extrasRevisionProvider);
      return ref.watch(extrasRepositoryProvider).runs(id);
    });

final smsSettingsProvider = FutureProvider.autoDispose<SmsSettings>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(extrasRevisionProvider);
  return ref.watch(extrasRepositoryProvider).smsSettings();
});

final gatewaySettingsProvider = FutureProvider.autoDispose<GatewaySettings>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(extrasRevisionProvider);
  return ref.watch(extrasRepositoryProvider).gateway();
});

final paymentLinksProvider = FutureProvider.autoDispose
    .family<List<PaymentLink>, String?>((ref, status) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(extrasRevisionProvider);
      return ref.watch(extrasRepositoryProvider).links(status: status);
    });

class ExtrasRepository {
  ExtrasRepository(this._api);
  final ApiClient _api;

  Future<List<SearchGroup>> search(String q) async => asJsonList(
    (await _api.getJson('/search', query: {'q': q, 'limit': 8}))['groups'],
  ).map(SearchGroup.fromJson).toList();

  Future<List<ScheduledReport>> reports() async => asJsonList(
    (await _api.getJson('/scheduled-reports'))['data'],
  ).map(ScheduledReport.fromJson).toList();

  Future<List<CatalogueReport>> catalogue() async => asJsonList(
    (await _api.getJson('/scheduled-reports/catalogue'))['data'],
  ).map((j) => CatalogueReport(j['key'] as String, j['label'] as String, j['allowed'] as bool? ?? true)).toList();

  Future<ScheduledReport> saveReport(ScheduledReport r) async =>
      ScheduledReport.fromJson(
        r.id == null
            ? await _api.postJson('/scheduled-reports', body: r.toJson())
            : await _api.patchJson('/scheduled-reports/${r.id}', body: r.toJson()),
      );

  Future<void> deleteReport(String id) async {
    await _api.delete('/scheduled-reports/$id');
  }

  Future<ReportRun> runReport(String id) async =>
      ReportRun.fromJson(await _api.postJson('/scheduled-reports/$id/run'));

  Future<List<ReportRun>> runs(String id) async => asJsonList(
    (await _api.getJson('/scheduled-reports/$id/runs'))['data'],
  ).map(ReportRun.fromJson).toList();

  Future<SmsSettings> smsSettings() async =>
      SmsSettings.fromJson(await _api.getJson('/sms/settings'));

  Future<SmsSettings> saveSms(Json body) async =>
      SmsSettings.fromJson(await _api.patchJson('/sms/settings', body: body));

  Future<void> testSms(String phone) async {
    await _api.postJson('/sms/test', body: {'phone': phone});
  }

  Future<GatewaySettings> gateway() async {
    final list = asJsonList((await _api.getJson('/payment-gateways'))['data']);
    return GatewaySettings.fromJson(list.isEmpty ? <String, dynamic>{} : list.first);
  }

  Future<GatewaySettings> saveGateway(Json body) async =>
      GatewaySettings.fromJson(
        await _api.patchJson('/payment-gateways/razorpay', body: body),
      );

  Future<List<PaymentLink>> links({String? status, String? invoiceId}) async =>
      asJsonList(
        (await _api.getJson(
          '/payment-links',
          query: {'status': status, 'invoiceId': invoiceId, 'limit': 100},
        ))['data'],
      ).map(PaymentLink.fromJson).toList();

  Future<PaymentLink> createLink(String invoiceId, {int days = 7}) async =>
      PaymentLink.fromJson(
        await _api.postJson(
          '/invoices/$invoiceId/payment-links',
          body: {'expiresInDays': days},
        ),
      );

  Future<PaymentLink> cancelLink(String id) async =>
      PaymentLink.fromJson(await _api.postJson('/payment-links/$id/cancel'));

  Future<int> sendLink(String id, List<String> channels) async =>
      ((await _api.postJson('/payment-links/$id/send', body: {'channels': channels}))['queued'] as num?)?.toInt() ?? 0;
}
