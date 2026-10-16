import 'package:flutter/foundation.dart';

import '../api/funread_api.dart';
import '../models/models.dart';

/// 详情页的状态机：书架记录 → `/reader/book` → `/reader/toc`。
///
/// 两件事值得单独说：
///
///  - **详情和目录是两个独立的失败域。** 详情能出来、目录抓不到是很常见的
///    （目录往往要再打一次源站，有的源还是分页抓的）。合成一个 error 的话，
///    用户只会看到「这本书打不开」，而实际上书名简介都在手上，重试目录即可。
///  - **书架记录只是可选的增强。** 不在书架也要能读（试读），所以 `/shelf`
///    的 401 / 网络失败在这里被吃掉，当作「不在书架」继续走。后端的
///    `/reader/book` `/reader/toc` `/reader/content` 都不要求登录。
class BookDetailController extends ChangeNotifier {
  BookDetailController({required FunreadApi api, required BookRef ref})
      : _api = api,
        _ref = ref;

  final FunreadApi _api;

  BookRef _ref;
  bool _loading = false;
  String? _error;
  BookInfo? _info;
  bool _tocLoading = false;
  String? _tocError;
  List<Chapter> _chapters = const <Chapter>[];
  ShelfBook? _shelfBook;
  bool _onShelf = false;
  bool _shelfBusy = false;

  BookRef get ref => _ref;
  bool get loading => _loading;
  String? get error => _error;
  BookInfo? get info => _info;
  bool get tocLoading => _tocLoading;
  String? get tocError => _tocError;
  List<Chapter> get chapters => _chapters;

  /// 书架里的那条记录。`null` 有两种原因：不在书架，或者没登录看不到书架。
  /// 对阅读链路来说这两者是一回事 —— 都读得了，只是存不了进度。
  ShelfBook? get shelfBook => _shelfBook;
  bool get onShelf => _onShelf;

  /// 加入 / 移出书架在飞。按钮据此禁用。
  bool get shelfBusy => _shelfBusy;

  /// 上次读到第几章（目录里的下标）。-1 = 没有进度，从头开始。
  int get progressPosition {
    final ReadingProgress? progress = _shelfBook?.progress;
    if (progress == null) return -1;
    return positionOfChapter(_chapters, progress.chapterIndex);
  }

  int get progressOffset => _shelfBook?.progress?.charOffset ?? 0;

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await _loadShelf();
      if (!_ref.isUsable) {
        _error = '缺少来源信息（url_id / book_url），请从搜索结果进入。';
        return;
      }
      _info = await _api.reader.bookInfo(
        urlId: _ref.urlId,
        bookUrl: _ref.bookUrl,
        name: _ref.name,
        author: _ref.author,
      );
    } on ApiException catch (error) {
      _error = error.message;
    } finally {
      _loading = false;
      notifyListeners();
    }
    // 详情失败就没有 BookInfo 可以喂给目录，不必再白跑一趟。
    if (_error == null) await loadToc();
  }

  /// 目录。
  ///
  /// 入参是**整个** [BookInfo]（含 variables）—— 详情页的规则会用 `@put` 存
  /// 变量，目录规则用 `@get` 取回来。这里只传 url 的话，带变量的源会静默
  /// 返回空目录，看起来就像「这本书没有章节」。
  Future<void> loadToc() async {
    final BookInfo? info = _info;
    if (info == null) return;
    _tocLoading = true;
    _tocError = null;
    notifyListeners();
    try {
      final TocPage page = await _api.reader.toc(_ref.urlId, info);
      _chapters = page.items;
      if (_chapters.isEmpty) {
        _tocError = '这个源没有返回任何章节。换一个源试试 —— '
            '书源池里能跑通的只有个位数百分比。';
      }
    } on ApiException catch (error) {
      _tocError = error.message;
    } finally {
      _tocLoading = false;
      notifyListeners();
    }
  }

  /// 加入书架。返回一句给用户看的话（成功和失败都有）。
  Future<String> addToShelf() async {
    final BookInfo? info = _info;
    if (info == null || _shelfBusy) return '';
    _shelfBusy = true;
    notifyListeners();
    try {
      final String key = await _api.shelf.addBook(info, urlId: _ref.urlId);
      // 以后端算出来的 key 为准：进度、服务端章节缓存都挂在它下面，
      // 用错一个字符就是「进度存进了另一本书」。
      if (key.isNotEmpty) _ref = _ref.withBookKey(key);
      _onShelf = true;
      // 刚加进来的书没有进度，不必再拉一次整个书架去确认这件事。
      _shelfBook = null;
      return '已加入书架';
    } on UnauthorizedException {
      return '书架需要登录。没登录也能接着读，只是进度存不下来。';
    } on ApiException catch (error) {
      return error.message;
    } finally {
      _shelfBusy = false;
      notifyListeners();
    }
  }

  /// 移出书架。进度跟着没了，所以界面要先确认。
  Future<String> removeFromShelf() async {
    if (!_onShelf || _shelfBusy) return '';
    _shelfBusy = true;
    notifyListeners();
    try {
      await _api.shelf.remove(_ref.bookKey);
      _onShelf = false;
      _shelfBook = null;
      return '已移出书架';
    } on ApiException catch (error) {
      return error.message;
    } finally {
      _shelfBusy = false;
      notifyListeners();
    }
  }

  Future<void> _loadShelf() async {
    try {
      final List<ShelfBook> shelf = await _api.shelf.list();
      for (final ShelfBook book in shelf) {
        if (book.bookKey == _ref.bookKey) {
          _shelfBook = book;
          _onShelf = true;
          return;
        }
      }
      _shelfBook = null;
      _onShelf = false;
    } on ApiException {
      // 没登录（401）或者书架接口挂了都走这里。试读不需要身份，
      // 把它当成「不在书架」继续往下走，不要让整页报错。
      _shelfBook = null;
      _onShelf = false;
    }
  }
}
