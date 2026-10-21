import 'package:flutter/foundation.dart';

import '../core/json.dart';

typedef PageFetcher<T> = Future<Paged<T>> Function(int offset, int limit);

/// Loads a list endpoint page by page. Filters are read by [fetch] at call
/// time, so changing a filter is just `refresh()`.
class PagedController<T> extends ChangeNotifier {
  PagedController(this.fetch, {this.pageSize = 50});

  final PageFetcher<T> fetch;
  final int pageSize;

  List<T> items = const [];
  int total = 0;
  bool loading = false;
  bool loaded = false;
  Object? error;

  int _generation = 0;
  bool _disposed = false;

  bool get hasMore => items.length < total;

  Future<void> refresh() async {
    final generation = ++_generation;
    loading = true;
    error = null;
    _notify();
    try {
      final page = await fetch(0, pageSize);
      if (generation != _generation) return;
      items = page.data;
      total = page.total;
    } catch (e) {
      if (generation != _generation) return;
      items = const [];
      total = 0;
      error = e;
    }
    loading = false;
    loaded = true;
    _notify();
  }

  Future<void> loadMore() async {
    if (loading || !hasMore) return;
    final generation = _generation;
    loading = true;
    error = null;
    _notify();
    try {
      final page = await fetch(items.length, pageSize);
      if (generation != _generation) return;
      items = [...items, ...page.data];
      total = page.total;
    } catch (e) {
      if (generation != _generation) return;
      error = e;
    }
    loading = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
