import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/novel.dart';
import '../utils/app_logger.dart';

/// Offset pagination shared by novel books, collections and comments.
/// Every refresh invalidates outstanding requests, including their error paths.
class NovelPagedController<T> extends ChangeNotifier {
  NovelPagedController({required this.loadPage, required this.keyOf});

  final Future<NovelPage<T>> Function(int offset) loadPage;
  final String Function(T item) keyOf;
  List<T> items = [];
  bool loading = false;
  bool refreshing = false;
  bool hasMore = true;
  Object? error;
  Object? refreshError;
  int _offset = 0;
  int _generation = 0;
  bool _disposed = false;

  void clear() {
    _generation++;
    items = [];
    loading = false;
    refreshing = false;
    hasMore = true;
    error = null;
    refreshError = null;
    _offset = 0;
    notifyListeners();
  }

  /// Keep the current query's results visible during pull-to-refresh.
  /// New queries and filters still clear immediately by default.
  Future<void> refresh({bool keepItems = false}) {
    if (_disposed) return Future.value();
    if (keepItems) {
      _generation++;
      loading = false;
    } else {
      clear();
    }
    return _loadPage(replace: true);
  }

  Future<void> loadMore() => _loadPage();

  Future<void> _loadPage({bool replace = false}) async {
    if (_disposed ||
        loading ||
        (!replace && (!hasMore || refreshError != null))) {
      return;
    }
    final generation = _generation;
    final offset = replace ? 0 : _offset;
    loading = true;
    refreshing = replace;
    error = null;
    refreshError = null;
    notifyListeners();
    try {
      final page = await loadPage(offset);
      if (_disposed || generation != _generation) return;
      final previous = replace ? <T>[] : items;
      final seen = previous.map(keyOf).toSet();
      items = [
        ...previous,
        ...page.list.where((item) => seen.add(keyOf(item))),
      ];
      // Advance by raw results, not by the deduplicated visible item count.
      _offset = page.offset + page.list.length;
      hasMore = page.hasMore && _offset > offset;
    } catch (e, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: stack,
          source: 'novel.pagination',
        ),
      );
      if (_disposed || generation != _generation) return;
      if (replace && items.isNotEmpty) {
        refreshError = e;
      } else {
        error = e;
      }
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        refreshing = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
