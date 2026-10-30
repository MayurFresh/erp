import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'compliance_models.dart';
import 'compliance_repository.dart';
import 'compliance_widgets.dart';

/// `/data-export`: company data as CSV.
class DataExportScreen extends ConsumerStatefulWidget {
  const DataExportScreen({super.key});

  @override
  ConsumerState<DataExportScreen> createState() => _DataExportScreenState();
}

class _DataExportScreenState extends ConsumerState<DataExportScreen> {
  DateTime? _from;
  DateTime? _to;
  String? _busy;

  Future<void> _export(String dataset, String title) async {
    setState(() => _busy = dataset);
    try {
      final csv = await ref
          .read(complianceRepositoryProvider)
          .exportCsv(
            dataset,
            from: _from == null ? null : apiDate(_from!),
            to: _to == null ? null : apiDate(_to!),
          );
      if (!mounted) return;
      final rows = csv.trim().isEmpty ? 0 : csv.trim().split('\n').length - 1;
      await shareText(context, csv, '$title CSV ($rows rows)');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const PageHeader(
        title: 'Data export',
        subtitle: 'Your data as CSV, to paste into a spreadsheet or keep',
      ),
      FilterBar(
        children: [
          DayButton(
            label: 'From',
            value: _from,
            onChanged: (d) => setState(() => _from = d),
          ),
          DayButton(
            label: 'To',
            value: _to,
            onChanged: (d) => setState(() => _to = d),
          ),
          if (_from != null || _to != null)
            TextButton(
              onPressed: () => setState(() {
                _from = null;
                _to = null;
              }),
              child: const Text('Clear dates'),
            ),
        ],
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            for (final (key, title, text) in exportDatasets)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(title),
                  subtitle: Text(text),
                  trailing: _busy == key
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.copy_all_outlined),
                  onTap: _busy == null ? () => _export(key, title) : null,
                ),
              ),
          ],
        ),
      ),
    ],
  );
}
