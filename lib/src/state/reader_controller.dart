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
  List<ChapterParagraph> _paragraphs = const <ChapterParagraph>[];
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

  /// 等用户回答的「别处读到了新进度」。非空期间**一次进度都不写**，
  /// 见 [checkRemoteProgress]。
  ProgressConflict? _conflict;

  /// 正在问服务端。防止前台切换抖动时连打好几次 `/shelf`。
  bool _checking = false;

  /// 有没有「还没写回去的进度」。
  ///
  /// 没有它的话，退出页面时一定会多打一次 PUT —— 刚进一章、一行没滚就返回，
  /// 这次写的内容和进章时写的那次一模一样。
  bool _dirty = false;

  BookRef get ref => _ref;
  List<Chapter> get chapters => _chapters;
  int get position => _position;
  ChapterContent? get content => _content;
  bool get loading => _loading;
  String? get error => _error;
  int get revision => _revision;
  int get restoreOffset => _restoreOffset;

  /// 不在书架 = 试读。能读，但没有可写的进度记录（后端会 404）。
  bool get onShelf => _onShelf;

  /// 待用户回答的进度冲突。界面据此弹窗，`null` = 没有要问的。
  ProgressConflict? get conflict => _conflict;

  Chapter? get current =>
      _position >= 0 && _position < _chapters.length ? _chapters[_position] : null;

  bool get hasPrev => _position > 0;
  bool get hasNext => _position < _chapters.length - 1;

  /// 正文按空行切段，每段带着它在原文里的起始下标。
  ///
  /// 切好了存着而不是每次 get 现切：滚动时每一帧都要问它，
  /// 几万字的章节上现切就是每帧一次全章扫描。
  List<ChapterParagraph> get paragraphs => _paragraphs;

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
    _paragraphs = const <ChapterParagraph>[];
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
      _paragraphs = splitParagraphs(content.text);
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

  /// 回到前台时问一次服务端：别的设备有没有读到别的地方。
  ///
  /// 进度是一人一本书**一条**记录、后写覆盖先写。顺序使用没问题，但有个很常见
  /// 的场景会咬人：这一页一直开着没关，人在手机上读到了第 100 章，回头碰一下
  /// 这个停在第 30 章的页面滚一下 —— 旧进度就把新的盖掉了。
  ///
  /// **只问不跳。** 自动跳转会在「我就是想回头重读前面几章」时把人强行拽走，
  /// 而那种情况下服务端进度同样比本地靠后，程序分不出来，只有人能分。
  ///
  /// 问到冲突之后到用户回答之前**停写**：否则 resumed 那一下的滚动事件会抢在
  /// 用户点「跳过去」之前把远端进度盖掉，那就白问了。
  Future<void> checkRemoteProgress() async {
    // 试读没有进度记录，问了也只是白打一次 404。
    if (!_onShelf || _chapters.isEmpty || _conflict != null || _checking) return;
    _checking = true;
    ReadingProgress? remote;
    try {
      final List<ShelfBook> shelf = await _api.shelf.list();
      for (final ShelfBook book in shelf) {
        if (book.bookKey == _ref.bookKey) {
          remote = book.progress;
          break;
        }
      }
    } on ApiException {
      // 掉线或者会话过期都走这里。问不到就当没问过 —— 本地照常读、照常写，
      // 这比弹一个「同步失败」更合适：用户什么都做不了。
      return;
    } finally {
      _checking = false;
    }
    if (remote == null) return;
    final int target = positionOfChapter(_chapters, remote.chapterIndex);
    // 同一章就别打扰。章内偏移差几段是「同一个人刚才在这读」的常态，
    // 为它弹窗等于每次切回前台都弹。
    if (target < 0 || target == _position) return;
    _conflict = ProgressConflict(
      position: target,
      localPosition: _position,
      charOffset: remote.charOffset,
      chapterName: remote.chapterName.isNotEmpty
          ? remote.chapterName
          : _chapters[target].name,
    );
    notifyListeners();
  }

  /// 「跳过去」：采纳服务端进度。
  Future<void> acceptRemoteProgress() async {
    final ProgressConflict? conflict = _conflict;
    if (conflict == null) return;
    _conflict = null;
    // 本地那段没写出去的进度要丢掉 —— 用户刚说了以远端为准。
    _dirty = false;
    _saveTimer?.cancel();
    _saveTimer = null;
    _position = conflict.position;
    _restoreOffset = conflict.charOffset;
    _pendingOffset = conflict.charOffset;
    await load();
  }

  /// 「留在这里」：本地位置就是对的，解禁回写。
  ///
  /// 立刻写一次而不是等下一个节流窗口：用户已经明确选了以这边为准，
  /// 拖着不写的话，另一台设备在这期间再读一下又会把它翻过来。
  void keepLocalProgress() {
    if (_conflict == null) return;
    _conflict = null;
    _dirty = true;
    unawaited(_save());
    notifyListeners();
  }

  Future<void> _save() async {
    // 试读（书不在书架）没有可写的进度记录，后端会 404。直接不发，
    // 省得每个节流窗口都打一次注定失败的请求。
    if (!_onShelf || !_dirty) return;
    // 有没回答的冲突时一个字节都不写。`_dirty` 保持着，用户选「留在这里」
    // 之后这一笔会补上。
    if (_conflict != null) return;
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

/// 一个**待回答的问题**：服务端的进度和这一页停的位置对不上。
///
/// 它不是「已经发生的跳转」。构造出它来只意味着界面该弹窗了，
/// 跳不跳由用户决定（[ReaderController.acceptRemoteProgress] /
/// [ReaderController.keepLocalProgress]）。
@immutable
class ProgressConflict {
  const ProgressConflict({
    required this.position,
    required this.localPosition,
    required this.charOffset,
    required this.chapterName,
  });

  /// 服务端进度在目录里的下标。
  final int position;

  /// 这一页当前停在的下标。弹窗里要把两边都说出来，
  /// 只说「别处读到第 100 章」用户没法判断该不该跳。
  final int localPosition;

  /// 服务端那条记录的章内偏移。跳过去之后要落在这里。
  final int charOffset;

  /// 服务端记的章节名。优先用它而不是本地目录里的名字 —— 两边可能是不同的源。
  final String chapterName;
}
