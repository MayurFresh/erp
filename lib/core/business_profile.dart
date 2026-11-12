import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/session.dart';
import '../features/business/business_repository.dart';
import '../features/company/company_model.dart';

/// A module that can be switched off. Keys match `GET /business-types`.
/// To add one: add it here and to `backend/src/lib/business-types.ts`.
class ModuleDef {
  const ModuleDef(
    this.key,
    this.label,
    this.description, {
    this.indiaOnly = false,
  });

  final String key;
  final String label;
  final String description;
  final bool indiaOnly;
}

const List<ModuleDef> kModules = [
  ModuleDef(
    'sales',
    'Sales',
    'Invoices, credit notes, receipts and sales orders',
  ),
  ModuleDef(
    'fulfilment',
    'Fulfilment',
    'Pick lists, shipments and sales returns',
  ),
  ModuleDef(
    'purchases',
    'Purchases',
    'Purchase orders, bills, payments and expenses',
  ),
  ModuleDef('inventory', 'Stock', 'Stock, transfers, reorder and stock counts'),
  ModuleDef(
    'construction',
    'Construction',
    'Projects, BOQ, site reports, labour and subcontracts',
  ),
  ModuleDef(
    'pos',
    'Counter billing',
    'Register sessions, fast counter sales, split payments, returns and receipts',
  ),
  ModuleDef(
    'real_estate',
    'Real estate sales',
    'Units, bookings, demands and RERA',
  ),
  ModuleDef(
    'clinic',
    'Patient care',
    'Patients, doctors, appointments, consultations and prescriptions',
  ),
  ModuleDef(
    'funds',
    'Funds and budgets',
    'Funds and schemes, budget heads, sanctions, spending control and utilisation certificates',
  ),
  ModuleDef(
    'donations',
    'Donations',
    'Donors, donation receipts with 80G, donor statements and Form 10BD data',
  ),
  ModuleDef(
    'memberships',
    'Memberships',
    'Plans, members, renewals, recurring bills, dues and check-in',
  ),
  ModuleDef(
    'job_cards',
    'Job cards',
    'Repair intake, estimates, parts and labour, status and job bills',
  ),
  ModuleDef(
    'hotel',
    'Hotel front office',
    'Rooms, rates, reservations, check-in and out, folios and housekeeping',
  ),
  ModuleDef(
    'education',
    'Students and fees',
    'Admissions, classes or batches, fee plans, fee collection and attendance',
  ),
  ModuleDef(
    'legal',
    'Legal practice',
    'Matters, court diary, deadlines, time and expenses, and fee bills',
  ),
  ModuleDef(
    'channels',
    'Online channels',
    'Marketplace and web store orders, SKU mapping and settlement reconciliation',
  ),
  ModuleDef(
    'gst',
    'GST',
    'GST returns, 2B reconciliation and rates',
    indiaOnly: true,
  ),
  ModuleDef(
    'tds',
    'TDS',
    'TDS deductions, challans and returns',
    indiaOnly: true,
  ),
  ModuleDef(
    'income_tax',
    'Income tax',
    'Tax calculators, advance tax and ITR data',
    indiaOnly: true,
  ),
  ModuleDef('einvoice', 'E-invoice', 'IRN and e-way bill', indiaOnly: true),
  ModuleDef('fixed_assets', 'Fixed assets', 'Asset register and depreciation'),
  ModuleDef(
    'accounting',
    'Accounting',
    'Chart of accounts, journals and financial statements',
  ),
  ModuleDef('reports', 'Reports', 'Registers, ageing and valuation'),
  ModuleDef(
    'controls',
    'Controls',
    'Approvals, custom fields, cost centres and imports',
  ),
  ModuleDef(
    'multi_company',
    'Multiple companies',
    'Several companies, inter-company and consolidation',
  ),
];

/// Plan limits. A default the owner may change; there is no billing yet.
class PlanDef {
  const PlanDef(
    this.id,
    this.name,
    this.maxUsers,
    this.features, {
    this.allowedModules,
  });

  final String id;
  final String name;
  final int? maxUsers;
  final List<String> features;

  /// `null` = every module.
  final List<String>? allowedModules;

  bool get simplifiedMenu => id == 'solo';
}

const List<PlanDef> kPlans = [
  PlanDef(
    'solo',
    'Solo',
    1,
    ['1 user', '1 company', 'Simplified menu'],
    allowedModules: [
      'sales',
      'purchases',
      'inventory',
      'gst',
      'tds',
      'income_tax',
      'einvoice',
      'fixed_assets',
      'accounting',
      'reports',
    ],
  ),
  PlanDef('team', 'Team', 10, ['Up to 10 users', 'Roles and locations']),
  PlanDef('business', 'Business', 50, ['Up to 50 users', 'All modules']),
  PlanDef('enterprise', 'Enterprise', null, [
    'Unlimited users',
    'Single sign-on',
    'Approvals',
    'Multiple companies',
  ]),
];

PlanDef planById(String id) =>
    kPlans.firstWhere((p) => p.id == id, orElse: () => kPlans[2]);

const Map<String, String> kTermDefaults = {
  'customer': 'Customer',
  'vendor': 'Vendor',
  'item': 'Item',
  'invoice': 'Invoice',
  'bill': 'Bill',
  'project': 'Project',
  'sales_order': 'Sales order',
  'receipt': 'Receipt',
  'location': 'Location',
  'stock': 'Stock',
};

class CountryDef {
  const CountryDef(this.code, this.name, this.currency, this.locale);

  final String code;
  final String name;
  final String currency;
  final String locale;
}

const List<CountryDef> kCountries = [
  CountryDef('IN', 'India', 'INR', 'en_IN'),
  CountryDef('US', 'United States', 'USD', 'en_US'),
  CountryDef('GB', 'United Kingdom', 'GBP', 'en_GB'),
  CountryDef('AE', 'United Arab Emirates', 'AED', 'en_AE'),
  CountryDef('SG', 'Singapore', 'SGD', 'en_SG'),
  CountryDef('AU', 'Australia', 'AUD', 'en_AU'),
  CountryDef('CA', 'Canada', 'CAD', 'en_CA'),
  CountryDef('DE', 'Germany', 'EUR', 'de_DE'),
  CountryDef('FR', 'France', 'EUR', 'fr_FR'),
  CountryDef('NP', 'Nepal', 'NPR', 'en_IN'),
  CountryDef('BD', 'Bangladesh', 'BDT', 'en_IN'),
  CountryDef('LK', 'Sri Lanka', 'LKR', 'en_IN'),
  CountryDef('SA', 'Saudi Arabia', 'SAR', 'en_US'),
  CountryDef('ZA', 'South Africa', 'ZAR', 'en_ZA'),
  CountryDef('KE', 'Kenya', 'KES', 'en_KE'),
  CountryDef('NG', 'Nigeria', 'NGN', 'en_NG'),
  CountryDef('XX', 'Other country', 'USD', 'en_US'),
];

CountryDef countryByCode(String code) => kCountries.firstWhere(
  (c) => c.code == code,
  orElse: () => kCountries.first,
);

/// Menu-only paths a solo user does not need.
const Set<String> kSoloHiddenPaths = {
  '/users',
  '/roles',
  '/integrations',
  '/audit',
  '/locations',
  '/transfers',
  '/reorder',
  '/stock-counts',
  '/jobs',
  '/outbox',
  '/security',
  '/gsp-settings',
  '/custom-fields',
  '/cost-centres',
  '/cost-centre-report',
  '/approval-rules',
  '/imports',
  '/msme-dues',
  '/setup-health',
};

/// What kind of business the active company is: which modules show, and
/// which words it uses. Modules only shape the menu; permissions are the
/// security check.
class BusinessProfile {
  const BusinessProfile({
    this.type = 'general',
    this.plan = 'business',
    this.enabledModules,
    this.terms = const {},
    this.country = 'IN',
    this.currency = 'INR',
  });

  /// The profile of [company]; the defaults when there is none.
  factory BusinessProfile.of(Company? company) => company == null
      ? const BusinessProfile()
      : BusinessProfile(
          type: company.businessType,
          plan: company.plan,
          enabledModules: company.enabledModules,
          terms: company.terms,
          country: company.country,
          currency: company.currency,
        );

  static const BusinessProfile standard = BusinessProfile();

  final String type;
  final String plan;

  /// `null` = every module (older companies keep their whole menu).
  final List<String>? enabledModules;
  final Map<String, String> terms;
  final String country;
  final String currency;

  PlanDef get planDef => planById(plan);

  bool get simplifiedMenu => planDef.simplifiedMenu;

  bool get isIndia => country == 'IN';

  /// Whether [key] is on. Unknown keys (a section that is not a module) are on.
  bool hasModule(String key) {
    final def = kModules.where((m) => m.key == key);
    if (def.isEmpty) return true;
    if (def.first.indiaOnly && !isIndia) return false;
    final allowed = planDef.allowedModules;
    if (allowed != null && !allowed.contains(key)) return false;
    final on = enabledModules;
    return on == null || on.contains(key);
  }

  /// The company's word for [key] (`customer` → `Patient`); [plural] adds
  /// an s (or ies).
  String term(String key, {bool plural = false}) {
    final custom = terms[key];
    final word = custom != null && custom.trim().isNotEmpty
        ? custom.trim()
        : (kTermDefaults[key] ?? key);
    return plural ? pluralize(word) : word;
  }

  /// The word for a customer-or-vendor record: the company's customer word
  /// when it has one (`Patient`), otherwise `Party`.
  String get partyWord =>
      (terms['customer'] ?? '').trim().isEmpty ? 'Party' : term('customer');

  /// Lower-case form for use inside a sentence.
  String termLower(String key, {bool plural = false}) =>
      term(key, plural: plural).toLowerCase();
}

/// `Patient` → `Patients`, `Delivery` → `Deliveries`, `Service or medicine` →
/// `Services or medicines`; a word already ending in a single s is kept.
String pluralize(String word) {
  if (word.isEmpty) return word;
  if (word.contains(' or ')) {
    return word.split(' or ').map(pluralize).join(' or ');
  }
  final lower = word.toLowerCase();
  if (lower.endsWith('ss')) return '${word}es';
  if (lower.endsWith('s')) return word;
  if (lower.endsWith('y') &&
      word.length > 1 &&
      !'aeiou'.contains(lower[lower.length - 2])) {
    return '${word.substring(0, word.length - 1)}ies';
  }
  if (lower.endsWith('ch') || lower.endsWith('sh') || lower.endsWith('x')) {
    return '${word}es';
  }
  return '${word}s';
}

/// The first choice of a two-way word, for the narrow menu: `Services or
/// medicines` → `Services`.
String menuWord(String word) => word.split(' or ').first;

final businessProfileProvider = Provider<BusinessProfile>(
  (ref) => BusinessProfile.of(
    ref.watch(sessionProvider.select((s) => s.value?.company)),
  ),
);

/// Rewrites default words in [text] to the company's own (`Customers` →
/// `Patients`). Leaves "Tax Invoice" and "e-invoice" alone. Use it for page
/// titles, column headers, labels, empty states and buttons; never for
/// statutory or printed documents.
String applyTerms(String text, BusinessProfile profile) {
  if (profile.terms.isEmpty) return text;
  // `Party` (a customer or a vendor) follows the customer word.
  final pairs = <(String, String?)>[
    for (final e in kTermDefaults.entries) (e.value, profile.terms[e.key]),
    ('Party', profile.terms['customer']),
  ];
  final words = <String, String>{};
  for (final (base, raw) in pairs) {
    final custom = raw?.trim();
    if (custom == null || custom.isEmpty || custom == base) continue;
    words[base.toLowerCase()] = custom;
    words[pluralize(base).toLowerCase()] = pluralize(custom);
  }
  if (words.isEmpty) return text;
  // One pass, so a result is never rewritten: with `invoice` → `Bill` and
  // `bill` → `Purchase bill`, `Invoices` must stop at `Bills`.
  final froms = words.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final alternatives = froms
      .map(
        (w) =>
            '(?:${w[0].toUpperCase()}|${w[0]})'
            '${RegExp.escape(w.substring(1))}',
      )
      .join('|');
  final re = RegExp(
    '(?<![\\w-])(?<![Tt]ax )(?<![Ee]-way )(?<![Pp]urchase )'
    '(?:$alternatives)(?![\\w])',
  );
  return text.replaceAllMapped(re, (m) {
    final hit = m[0]!;
    final to = words[hit.toLowerCase()]!;
    final upper = hit[0] == hit[0].toUpperCase();
    return upper ? to : '${to[0].toLowerCase()}${to.substring(1)}';
  });
}

/// Suggested quick actions for the active company's business type, already
/// in the company's words and limited to what the user may do. Empty while
/// the catalogue loads, when it cannot be loaded or the type is unknown.
/// The dashboard shows these.
final quickActionsProvider = Provider<List<QuickActionDef>>((ref) {
  final type = ref.watch(
    sessionProvider.select((s) => s.value?.company?.businessType),
  );
  final catalogue = ref.watch(businessCatalogueProvider).value;
  final perms = ref.watch(permissionsProvider);
  final profile = ref.watch(businessProfileProvider);
  if (type == null || catalogue == null) return const [];
  final def = catalogue.types.where((t) => t.id == type);
  if (def.isEmpty) return const [];
  return [
    for (final q in def.first.quickActions)
      if (perms.can(q.permission))
        QuickActionDef(applyTerms(q.label, profile), q.route),
  ];
});

class QuickActionDef {
  const QuickActionDef(this.label, this.route);

  final String label;
  final String route;
}

/// Carries the active [BusinessProfile] to widgets that have no `ref`
/// (shared page headers and lists). Without a scope, text is unchanged.
class TermsScope extends InheritedWidget {
  const TermsScope({super.key, required this.profile, required super.child});

  final BusinessProfile profile;

  static BusinessProfile? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TermsScope>()?.profile;

  @override
  bool updateShouldNotify(TermsScope old) => old.profile.terms != profile.terms;
}

extension TermsContext on BuildContext {
  /// [text] in the company's words.
  String w(String text) {
    final p = TermsScope.maybeOf(this);
    return p == null ? text : applyTerms(text, p);
  }
}
