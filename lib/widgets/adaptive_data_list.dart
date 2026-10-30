import 'package:flutter/material.dart';

import 'paged_controller.dart';
import 'states.dart';

class TableColumnSpec<T> {
  const TableColumnSpec(
    this.label,
    this.cell, {
    this.numeric = false,
    this.maxWidth,
  });

  final String label;
  final Widget Function(T row) cell;
  final bool numeric;

  /// Caps the column; longer text is ellipsized on one line.
  final double? maxWidth;

  Widget build(T row) {
    final max = maxWidth;
    if (max == null) return cell(row);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: max),
      child: DefaultTextStyle.merge(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        child: cell(row),
      ),
    );
  }
}

/// A paged list shown as a [DataTable] on wide screens and as cards on
/// phones, with loading, empty, error and "load more" states.
class AdaptiveDataList<T> extends StatelessWidget {
  const AdaptiveDataList({
    super.key,
    required this.controller,
    required this.columns,
    required this.cardBuilder,
    this.onTap,
    this.emptyMessage = 'Nothing here yet.',
    this.emptyIcon = Icons.inbox_outlined,
    this.emptyAction,
    this.tableBreakpoint = 720,
  });

  final PagedController<T> controller;
  final List<TableColumnSpec<T>> columns;
  final Widget Function(BuildContext context, T row) cardBuilder;
  final void Function(T row)? onTap;
  final String emptyMessage;
  final IconData emptyIcon;
  final Widget? emptyAction;
  final double tableBreakpoint;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        if (c.items.isEmpty) {
          if (c.loading || !c.loaded) return const LoadingView();
          if (c.error != null) {
            return ErrorView(error: c.error!, onRetry: c.refresh);
          }
          return RefreshIndicator(
            onRefresh: c.refresh,
            child: LayoutBuilder(
              builder: (context, constraints) => ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(
                    height: constraints.maxHeight,
                    child: EmptyView(
                      message: emptyMessage,
                      icon: emptyIcon,
                      action: emptyAction,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: c.refresh,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final footer = PagedFooter(controller: c);
              if (constraints.maxWidth >= tableBreakpoint) {
                return ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  children: [
                    Card(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: constraints.maxWidth - 32,
                          ),
                          child: _table(c.items),
                        ),
                      ),
                    ),
                    footer,
                  ],
                );
              }
              return ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                itemCount: c.items.length + 1,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) => i == c.items.length
                    ? footer
                    : cardBuilder(context, c.items[i]),
              );
            },
          ),
        );
      },
    );
  }

  Widget _table(List<T> rows) {
    final tap = onTap;
    return DataTable(
      showCheckboxColumn: false,
      // Tighter than the defaults (56/24) so 7-column tables fit a laptop
      // screen next to the sidebar without horizontal scrolling.
      columnSpacing: 24,
      horizontalMargin: 16,
      columns: [
        for (final column in columns)
          DataColumn(label: Text(column.label), numeric: column.numeric),
      ],
      rows: [
        for (final row in rows)
          DataRow(
            onSelectChanged: tap == null ? null : (_) => tap(row),
            cells: [for (final column in columns) DataCell(column.build(row))],
          ),
      ],
    );
  }
}

class PagedFooter extends StatelessWidget {
  const PagedFooter({super.key, required this.controller});

  final PagedController<Object?> controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 4,
        children: [
          Text(
            'Showing ${c.items.length} of ${c.total}',
            style: theme.textTheme.bodySmall,
          ),
          if (c.error != null) ...[
            Text(
              errorMessage(c.error!),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            TextButton(onPressed: c.loadMore, child: const Text('Retry')),
          ] else if (c.hasMore)
            c.loading
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    onPressed: c.loadMore,
                    child: const Text('Load more'),
                  ),
        ],
      ),
    );
  }
}

/// A tappable card row for phone layouts.
class ListCard extends StatelessWidget {
  const ListCard({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leading,
    this.onTap,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final Widget? leading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 16)],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DefaultTextStyle.merge(
                    style: Theme.of(context).textTheme.bodyLarge,
                    child: title,
                  ),
                  if (subtitle != null)
                    DefaultTextStyle.merge(
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      child: subtitle!,
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              Flexible(
                flex: 0,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.sizeOf(context).width * 0.4,
                  ),
                  child: trailing!,
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
