import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/states.dart';
import 'tax_models.dart';
import 'tax_repository.dart';

/// Shows the TDS a document would deduct, from a debounced
/// `POST /tds/preview`, and the net payable ([documentTotal] − TDS).
/// Renders nothing until a party, a section and a gross amount are known.
class TdsPreviewCard extends ConsumerStatefulWidget {
  const TdsPreviewCard({
    super.key,
    required this.partyId,
    required this.sectionId,
    required this.date,
    required this.gross,
    this.documentTotal,
    this.netLabel = 'Net payable',
    this.debounce = const Duration(milliseconds: 500),
  });

  final String? partyId;
  final String? sectionId;

  /// `YYYY-MM-DD`.
  final String date;

  /// Value before GST.
  final double? gross;

  /// Document total to subtract TDS from.
  final double? documentTotal;
  final String netLabel;
  final Duration debounce;

  @override
  ConsumerState<TdsPreviewCard> createState() => _TdsPreviewCardState();
}

class _TdsPreviewCardState extends ConsumerState<TdsPreviewCard> {
  Timer? _timer;
  int _generation = 0;
  TdsCalc? _calc;
  Object? _error;
  bool _loading = false;

  bool get _ready =>
      widget.partyId != null &&
      widget.sectionId != null &&
      (widget.gross ?? 0) > 0;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(TdsPreviewCard old) {
    super.didUpdateWidget(old);
    if (old.partyId != widget.partyId ||
        old.sectionId != widget.sectionId ||
        old.date != widget.date ||
        old.gross != widget.gross) {
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    _generation++;
    if (!_ready) {
      _calc = null;
      _error = null;
      _loading = false;
      return;
    }
    _loading = true;
    _timer = Timer(widget.debounce, _run);
  }

  Future<void> _run() async {
    final generation = ++_generation;
    try {
      final calc = await ref
          .read(taxRepositoryProvider)
          .previewTds(
            partyId: widget.partyId!,
            sectionId: widget.sectionId!,
            date: widget.date,
            gross: widget.gross!,
          );
      if (!mounted || generation != _generation) return;
      setState(() {
        _calc = calc;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final calc = _calc;
    final Widget body;
    if (_error != null) {
      body = Text(
        errorMessage(_error!),
        style: TextStyle(color: theme.colorScheme.error),
      );
    } else if (calc == null) {
      body = const Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else {
      final total = widget.documentTotal;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _row(
            'TDS ${calc.sectionCode} @ ${formatPercent(calc.rate)}',
            formatMoney(calc.amount),
            bold: true,
          ),
          if (total != null)
            _row(widget.netLabel, formatMoney(total - calc.amount)),
          const SizedBox(height: 4),
          Text(
            calc.reasonText,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (calc.threshold != null)
            Text(
              'Year to date incl. this: ${formatMoney(calc.fyGross)} '
              '(threshold ${formatMoney(calc.threshold)})',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      );
    }
    return Opacity(
      opacity: _loading && calc != null ? 0.6 : 1,
      child: Padding(padding: const EdgeInsets.only(top: 12), child: body),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(
          value,
          style: TextStyle(fontWeight: bold ? FontWeight.w600 : null),
        ),
      ],
    ),
  );
}
