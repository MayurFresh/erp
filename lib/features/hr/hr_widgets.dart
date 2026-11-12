import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/layout.dart';
import '../memberships/inline_async.dart';

/// Wraps a screen body in the page gutter with room at the bottom.
class HrPad extends StatelessWidget {
  const HrPad({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final g = pageGutter(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(g, 0, g, 32),
      children: children,
    );
  }
}

class HrSection extends StatelessWidget {
  const HrSection(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, Space.lg, 0, Space.sm),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// A bordered block of label/value rows or any content.
class HrCard extends StatelessWidget {
  const HrCard({super.key, required this.child, this.onTap, this.padding});

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: Space.sm),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.medium),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.medium),
        onTap: onTap,
        child: Padding(
          padding: padding ?? const EdgeInsets.all(Space.md),
          child: child,
        ),
      ),
    );
  }
}

/// Two texts on one line: label on the left, amount on the right.
class HrAmountRow extends StatelessWidget {
  const HrAmountRow(this.label, this.amount, {super.key, this.bold = false, this.text});

  final String label;
  final num? amount;
  final String? text;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: bold ? FontWeight.w700 : null,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(text ?? formatMoney(amount), style: style),
        ],
      ),
    );
  }
}

/// A read-only text field that opens a date picker. The value is `YYYY-MM-DD`.
class HrDateField extends StatelessWidget {
  const HrDateField({
    super.key,
    required this.controller,
    required this.label,
    this.required = false,
  });

  final TextEditingController controller;
  final String label;
  final bool required;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    readOnly: true,
    decoration: InputDecoration(
      labelText: required ? '$label *' : label,
      suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
    ),
    validator: (v) => required && (v == null || v.isEmpty) ? 'Required' : null,
    onTap: () async {
      final now = DateTime.now();
      final initial = DateTime.tryParse(controller.text) ?? now;
      final d = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(1950),
        lastDate: DateTime(now.year + 2),
      );
      if (d != null) {
        controller.text =
            '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      }
    },
  );
}

double? parseAmount(String s) => double.tryParse(s.replaceAll(',', '').trim());


/// A list inside a scrolling page: loading bar, error line, empty text.
class InlineAsyncList<T> extends StatelessWidget {
  const InlineAsyncList({
    super.key,
    required this.value,
    required this.item,
    required this.empty,
  });

  final AsyncValue<List<T>> value;
  final Widget Function(T row) item;
  final String empty;

  @override
  Widget build(BuildContext context) => InlineAsync<List<T>>(
    value: value,
    data: (rows) => rows.isEmpty
        ? Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(empty))
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final r in rows) item(r)],
          ),
  );
}
