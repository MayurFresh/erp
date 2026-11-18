import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../items/item_model.dart';
import '../stock_tools/unit_picker.dart';
import 'document_models.dart';
import 'document_widgets.dart';
import '../pricing/price_prefill.dart';

/// An editable line (item, qty, rate, discount) of an invoice or purchase.
class LineDraft with PricedLine {
  LineDraft(this.item, {double? defaultRate})
    : qty = TextEditingController(text: '1'),
      rate = TextEditingController(text: formatPlain(defaultRate)),
      discount = TextEditingController();

  /// Alternate unit the quantity and rate are entered in; null is the item's own unit.
  String? unit;

  /// The scheme's free goods were already added as a separate line.
  bool freeAdded = false;

  @override
  TextEditingController get priceRateField => rate;
  @override
  TextEditingController get priceDiscountField => discount;
  @override
  String get priceItemId => item.id;
  @override
  double get priceQty => parseNumber(qty.text) ?? 0;

  final Item item;
  final TextEditingController qty;
  final TextEditingController rate;
  final TextEditingController discount;
  final Key key = UniqueKey();

  bool get isValid {
    final q = parseNumber(qty.text);
    final r = rate.text.trim().isEmpty ? 0 : parseNumber(rate.text);
    final d = discount.text.trim().isEmpty ? 0 : parseNumber(discount.text);
    return q != null &&
        q > 0 &&
        r != null &&
        r >= 0 &&
        d != null &&
        d >= 0 &&
        d <= 100;
  }

  /// An empty rate is omitted so the server applies the item's default.
  DraftLine toDraft() => DraftLine(
    itemId: item.id,
    qty: parseNumber(qty.text)!,
    rate: parseNumber(rate.text),
    discountPct: parseNumber(discount.text),
    unit: unit,
  );

  void dispose() {
    qty.dispose();
    rate.dispose();
    discount.dispose();
  }
}

/// `lines.0.qty` / `lines[0].qty` → (0, qty).
final RegExp lineErrorKey = RegExp(r'^lines[.\[](\d+)\]?\.(\w+)$');

/// Splits `VALIDATION_ERROR` details into header and per-line errors.
(Map<String, String>, Map<int, Map<String, String>>) splitFieldErrors(
  Object error,
) {
  final api = apiError(error);
  final header = <String, String>{};
  final lines = <int, Map<String, String>>{};
  api?.fieldErrors.forEach((key, message) {
    final match = lineErrorKey.firstMatch(key);
    if (match == null) {
      header[key] = message;
    } else {
      (lines[int.parse(match.group(1)!)] ??= {})[match.group(2)!] = message;
    }
  });
  return (header, lines);
}

/// One line of the editor: a single row when there is room, a stacked card
/// on phones.
class LineEditor extends StatelessWidget {
  const LineEditor({
    super.key,
    required this.line,
    required this.preview,
    required this.errors,
    required this.onChanged,
    required this.onRemove,
    this.rateHint,
    this.onAddFree,
  });

  /// Adds the free goods of the line's scheme as a separate line.
  final VoidCallback? onAddFree;
  final LineDraft line;
  final TaxLine? preview;
  final Map<String, String> errors;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  /// Shown under an empty rate field, e.g. "Item default".
  final String? rateHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = line.item;
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final p = preview;

    Widget field(
      TextEditingController controller,
      String label,
      String errorKey, {
      required int decimals,
      required String? Function(String?) validator,
      String? hint,
    }) => TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        errorText: errors[errorKey],
        errorMaxLines: 2,
      ),
      keyboardType: decimalKeyboard,
      inputFormatters: [decimalInput(decimals: decimals)],
      onChanged: (_) => onChanged(),
      validator: validator,
    );

    final qty = field(
      line.qty,
      'Qty',
      'qty',
      decimals: 3,
      validator: (v) {
        final q = parseNumber(v ?? '');
        return q == null || q <= 0 ? 'Enter qty' : null;
      },
    );
    final rate = field(
      line.rate,
      'Rate ₹',
      'rate',
      decimals: 2,
      hint: rateHint,
      validator: (v) => optionalNumber(v, min: 0),
    );
    final discount = field(
      line.discount,
      'Disc %',
      'discountPct',
      decimals: 2,
      validator: (v) =>
          validatePercent(v, isRequired: false, label: 'Discount'),
    );
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.name,
          style: theme.textTheme.titleSmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          [
            if (item.hsnCode != null) 'HSN ${item.hsnCode}',
            item.unit,
            'GST ${formatPercent(item.gstRate)}',
          ].join(' · '),
          style: small,
          overflow: TextOverflow.ellipsis,
        ),
        LineUnitPicker(
          itemId: item.id,
          value: line.unit,
          onChanged: (u) => line.unit = u,
          onRateScale: (r) {
            line.rate.text = scaleRateText(line.rate.text, r);
            onChanged();
          },
        ),
      ],
    );
    final remove = IconButton(
      tooltip: 'Remove line',
      icon: const Icon(Icons.delete_outline),
      onPressed: onRemove,
    );

    final card = Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 640) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 4, child: title),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: qty),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: rate),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: discount),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 120,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        p == null ? '—' : formatMoney(p.lineTotal),
                        textAlign: TextAlign.end,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ),
                  remove,
                ],
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: title),
                    remove,
                  ],
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: qty),
                      const SizedBox(width: 8),
                      Expanded(child: rate),
                      const SizedBox(width: 8),
                      Expanded(child: discount),
                    ],
                  ),
                ),
                if (p != null) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      'Taxable ${formatMoney(p.taxableValue)} · '
                      'Tax ${formatMoney(p.taxTotal)} · '
                      'Amount ${formatMoney(p.lineTotal)}',
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
    final price = line.resolved;
    if (price == null ||
        (price.priceListName == null &&
            price.source != 'customer' &&
            price.discountPct <= 0 &&
            price.freeQty <= 0)) {
      return card;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: SchemeHint(
            price: price,
            onAddFree: onAddFree,
            freeAdded: line.freeAdded,
          ),
        ),
        card,
      ],
    );
  }
}

/// Re-computes a server preview ~400 ms after the last change. The state
/// supplies [buildDraft] (null = not ready) and [fetchPreview].
mixin LivePreview<W extends StatefulWidget, D, R> on State<W> {
  R? preview;
  Object? previewError;
  bool previewing = false;
  Timer? _debounce;
  int _generation = 0;

  D? buildDraft();
  Future<R> fetchPreview(D draft);

  static const delay = Duration(milliseconds: 400);

  void schedulePreview() {
    _debounce?.cancel();
    if (buildDraft() == null) {
      _generation++;
      setState(() {
        preview = null;
        previewError = null;
        previewing = false;
      });
      return;
    }
    setState(() => previewing = true);
    _debounce = Timer(delay, _run);
  }

  void cancelPreview() => _debounce?.cancel();

  Future<void> _run() async {
    final draft = buildDraft();
    if (draft == null) return;
    final generation = ++_generation;
    try {
      final result = await fetchPreview(draft);
      if (!mounted || generation != _generation) return;
      setState(() {
        preview = result;
        previewError = null;
        previewing = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        previewError = e;
        previewing = false;
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

/// Totals from the preview, errors and the save button.
class DocSummaryPanel extends StatelessWidget {
  const DocSummaryPanel({
    super.key,
    required this.ready,
    required this.preview,
    required this.previewError,
    required this.previewing,
    required this.saveError,
    required this.saving,
    required this.onSave,
    required this.saveLabel,
    required this.hint,
    this.hideSave = false,
    this.subject = 'the document',
    this.placeLabel = 'Place of supply',
  });

  final bool ready;
  final TaxSummary? preview;
  final Object? previewError;
  final bool previewing;
  final Object? saveError;
  final bool saving;
  final VoidCallback onSave;
  final String saveLabel;

  /// True when the save button lives in the page's sticky bar instead.
  final bool hideSave;

  /// Shown until the form is complete enough to preview.
  final String hint;
  final String subject;
  final String placeLabel;

  @override
  Widget build(BuildContext context) {
    final error = saveError ?? previewError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!ready && preview == null) Text(hint),
        if (previewing) const LinearProgressIndicator(minHeight: 2),
        if (ready && preview != null)
          AnimatedOpacity(
            opacity: previewing ? 0.5 : 1,
            duration: const Duration(milliseconds: 150),
            child: TaxTotals(summary: preview!, placeLabel: placeLabel),
          ),
        if (error != null) ...[
          const SizedBox(height: 12),
          ApiErrorBox(error: error, subject: subject),
        ],
        if (!hideSave) ...[
          const SizedBox(height: 16),
          BusyButton(
            busy: saving,
            onPressed: onSave,
            icon: Icons.save_outlined,
            label: saveLabel,
          ),
        ],
      ],
    );
  }
}

/// Sticky save strip for [DocFormLayout.bottomBar].
class DocSaveBar extends StatelessWidget {
  const DocSaveBar({
    super.key,
    required this.busy,
    required this.onPressed,
    required this.label,
  });

  final bool busy;
  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) => FormActionBar(
    children: [
      BusyButton(
        busy: busy,
        onPressed: onPressed,
        icon: Icons.save_outlined,
        label: label,
      ),
    ],
  );
}

/// Page frame for create screens: details and lines on the left and the
/// summary pinned on the right from 1000 px, stacked below that.
class DocFormLayout extends StatelessWidget {
  const DocFormLayout({
    super.key,
    required this.title,
    required this.main,
    required this.summary,
    this.bottomBar,
  });

  final String title;
  final List<Widget> main;
  final Widget summary;

  /// Sticky strip under the scrolling form, e.g. a [FormActionBar].
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutter(context);
    final scroll = SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(gutter, Space.md, gutter, Space.lg),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Layout.contentMaxWidth),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final heading = Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              );
              if (constraints.maxWidth >= 1000) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    heading,
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: main,
                          ),
                        ),
                        const SizedBox(width: 16),
                        SizedBox(width: 360, child: summary),
                      ],
                    ),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [heading, ...main, summary],
              );
            },
          ),
        ),
      ),
    );
    if (bottomBar == null) return scroll;
    return Column(
      children: [
        Expanded(child: scroll),
        bottomBar!,
      ],
    );
  }
}

/// Date picker for document dates: 2000-01-01 to today + 365 days.
Future<DateTime?> pickDocDate(BuildContext context, DateTime initial) {
  final last = maxDocDate();
  final clamped = initial.isBefore(kMinDocDate)
      ? kMinDocDate
      : (initial.isAfter(last) ? last : initial);
  return showDatePicker(
    context: context,
    initialDate: clamped,
    firstDate: kMinDocDate,
    lastDate: last,
  );
}

/// The "Items" card of a create screen: one [LineEditor] per line and an
/// "Add item" button.
class DocLinesSection extends StatelessWidget {
  const DocLinesSection({
    super.key,
    required this.lines,
    required this.previewLines,
    required this.lineErrors,
    required this.onChanged,
    required this.onRemove,
    required this.onAdd,
    this.enabled = true,
    this.rateHint,
    this.onAddFree,
  });

  /// Called with the line whose scheme free goods should be added.
  final ValueChanged<LineDraft>? onAddFree;

  final List<LineDraft> lines;

  /// Preview lines, used only when they match [lines] one to one.
  final List<TaxLine>? previewLines;
  final Map<int, Map<String, String>> lineErrors;
  final VoidCallback onChanged;
  final ValueChanged<LineDraft> onRemove;
  final VoidCallback onAdd;
  final bool enabled;
  final String? rateHint;

  @override
  Widget build(BuildContext context) {
    final preview = previewLines;
    final matches = preview != null && preview.length == lines.length;
    return SectionCard(
      title: 'Items',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (lines.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('No items yet. Add the first one.'),
            ),
          for (final (index, line) in lines.indexed)
            LineEditor(
              key: line.key,
              line: line,
              preview: matches ? preview[index] : null,
              errors: lineErrors[index] ?? const {},
              rateHint: rateHint,
              onAddFree: onAddFree == null ? null : () => onAddFree!(line),
              onChanged: onChanged,
              onRemove: () => onRemove(line),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: enabled ? onAdd : null,
              icon: const Icon(Icons.add),
              label: const Text('Add item'),
            ),
          ),
        ],
      ),
    );
  }
}
