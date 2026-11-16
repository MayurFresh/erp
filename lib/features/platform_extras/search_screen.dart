import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../widgets/states.dart';
import 'extras_repository.dart';

/// `/search?q=`: results grouped by kind.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final _controller = TextEditingController(text: widget.initialQuery);
  late String _query = widget.initialQuery.trim();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = v.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(Space.md),
          children: [
            TextField(
              key: const ValueKey('search-input'),
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _changed,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Search customers, items, bills, payments and leads',
              ),
            ),
            const SizedBox(height: Space.md),
            if (_query.length < 2)
              Text(
                'Type at least two letters. You can search by name, phone, GSTIN, SKU, barcode or document number.',
                style: theme.textTheme.bodySmall,
              )
            else
              ref
                  .watch(searchResultsProvider(_query))
                  .when(
                    loading: () => const Padding(
                      padding: EdgeInsets.all(Space.lg),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (e, _) => ErrorView(
                      error: e,
                      onRetry: () =>
                          ref.invalidate(searchResultsProvider(_query)),
                    ),
                    data: (groups) => groups.isEmpty
                        ? const EmptyView(
                            icon: Icons.search_off,
                            message: 'Nothing matches that search.',
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final g in groups) _GroupCard(group: g),
                            ],
                          ),
                  ),
          ],
        ),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group});
  final SearchGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.md,
                Space.sm + 4,
                Space.md,
                Space.xs,
              ),
              child: Text(group.label, style: theme.textTheme.titleMedium),
            ),
            for (final i in group.items)
              ListTile(
                key: ValueKey('result-${group.kind}-${i.id}'),
                minVerticalPadding: 8,
                title: Text(i.title),
                subtitle: i.subtitle.isEmpty ? null : Text(i.subtitle),
                onTap: () => context.go(i.route),
              ),
          ],
        ),
      ),
    );
  }
}

/// A compact search box for the app bar. Press "/" anywhere on desktop to
/// focus it; Enter opens `/search?q=`. Place it in the top bar.
class GlobalSearchField extends StatefulWidget {
  const GlobalSearchField({super.key, this.width = 280});

  final double width;

  @override
  State<GlobalSearchField> createState() => _GlobalSearchFieldState();
}

class _GlobalSearchFieldState extends State<GlobalSearchField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.slash) {
      return false;
    }
    // Typing a slash into a text field must stay a slash.
    final primary = FocusManager.instance.primaryFocus;
    if (primary?.context?.findAncestorWidgetOfExactType<EditableText>() !=
        null) {
      return false;
    }
    _focus.requestFocus();
    return true;
  }

  void _go(String v) {
    final q = v.trim();
    if (q.length < 2) return;
    context.go(Uri(path: '/search', queryParameters: {'q': q}).toString());
    _controller.clear();
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    child: TextField(
      key: const ValueKey('global-search'),
      controller: _controller,
      focusNode: _focus,
      textInputAction: TextInputAction.search,
      onSubmitted: _go,
      // Fits the 46 px top bar with a little room above and below.
      decoration: const InputDecoration(
        isDense: true,
        prefixIcon: Icon(Icons.search, size: 20),
        prefixIconConstraints: BoxConstraints(minWidth: 36, minHeight: 32),
        constraints: BoxConstraints(maxHeight: 34),
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        hintText: 'Search (press /)',
      ),
    ),
  );
}
