import 'dart:async';

import 'package:flutter/material.dart';

/// A search box that reports changes after the user pauses typing.
class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    required this.onChanged,
    this.hintText = 'Search',
    this.debounce = const Duration(milliseconds: 350),
    this.autofocus = false,
  });

  final ValueChanged<String> onChanged;
  final String hintText;
  final Duration debounce;
  final bool autofocus;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  final _controller = TextEditingController();
  Timer? _timer;

  void _changed(String value) {
    _timer?.cancel();
    _timer = Timer(widget.debounce, () => widget.onChanged(value.trim()));
    setState(() {});
  }

  void _clear() {
    _timer?.cancel();
    _controller.clear();
    widget.onChanged('');
    setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    autofocus: widget.autofocus,
    onChanged: _changed,
    textInputAction: TextInputAction.search,
    decoration: InputDecoration(
      hintText: widget.hintText,
      prefixIcon: const Icon(Icons.search),
      isDense: true,
      suffixIcon: _controller.text.isEmpty
          ? null
          : IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.clear),
              onPressed: _clear,
            ),
    ),
  );
}
