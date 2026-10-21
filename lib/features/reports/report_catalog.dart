import 'package:flutter/material.dart';

import '../../core/permissions.dart';

/// One report: its route segment under `/reports`, hub card text and the
/// permissions it needs (all of them).
class ReportInfo {
  const ReportInfo({
    required this.name,
    required this.title,
    required this.description,
    required this.icon,
    required this.group,
    required this.allOf,
  });

  /// Route segment: `/reports/<name>`.
  final String name;
  final String title;
  final String description;
  final IconData icon;
  final String group;
  final List<String> allOf;

  String get path => '/reports/$name';

  bool allowed(PermissionSet permissions) => allOf.every(permissions.can);
}

const String kFinancialStatements = 'Financial statements';
const String kRegistersAndGst = 'Registers & GST';
const String kPartiesAndStock = 'Outstanding & stock';

/// Every report, in hub order.
const List<ReportInfo> reportCatalog = [
  ReportInfo(
    name: 'trial-balance',
    title: 'Trial balance',
    description: 'Debit and credit balance of every account',
    icon: Icons.balance_outlined,
    group: kFinancialStatements,
    allOf: [Perm.accountsView],
  ),
  ReportInfo(
    name: 'profit-loss',
    title: 'Profit & loss',
    description: 'Revenue, cost of goods sold, expenses and net profit',
    icon: Icons.trending_up_outlined,
    group: kFinancialStatements,
    allOf: [Perm.accountsView],
  ),
  ReportInfo(
    name: 'balance-sheet',
    title: 'Balance sheet',
    description: 'Assets against liabilities and equity',
    icon: Icons.account_balance_outlined,
    group: kFinancialStatements,
    allOf: [Perm.accountsView],
  ),
  ReportInfo(
    name: 'sales-register',
    title: 'Sales register',
    description: 'Every invoice with taxable value and GST',
    icon: Icons.receipt_long_outlined,
    group: kRegistersAndGst,
    allOf: [Perm.reportsView],
  ),
  ReportInfo(
    name: 'purchase-register',
    title: 'Purchase register',
    description: 'Every purchase bill with input GST',
    icon: Icons.shopping_cart_outlined,
    group: kRegistersAndGst,
    allOf: [Perm.reportsView],
  ),
  ReportInfo(
    name: 'gst-summary',
    title: 'GST summary',
    description: 'Outward and inward supplies by rate, HSN summary, net payable',
    icon: Icons.percent_outlined,
    group: kRegistersAndGst,
    allOf: [Perm.reportsView],
  ),
  ReportInfo(
    name: 'receivables-ageing',
    title: 'Receivables ageing',
    description: 'Customer dues by days past the due date',
    icon: Icons.call_received_outlined,
    group: kPartiesAndStock,
    allOf: [Perm.reportsView],
  ),
  ReportInfo(
    name: 'payables-ageing',
    title: 'Payables ageing',
    description: 'Vendor dues by days past the due date',
    icon: Icons.call_made_outlined,
    group: kPartiesAndStock,
    allOf: [Perm.reportsView],
  ),
  ReportInfo(
    name: 'stock-valuation',
    title: 'Stock valuation',
    description: 'Quantity and weighted-average value of every item',
    icon: Icons.inventory_2_outlined,
    group: kPartiesAndStock,
    allOf: [Perm.reportsView, Perm.itemsViewCost],
  ),
];

ReportInfo reportInfo(String name) =>
    reportCatalog.firstWhere((r) => r.name == name);

/// Reports [permissions] allow, in hub order.
List<ReportInfo> visibleReports(PermissionSet permissions) =>
    reportCatalog.where((r) => r.allowed(permissions)).toList();
