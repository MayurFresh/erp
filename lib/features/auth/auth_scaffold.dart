import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../widgets/brand.dart';
import '../../widgets/illustrations.dart';

/// Layout for sign-in, sign-up and password pages. From 900 px wide it is a
/// brand panel next to the form; below that, one plain column.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.maxWidth = 420,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= Layout.wide;
    final form = _FormColumn(
      title: title,
      subtitle: subtitle,
      maxWidth: maxWidth,
      showWordmark: !wide,
      child: child,
    );
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: wide
          ? Row(
              children: [
                const Expanded(flex: 5, child: _BrandPanel()),
                Expanded(flex: 6, child: SafeArea(child: form)),
              ],
            )
          : SafeArea(child: form),
    );
  }
}

class _FormColumn extends StatelessWidget {
  const _FormColumn({
    required this.title,
    required this.subtitle,
    required this.maxWidth,
    required this.showWordmark,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final double maxWidth;
  final bool showWordmark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.xl,
          vertical: Space.xl,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showWordmark) ...[
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Wordmark(size: 28),
                ),
                const SizedBox(height: Space.xxl),
              ],
              Text(title, style: theme.textTheme.headlineMedium),
              if (subtitle != null) ...[
                const SizedBox(height: Space.sm),
                Text(
                  subtitle!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: Space.xl),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel();

  static const _points = [
    'GST invoices and e-invoices, with GSTR-1 and GSTR-3B prepared from your books',
    'Stock by godown and site, with transfers, counts and low-stock alerts',
    'Ledgers, bank reconciliation, TDS and the trial balance',
    'Construction sites: projects, subcontractor bills, labour and RA bills',
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final onBrand = scheme.onPrimary;
    // The panel stays in the brand colour in both themes.
    final bg = context.colors.sidebar;
    return Container(
      color: bg,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(Space.xxxl),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - Space.xxxl * 2,
                maxWidth: 520,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Wordmark(
                    size: 30,
                    color: Colors.white,
                    markBackground: Colors.white,
                    markForeground: bg,
                  ),
                  const SizedBox(height: Space.xxl),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Books, GST and stock for Indian businesses',
                        style: theme.textTheme.headlineLarge?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: Space.xl),
                      for (final point in _points)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Space.md),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 9),
                                child: Container(
                                  width: 6,
                                  height: 1.5,
                                  color: onBrand.withValues(alpha: 0.7),
                                ),
                              ),
                              const SizedBox(width: Space.md),
                              Expanded(
                                child: Text(
                                  point,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.92),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.xxl),
                  ExcludeSemantics(
                    child: CustomPaint(
                      size: const Size(240, 173),
                      painter: IllustrationPainter(
                        IllustrationKind.sales,
                        line: Colors.white.withValues(alpha: 0.55),
                        accent: Colors.white,
                        fill: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wordmark centred on a plain page; used by the splash screen.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key});

  @override
  Widget build(BuildContext context) => const Wordmark(size: 36);
}
