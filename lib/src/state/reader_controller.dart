import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../api/funread_api.dart';
import '../models/models.dart';

/// 正文页的状态机：取正文、翻章、回写进度。
///
/// 目录和 [BookInfo] 由详情页**传进来**，这里不重新抓。
/// funread-web 那边每进一次正文页都要重跑 `/reader/book` + `/reader/toc`，
/// 因为它的页面状态只能从 URL 恢复；Flutter 是对象导航，没有这个约束。
/// 省掉的不只是两次请求 —— 那两步各自都可能失败或者读到空，
/// 而且 `BookInfo.variables` 原样带在对象上，结构上就丢不掉。
class ReaderController extends ChangeNotifier {
  ReaderController({
    required FunreadApi api,
    required BookRef ref,
    required BookInfo info,
    required List<Chapter> chapters,
    required int position,
    int charOffset = 0,
    bool onShelf = false,
    this.saveThrottle = const Duration(seconds: 3),
  })  : _api = api,
        _ref = ref,
        _info = info,
        _chapters = chapters,
        _onShelf = onShelf,
        _position = chapters.isEmpty
            ? 0
            : math.max(0, math.min(position, chapters.length - 1)),
        _restoreOffset = charOffset,
        _pendingOffset = charOffset;

  final FunreadApi _api;
  final BookRef _ref;
  final BookInfo _info;
  final List<Chapter> _chapters;
  final bool _onShelf;

  /// 进度回写的节流窗口。
  ///
  /// 不节流的话滚动时每一帧都打一次库；只节流不补写则会丢掉最后一段 ——
  /// 读者往往读到一半就直接切走。所以节流 + 离开时 [flush] 两者都要。
  final Duration saveThrottle;

  int _position;
  ChapterContent? _content;
  bool _loading = false;
  String? _error;

  /// 过期响应的丢弃令牌。连点「下一章」时，先发后到的旧正文会覆盖新章。
  int _generation = 0;

  /// 每次有新正文落地就 +1。界面用它判断「该恢复滚动位置了」，
  /// 而不是去比较内容是否相等（同一章重试两次内容是一样的）。
  int _revision = 0;

  /// 这一章要恢复到的字符偏移。翻章后是 0，恢复进度时是存下来的值。
  int _restoreOffset;

  int _pendingOffset;
  Timer? _saveTimer;

  /// 有没有「还没写回去的进度」。
  ///
  /// 没有它的话，退出页面时一定会多打一次 PUT —— 刚进一章、一行没滚就返回，
  /// 这次写的内容和进章时写的那次一模一样。
  bool _dirty = false;

  BookRef get ref => _ref;
  BookInfo get info => _info;
  List<Chapter> get chapters => _chapters;
  int get position => _position;
  ChapterContent? get content => _content;
  bool get loading => _loading;
  String? get error => _error;
  int get revision => _revision;
  int get restoreOffset => _restoreOffset;

  /// 不在书架 = 试读。能读，但没有可写的进度记录（后端会 404）。
  bool get onShelf => _onShelf;

  Chapter? get current =>
      _position >= 0 && _position < _chapters.length ? _chapters[_position] : null;

  bool get hasPrev => _position > 0;
  bool get hasNext => _position < _chapters.length - 1;

  /// 正文按空行切段。源站给的正文是纯文本，段落之间可能是 `\n` 也可能是
  /// 连续多个换行，统一成「非空行即一段」。
  List<String> get paragraphs {
    final String text = _content?.text ?? '';
    if (text.isEmpty) return const <String>[];
    return <String>[
      for (final String line in text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
  }

  int get totalChars => _content?.text.length ?? 0;

  Future<void> load() async {
    final Chapter? chapter = current;
    if (chapter == null) {
      _error = '目录是空的，没有可读的章节。';
      notifyListeners();
      return;
    }
    final int token = ++_generation;
    _loading = true;
    _error = null;
    _content = null;
    notifyListeners();
    try {
      final ChapterContent content = await _api.reader.content(
        urlId: _ref.urlId,
        chapter: chapter,
        // 整个 BookInfo 要带上：正文规则可能 `@get` 详情页 `@put` 的变量。
        book: _info,
        // 带 book_key 才走服务端那层章节缓存（命中直接读，未命中抓完写回）。
        // 不带就是每次都实抓源站 —— 回头看同一章要再等十几秒，
        // 而且多打一次源站就多一分被封的机会。
        bookKey: _ref.bookKey,
      );
      if (token != _generation) return;
      _content = content;
      _revision++;
      // 进了这一章就先把「读到这一章」落下去。只靠滚动触发的话，
      // 短到不需要滚动的章节永远不会被记进进度。
      _pendingOffset = _restoreOffset;
      _dirty = true;
      unawaited(_save());
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

  /// 跳到目录里的第 [target] 章。越界直接忽略。
  Future<void> goTo(int target) async {
    if (target < 0 || target >= _chapters.length || target == _position) return;
    // 翻章前把当前这一章读到哪落下去，否则节流窗口里的那一段就丢了。
    await flush();
    _position = target;
    _restoreOffset = 0;
    _pendingOffset = 0;
    await load();
  }

  Future<void> prev() => hasPrev ? goTo(_position - 1) : Future<void>.value();

  Future<void> next() => hasNext ? goTo(_position + 1) : Future<void>.value();

  /// 滚动位置变了。只记下来并开一个节流窗口，不立刻发请求。
  void onOffsetChanged(int charOffset) {
    if (charOffset == _pendingOffset) return;
    _pendingOffset = charOffset;
    _dirty = true;
    // 已经有窗口在跑就不重开 —— 这是节流（固定间隔写一次），
    // 不是防抖（一直滚就一直不写，正好是最该写的时候不写）。
    _saveTimer ??= Timer(saveThrottle, () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  /// 立刻把攒着的进度写掉。翻章前、离开页面时都要调。
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _save();
  }

  Future<void> _save() async {
    // 试读（书不在书架）没有可写的进度记录，后端会 404。直接不发，
    // 省得每个节流窗口都打一次注定失败的请求。
    if (!_onShelf || !_dirty) return;
    final Chapter? chapter = current;
    if (chapter == null) return;
    _dirty = false;
    try {
      await _api.shelf.saveProgress(
        _ref.bookKey,
        chapterIndex: chapter.index,
        chapterUrl: chapter.url,
        chapterName: chapter.name,
        // 字符偏移而不是滚动像素：换了字号、设备或字体之后像素值毫无意义，
        // 字符偏移至少还能按比例换算回大致位置。
        charOffset: _pendingOffset,
      );
    } on ApiException {
      // 进度写失败不该打断阅读。标回脏，下一个节流窗口会再试一次。
      _dirty = true;
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _saveTimer = null;
    // 补最后一次写。dispose 不能 await，但请求已经发出去了 ——
    // 丢掉的只有「写失败时的重试」，而那一次重试本来也没地方去。
    if (_dirty) unawaited(_save());
    super.dispose();
  }
}

/// 滚动位置 ↔ 章内字符偏移。
///
/// 进度存字符偏移、不存滚动像素：像素值和字号、行距、屏幕宽度绑死，换台设备
/// 就是个随机数。字符偏移按「已读字符 / 总字符」乘可滚高度换算回去，**不精确
/// 但稳定** —— 段落长短不均，所以同一个偏移在不同字号下落点会差几行，
/// 这个误差是可以接受的，像素值的误差则是整章。
class ReadingPosition {
  const ReadingPosition._();

  /// 当前滚动位置对应的字符偏移。
  static int offsetOf({
    required double pixels,
    required double maxExtent,
    required int totalChars,
  }) {
    // 内容一屏装得下（maxExtent == 0）时没有「读到哪」可言，记 0。
    if (totalChars <= 0 || maxExtent <= 0) return 0;
    final double ratio = pixels / maxExtent;
    // 过冲（下拉回弹）会让比例跑到 [0,1] 之外，夹住，否则存进去一个
    // 大于总字数的偏移，下次恢复时直接落到章尾。
    if (ratio <= 0) return 0;
    if (ratio >= 1) return totalChars;
    return (ratio * totalChars).round();
  }

  /// 字符偏移对应的滚动位置。
  static double pixelsOf({
    required int charOffset,
    required int totalChars,
    required double maxExtent,
  }) {
    if (charOffset <= 0 || totalChars <= 0 || maxExtent <= 0) return 0;
    if (charOffset >= totalChars) return maxExtent;
    return charOffset / totalChars * maxExtent;
  }
}
