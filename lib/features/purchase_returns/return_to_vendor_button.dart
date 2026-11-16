import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../documents/document_widgets.dart';

/// Opens the debit note form for one purchase bill.
String returnToVendorPath(String purchaseId) =>
    Uri(path: '/purchase-returns/new', queryParameters: {'purchaseId': purchaseId})
        .toString();

/// For the action row of a bill.
DocAction returnToVendorAction(BuildContext context, String purchaseId) =>
    DocAction(
      label: 'Return to vendor',
      icon: Icons.assignment_return_outlined,
      onPressed: () => context.push(returnToVendorPath(purchaseId)),
    );

/// A plain button for places outside the action row. Show it only to users who
/// may create purchases, and only for a posted bill.
class ReturnToVendorButton extends StatelessWidget {
  const ReturnToVendorButton({super.key, required this.purchaseId});

  final String purchaseId;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: () => context.push(returnToVendorPath(purchaseId)),
    icon: const Icon(Icons.assignment_return_outlined),
    label: const Text('Return to vendor'),
  );
}
