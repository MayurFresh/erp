import 'package:pdf/widgets.dart' as pw;

import '../../../core/pdf_kit.dart';
import '../../construction/models/project_models.dart';
import '../../insights/analytics_models.dart';
import '../../insights/insights_rules.dart';
import '../report_models.dart' show StockValuationRow;

/// The parts of a client report the user can switch on.
enum ReportSection {
  summary('Summary'),
  sales('Sales'),
  profit('Profit'),
  cash('Cash'),
  receivables('Receivables'),
  stock('Stock'),
  projects('Projects');

  const ReportSection(this.label);
  final String label;
}

/// Sections whose data the user is allowed to see, from what the server sent.
/// A section with no permission is left out, not shown blank.
Set<ReportSection> availableSections(
  Analytics a, {
  required bool canSeeProjects,
}) => {
  ReportSection.summary,
  ReportSection.sales,
  if (a.current.netProfit != null) ReportSection.profit,
  if (a.cashFlow != null) ReportSection.cash,
  if (a.current.receivables != null) ReportSection.receivables,
  if (a.current.stockValue != null) ReportSection.stock,
  if (canSeeProjects) ReportSection.projects,
};

/// Everything a client report needs, already fetched.
class ClientReportInput {
  const ClientReportInput({
    required this.brand,
    required this.theme,
    required this.analytics,
    required this.sections,
    required this.takeaways,
    required this.periodLabel,
    required this.generatedOn,
    this.recipient = '',
    this.preparedBy = '',
    this.notes = '',
    this.stockRows = const [],
    this.stockTotal,
    this.projects = const [],
  });

  final PdfBrand brand;
  final pw.ThemeData? theme;
  final Analytics analytics;
  final Set<ReportSection> sections;
  final List<Takeaway> takeaways;

  /// `01 Apr 2026 to 21 Oct 2026`.
  final String periodLabel;
  final String generatedOn;
  final String recipient, preparedBy, notes;
  final List<StockValuationRow> stockRows;
  final double? stockTotal;
  final List<Project> projects;

  bool has(ReportSection s) => sections.contains(s);
}
