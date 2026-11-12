import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'fulfilment_models.dart';

typedef ScanHandler =
    Future<ScanResult> Function(String scanId, String code, double qty);

/// A scan box for keyboard-wedge scanners: the field always has focus, Enter
/// submits, and the result of the last scan stays visible under it.
///
/// Scans are queued and sent one at a time, so a fast scanner never drops a
/// code. Every scan carries its own id so a retried request cannot count
/// twice on the server.
class ScanPanel extends StatefulWidget {
  const ScanPanel({
    super.key,
    required this.onScan,
    this.label = 'Scan a barcode or SKU',
  });

  final ScanHandler onScan;
  final String label;

  @override
  State<ScanPanel> createState() => _ScanPanelState();
}

class _ScanPanelState extends State<ScanPanel> {
  final _code = TextEditingController();
  final _qty = TextEditingController(text: '1');
  final _focus = FocusNode();
  final List<(String, String, double)> _queue = [];
  bool _working = false;
  int _seq = 0;
  final String _session = DateTime.now().microsecondsSinceEpoch.toString();

  String? _message;
  bool _failed = false;

  @override
  void dispose() {
    _code.dispose();
    _qty.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final code = raw.trim();
    _code.clear();
    _focus.requestFocus();
    if (code.isEmpty) return;
    final qty = parseNumber(_qty.text);
    if (qty == null || qty <= 0) {
      setState(() {
        _failed = true;
        _message = 'Enter a quantity above zero';
      });
      return;
    }
    _queue.add(('$_session-${_seq++}', code, qty));
    _qty.text = '1';
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_working) return;
    _working = true;
    while (_queue.isNotEmpty && mounted) {
      final (id, code, qty) = _queue.removeAt(0);
      try {
        final r = await widget.onScan(id, code, qty);
        if (!mounted) return;
        setState(() {
          _failed = false;
          _message = r.duplicate
              ? 'Already counted: ${r.itemName}'
              : 'Added ${formatQty(r.qty)} × ${r.itemName}';
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _failed = true;
          _message = '$code: ${errorMessage(e)}';
        });
      }
      if (mounted) _focus.requestFocus();
    }
    _working = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _failed ? theme.colorScheme.error : theme.colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormRow(
          breakpoint: 480,
          children: [
            TextField(
              key: const ValueKey('scan-field'),
              controller: _code,
              focusNode: _focus,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: _submit,
              decoration: InputDecoration(
                labelText: widget.label,
                prefixIcon: const Icon(Icons.qr_code_scanner),
              ),
            ),
            SizedBox(
              width: 120,
              child: TextField(
                key: const ValueKey('scan-qty'),
                controller: _qty,
                keyboardType: decimalKeyboard,
                inputFormatters: <TextInputFormatter>[
                  decimalInput(decimals: 3),
                ],
                decoration: const InputDecoration(labelText: 'Quantity'),
                onSubmitted: (_) => _focus.requestFocus(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_message != null)
          Row(
            key: const ValueKey('scan-result'),
            children: [
              Icon(
                _failed ? Icons.error_outline : Icons.check_circle_outline,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _message!,
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                ),
              ),
              IconButton(
                tooltip: 'Clear result',
                onPressed: () {
                  setState(() => _message = null);
                  _focus.requestFocus();
                },
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
      ],
    );
  }
}
