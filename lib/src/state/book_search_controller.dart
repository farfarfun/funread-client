import 'package:flutter/foundation.dart';

import '../api/funread_api.dart';
import '../models/models.dart';

/// 搜索页的状态机。
///
/// 名字刻意不叫 `SearchController` —— Material 自己有一个同名的类
/// （配 `SearchAnchor` 用），重名会让 import 变成拼图游戏。
class BookSearchController extends ChangeNotifier {
  BookSearchController(this._api);

  final FunreadApi _api;

  /// 过期响应的丢弃令牌。
  ///
  /// 一次搜索可能跑十几秒，这期间用户很可能已经改了关键词又搜了一次。
  /// 没有这个计数器，先发后到的旧响应会把新结果覆盖掉 —— 表现为
  /// 「搜 A 出来 B 的结果」，而且偶发、难复现。
  int _generation = 0;

  String _keyword = '';
  bool _loading = false;
  String? _error;
  SearchPage? _page;

  String get keyword => _keyword;
  bool get loading => _loading;
  String? get error => _error;
  SearchPage? get page => _page;
  List<SearchBook> get items => _page?.items ?? const <SearchBook>[];

  /// 搜过至少一次。界面用它区分「还没搜」和「搜了没结果」。
  bool get hasSearched => _page != null || _error != null;

  Future<void> search(String keyword) async {
    final String trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    final int token = ++_generation;
    _keyword = trimmed;
    _loading = true;
    _error = null;
    _page = null;
    notifyListeners();

    try {
      final SearchPage page = await _api.reader.search(trimmed);
      if (token != _generation) return;
      _page = page;
    } on ApiException catch (error) {
      if (token != _generation) return;
      _error = error.message;
    } finally {
      if (token == _generation) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// 清空结果，回到初始态。
  void reset() {
    // 顺带作废在飞的请求，否则清空之后结果还会自己蹦出来。
    _generation++;
    _keyword = '';
    _loading = false;
    _error = null;
    _page = null;
    notifyListeners();
  }
}
