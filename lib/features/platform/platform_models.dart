import '../../core/json.dart';

class SecurityInfo {
  const SecurityInfo({
    this.twoFactorEnabled = false,
    this.recoveryCodesLeft = 0,
    this.mustEnrol2fa = false,
    this.twoFactorEnabledAt,
    this.passwordChangedAt,
  });

  factory SecurityInfo.fromJson(Json j) => SecurityInfo(
    twoFactorEnabled: asBool(j['twoFactorEnabled']),
    twoFactorEnabledAt: asStringOrNull(j['twoFactorEnabledAt']),
    recoveryCodesLeft: asInt(j['recoveryCodesLeft']),
    mustEnrol2fa: asBool(j['mustEnrol2fa']),
    passwordChangedAt: asStringOrNull(j['passwordChangedAt']),
  );

  final bool twoFactorEnabled;
  final String? twoFactorEnabledAt;
  final int recoveryCodesLeft;
  final bool mustEnrol2fa;
  final String? passwordChangedAt;
}

class TotpSetup {
  const TotpSetup({required this.secret, required this.otpauthUri});

  factory TotpSetup.fromJson(Json j) => TotpSetup(
    secret: asString(j['secret']),
    otpauthUri: asString(j['otpauthUri']),
  );

  final String secret;
  final String otpauthUri;
}

class UserSession {
  const UserSession({
    required this.id,
    this.userAgent,
    this.ip,
    this.startedAt,
    this.lastUsedAt,
    this.method = 'password',
    this.current = false,
  });

  factory UserSession.fromJson(Json j) => UserSession(
    id: asString(j['id']),
    userAgent: asStringOrNull(j['userAgent']),
    ip: asStringOrNull(j['ip']),
    startedAt: asStringOrNull(j['startedAt']),
    lastUsedAt: asStringOrNull(j['lastUsedAt']),
    method: asString(j['method'], 'password'),
    current: asBool(j['current']),
  );

  final String id;
  final String? userAgent;
  final String? ip;
  final String? startedAt;
  final String? lastUsedAt;
  final String method;
  final bool current;
}

class SsoProvider {
  const SsoProvider({
    required this.id,
    required this.name,
    required this.issuer,
    required this.clientId,
    this.hasClientSecret = false,
    this.emailDomains = const [],
    this.enforce = false,
    this.autoProvision = false,
    this.defaultCompanyId,
    this.defaultRoleId,
    this.isActive = true,
  });

  factory SsoProvider.fromJson(Json j) => SsoProvider(
    id: asString(j['id']),
    name: asString(j['name']),
    issuer: asString(j['issuer']),
    clientId: asString(j['clientId']),
    hasClientSecret: asBool(j['hasClientSecret']),
    emailDomains: asStringList(j['emailDomains']),
    enforce: asBool(j['enforce']),
    autoProvision: asBool(j['autoProvision']),
    defaultCompanyId: asStringOrNull(j['defaultCompanyId']),
    defaultRoleId: asStringOrNull(j['defaultRoleId']),
    isActive: asBool(j['isActive'], true),
  );

  final String id;
  final String name;
  final String issuer;
  final String clientId;
  final bool hasClientSecret;
  final List<String> emailDomains;
  final bool enforce;
  final bool autoProvision;
  final String? defaultCompanyId;
  final String? defaultRoleId;
  final bool isActive;
}

class SsoDiscovery {
  const SsoDiscovery({this.providers = const [], this.enforced = false});

  factory SsoDiscovery.fromJson(Json j) => SsoDiscovery(
    providers: asJsonList(
      j['providers'],
    ).map((p) => (id: asString(p['id']), name: asString(p['name']))).toList(),
    enforced: asBool(j['enforced']),
  );

  final List<({String id, String name})> providers;
  final bool enforced;
}

class Job {
  const Job({
    required this.id,
    required this.kind,
    required this.status,
    this.attempts = 0,
    this.maxAttempts = 3,
    this.error,
    this.createdBy,
    this.createdAt,
    this.finishedAt,
  });

  factory Job.fromJson(Json j) => Job(
    id: asString(j['id']),
    kind: asString(j['kind']),
    status: asString(j['status']),
    attempts: asInt(j['attempts']),
    maxAttempts: asInt(j['maxAttempts'], 3),
    error: asStringOrNull(j['error']),
    createdBy: asStringOrNull(asJsonOrNull(j['createdBy'])?['name']),
    createdAt: asStringOrNull(j['createdAt']),
    finishedAt: asStringOrNull(j['finishedAt']),
  );

  final String id;
  final String kind;
  final String status;
  final int attempts;
  final int maxAttempts;
  final String? error;
  final String? createdBy;
  final String? createdAt;
  final String? finishedAt;
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    this.link,
    this.readAt,
    this.createdAt,
  });

  factory AppNotification.fromJson(Json j) => AppNotification(
    id: asString(j['id']),
    title: asString(j['title']),
    body: asString(j['body']),
    link: asStringOrNull(j['link']),
    readAt: asStringOrNull(j['readAt']),
    createdAt: asStringOrNull(j['createdAt']),
  );

  final String id;
  final String title;
  final String body;
  final String? link;
  final String? readAt;
  final String? createdAt;

  bool get unread => readAt == null;
}

class NotificationPref {
  const NotificationPref({
    required this.template,
    required this.label,
    required this.email,
    this.whatsapp,
    this.mandatory = false,
  });

  factory NotificationPref.fromJson(Json j) => NotificationPref(
    template: asString(j['template']),
    label: asString(j['label']),
    email: asBool(j['email']),
    whatsapp: j['whatsapp'] == null ? null : asBool(j['whatsapp']),
    mandatory: asBool(j['mandatory']),
  );

  final String template;
  final String label;
  final bool email;
  final bool? whatsapp;
  final bool mandatory;
}

class OutboxRow {
  const OutboxRow({
    required this.id,
    required this.channel,
    required this.to,
    required this.template,
    required this.status,
    this.subject,
    this.attempts = 0,
    this.error,
    this.createdAt,
  });

  factory OutboxRow.fromJson(Json j) => OutboxRow(
    id: asString(j['id']),
    channel: asString(j['channel']),
    to: asString(j['to']),
    template: asString(j['template']),
    status: asString(j['status']),
    subject: asStringOrNull(j['subject']),
    attempts: asInt(j['attempts']),
    error: asStringOrNull(j['error']),
    createdAt: asStringOrNull(j['createdAt']),
  );

  final String id;
  final String channel;
  final String to;
  final String template;
  final String status;
  final String? subject;
  final int attempts;
  final String? error;
  final String? createdAt;
}

class CompanyRef {
  const CompanyRef({required this.id, required this.name});

  final String id;
  final String name;
}

class IcSide {
  const IcSide({
    required this.companyId,
    required this.companyName,
    required this.accountName,
  });

  factory IcSide.fromJson(Json j) => IcSide(
    companyId: asString(j['companyId']),
    companyName: asString(j['companyName']),
    accountName: asString(j['accountName']),
  );

  final String companyId;
  final String companyName;
  final String accountName;
}

class IntercompanyEntry {
  const IntercompanyEntry({
    required this.id,
    required this.number,
    required this.date,
    required this.amount,
    required this.narration,
    required this.status,
    required this.from,
    required this.to,
    this.cancelReason,
  });

  factory IntercompanyEntry.fromJson(Json j) => IntercompanyEntry(
    id: asString(j['id']),
    number: asString(j['number']),
    date: asString(j['date']),
    amount: asDouble(j['amount']),
    narration: asString(j['narration']),
    status: asString(j['status']),
    from: IcSide.fromJson(asJson(j['from'])),
    to: IcSide.fromJson(asJson(j['to'])),
    cancelReason: asStringOrNull(j['cancelReason']),
  );

  final String id;
  final String number;
  final String date;
  final double amount;
  final String narration;
  final String status;
  final IcSide from;
  final IcSide to;
  final String? cancelReason;

  bool get cancelled => status == 'cancelled';
}

class IntercompanyBalances {
  const IntercompanyBalances({
    required this.asOf,
    required this.rows,
    required this.accountBalance,
    required this.unexplained,
  });

  factory IntercompanyBalances.fromJson(Json j) => IntercompanyBalances(
    asOf: asString(j['asOf']),
    rows: asJsonList(j['rows'])
        .map(
          (r) => (
            name: asString(r['companyName']),
            balance: asDouble(r['balance']),
          ),
        )
        .toList(),
    accountBalance: asDouble(j['accountBalance']),
    unexplained: asDouble(j['unexplained']),
  );

  final String asOf;
  final List<({String name, double balance})> rows;
  final double accountBalance;
  final double unexplained;
}

/// One line of a consolidated statement.
class ConsolidatedRow {
  const ConsolidatedRow({
    required this.code,
    required this.name,
    required this.byCompany,
    required this.values,
  });

  final String code;
  final String name;
  final Map<String, double> byCompany;

  /// Consolidated figures: `[debit, credit]` for a trial balance, `[amount]`
  /// otherwise.
  final List<double> values;
}

class ConsolidatedSection {
  const ConsolidatedSection(this.title, this.rows, this.totals);

  final String title;
  final List<ConsolidatedRow> rows;

  /// Label → value, e.g. `Total` or `Gross profit`.
  final List<(String, double)> totals;
}

class ConsolidatedReport {
  const ConsolidatedReport({
    required this.companies,
    required this.sections,
    required this.eliminations,
    required this.warnings,
  });

  /// [kind]: `trial-balance`, `profit-loss` or `balance-sheet`.
  factory ConsolidatedReport.fromJson(String kind, Json j) {
    ConsolidatedRow row(Json r, {bool tb = false}) => ConsolidatedRow(
      code: asString(r['code']),
      name: asString(r['name']),
      byCompany: {
        for (final e in asJson(r['byCompany']).entries)
          e.key: asDouble(e.value),
      },
      values: tb
          ? [asDouble(r['debit']), asDouble(r['credit'])]
          : [asDouble(r['amount'])],
    );
    ConsolidatedSection section(String title, String key) {
      final s = asJson(j[key]);
      return ConsolidatedSection(
        title,
        asJsonList(s['rows']).map(row).toList(),
        [('Total ${title.toLowerCase()}', asDouble(s['total']))],
      );
    }

    final List<ConsolidatedSection> sections;
    switch (kind) {
      case 'trial-balance':
        sections = [
          ConsolidatedSection(
            'Accounts',
            asJsonList(j['rows']).map((r) => row(r, tb: true)).toList(),
            [
              ('Total debit', asDouble(j['totalDebit'])),
              ('Total credit', asDouble(j['totalCredit'])),
            ],
          ),
        ];
      case 'profit-loss':
        sections = [
          section('Revenue', 'revenue'),
          section('Cost of goods sold', 'cogs'),
          ConsolidatedSection('Gross profit', const [], [
            ('Gross profit', asDouble(j['grossProfit'])),
          ]),
          section('Other income', 'otherIncome'),
          section('Expenses', 'expenses'),
          ConsolidatedSection('Net profit', const [], [
            ('Net profit', asDouble(j['netProfit'])),
          ]),
        ];
      default:
        sections = [
          section('Assets', 'assets'),
          section('Liabilities', 'liabilities'),
          section('Equity', 'equity'),
          ConsolidatedSection('Check', const [], [
            ('Total assets', asDouble(j['totalAssets'])),
            (
              'Liabilities and equity',
              asDouble(j['totalLiabilitiesAndEquity']),
            ),
          ]),
        ];
    }
    return ConsolidatedReport(
      companies: asJsonList(j['companies'])
          .map(
            (c) => CompanyRef(id: asString(c['id']), name: asString(c['name'])),
          )
          .toList(),
      sections: sections,
      eliminations: asDouble(asJson(j['eliminations'])['intercompany']),
      warnings: asStringList(j['warnings']),
    );
  }

  final List<CompanyRef> companies;
  final List<ConsolidatedSection> sections;
  final double eliminations;
  final List<String> warnings;
}

class GspProviderInfo {
  const GspProviderInfo({
    required this.id,
    required this.name,
    this.capabilities = const [],
    this.fields = const [],
  });

  factory GspProviderInfo.fromJson(Json j) => GspProviderInfo(
    id: asString(j['id']),
    name: asString(j['name']),
    capabilities: asStringList(j['capabilities']),
    fields: asJsonList(j['credentialFields'])
        .map(
          (f) => (
            key: asString(f['key']),
            label: asString(f['label']),
            secret: asBool(f['secret']),
          ),
        )
        .toList(),
  );

  final String id;
  final String name;
  final List<String> capabilities;
  final List<({String key, String label, bool secret})> fields;
}

class GspSettings {
  const GspSettings({
    required this.mode,
    this.provider,
    this.providers = const [],
    this.credentials = const {},
    this.savedSecrets = const [],
  });

  factory GspSettings.fromJson(Json j) => GspSettings(
    mode: asString(j['mode'], 'manual'),
    provider: asStringOrNull(j['provider']),
    providers: asJsonList(
      j['providers'],
    ).map(GspProviderInfo.fromJson).toList(),
    credentials: {
      for (final e in asJson(j['credentials']).entries)
        e.key: asStringOrNull(e.value),
    },
    savedSecrets: asStringList(j['savedSecrets']),
  );

  final String mode;
  final String? provider;
  final List<GspProviderInfo> providers;
  final Map<String, String?> credentials;
  final List<String> savedSecrets;

  GspProviderInfo? get providerInfo {
    for (final p in providers) {
      if (p.id == provider) return p;
    }
    return null;
  }
}

class GspSubmission {
  const GspSubmission({
    required this.id,
    required this.period,
    required this.provider,
    required this.reference,
    required this.status,
    this.createdAt,
  });

  factory GspSubmission.fromJson(Json j) => GspSubmission(
    id: asString(j['id']),
    period: asString(j['period']),
    provider: asString(j['provider']),
    reference: asString(j['reference']),
    status: asString(j['status']),
    createdAt: asStringOrNull(j['createdAt']),
  );

  final String id;
  final String period;
  final String provider;
  final String reference;
  final String status;
  final String? createdAt;
}
