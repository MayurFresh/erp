import 'package:flutter/material.dart';

import 'search_field.dart';
import 'states.dart';

/// Opens a searchable picker and returns the chosen value (or `null`).
/// Full screen on phones, a dialog on wider screens.
Future<T?> showSearchPicker<T>({
  required BuildContext context,
  required String title,
  required Future<List<T>> Function(String query) search,
  required Widget Function(BuildContext context, T value) titleBuilder,
  Widget Function(BuildContext context, T value)? subtitleBuilder,
  Widget Function(BuildContext context, T value)? trailingBuilder,
  String hintText = 'Search',
  String emptyMessage = 'No matches.',
}) {
  return showDialog<T>(
    context: context,
    builder: (context) => _SearchPickerDialog<T>(
      title: title,
      search: search,
      titleBuilder: titleBuilder,
      subtitleBuilder: subtitleBuilder,
      trailingBuilder: trailingBuilder,
      hintText: hintText,
      emptyMessage: emptyMessage,
    ),
  );
}

class _SearchPickerDialog<T> extends StatefulWidget {
  const _SearchPickerDialog({
    required this.title,
    required this.search,
    required this.titleBuilder,
    this.subtitleBuilder,
    this.trailingBuilder,
    required this.hintText,
    required this.emptyMessage,
  });

  final String title;
  final Future<List<T>> Function(String query) search;
  final Widget Function(BuildContext, T) titleBuilder;
  final Widget Function(BuildContext, T)? subtitleBuilder;
  final Widget Function(BuildContext, T)? trailingBuilder;
  final String hintText;
  final String emptyMessage;

  @override
  State<_SearchPickerDialog<T>> createState() => _SearchPickerDialogState<T>();
}

class _SearchPickerDialogState<T> extends State<_SearchPickerDialog<T>> {
  String _query = '';
  List<T> _results = const [];
  Object? _error;
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await widget.search(_query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
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

  Widget _body() {
    if (_loading && _results.isEmpty) return const LoadingView();
    if (_error != null) return ErrorView(error: _error!, onRetry: _run);
    if (_results.isEmpty) return EmptyView(message: widget.emptyMessage);
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final value = _results[i];
        return ListTile(
          title: widget.titleBuilder(context, value),
          subtitle: widget.subtitleBuilder?.call(context, value),
          trailing: widget.trailingBuilder?.call(context, value),
          onTap: () => Navigator.of(context).pop(value),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final fullScreen = MediaQuery.sizeOf(context).width < 600;
    final content = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: SearchField(
            autofocus: true,
            hintText: widget.hintText,
            onChanged: (q) {
              _query = q;
              _run();
            },
          ),
        ),
        if (_loading && _results.isNotEmpty)
          const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _body()),
      ],
    );
    final header = AppBar(
      automaticallyImplyLeading: false,
      title: Text(widget.title),
      actions: [
        IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
    if (fullScreen) {
      return Dialog.fullscreen(
        child: Scaffold(appBar: header, body: content),
      );
    }
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Scaffold(appBar: header, body: content),
      ),
    );
  }
}
