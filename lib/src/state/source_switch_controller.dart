import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/funread_api.dart';
import '../models/models.dart';

/// 换源面板的状态机：拉候选 → 选一个 → 提交。
///
/// 三件事是这个类存在的理由，都来自后端行为而不是界面偏好：
///
///  1. **候选列表是一次实时聚合搜索，很慢。** 所以有 [elapsed]：不报时的话
///     十几秒的等待和「卡死了」在屏幕上长得一模一样。也因此**不缓存** ——
///     缓存住上一次的结果就等于「源挂了之后换源列表还是那批挂掉的源」，
///     恰好在最需要它的时候没用。
///  2. **换源要求书在书架。** 后端要读调用者自己的书架记录才知道书名，不在
///     书架就是 404。所以这里先拦一道并说清原因，入口也该是禁用态 ——
///     让人点出一个 404 是最糟的解释方式。
///  3. **提交之前必须把进度写掉。** 后端是拿**库里那条记录**的章节名去新源
///     目录里找同一章的，不是拿请求里的任何字段。少写这一步的表现是「换完
///     源回到第一章」，而且只在「读到一半才换源」时出现 —— 正是主场景。
///     所以 [saveProgressFirst] 是构造参数而不是调用方的自觉。
class SourceSwitchController extends ChangeNotifier {
  SourceSwitchController({
    required FunreadApi api,
    required String bookKey,
    required bool onShelf,
    this.saveProgressFirst,
    this.tick = const Duration(seconds: 1),
  })  : _api = api,
        _bookKey = bookKey,
        _onShelf = onShelf;

  final FunreadApi _api;
  final String _bookKey;
  final bool _onShelf;

  /// 提交换源之前要跑的那一步（正文页传 `ReaderController.flush`）。
  /// 详情页没有在飞的进度，传 `null`。
  final Future<void> Function()? saveProgressFirst;

  /// 计时的粒度。测试里调小，省得为了看到秒数变化等一整秒。
  final Duration tick;

  bool _loading = false;
  String? _error;
  SwitchSourcePage? _page;
  bool _switching = false;
  Duration _elapsed = Duration.zero;
  Timer? _timer;

  /// 过期响应的丢弃令牌。换源列表要十几秒，这期间用户完全可能点了「再搜一次」。
  int _generation = 0;

  bool get loading => _loading;

  /// 取列表失败的原因，或者「为什么根本没去取」（不在书架）。
  String? get error => _error;

  SwitchSourcePage? get page => _page;

  /// 已经提交了换源，在等后端重定位进度。期间整个列表要禁用。
  bool get switching => _switching;

  /// 这一轮等了多久。界面把它显示出来 —— 用户能接受慢，不能接受不知道在等什么。
  Duration get elapsed => _elapsed;

  /// 书在不在书架。为假时 [load] 不会发请求。
  bool get onShelf => _onShelf;

  Future<void> load() async {
    if (_loading || _switching) return;
    if (!_onShelf) {
      // 这不是「加载失败」，是一个前置条件没满足。说清楚它，
      // 顺带说清为什么 —— 否则「加入书架」和「换源」看不出有什么关系。
      _page = null;
      _error = '换源需要先把这本书加入书架。'
          '后端要靠书架里那条记录恢复书名才能跨源搜索，试读时那条记录不存在。';
      notifyListeners();
      return;
    }
    final int token = ++_generation;
    _loading = true;
    _error = null;
    _page = null;
    _startClock();
    notifyListeners();
    try {
      final SwitchSourcePage page = await _api.reader.sources(_bookKey);
      if (token != _generation) return;
      _page = page;
    } on ApiException catch (error) {
      if (token != _generation) return;
      _error = error.message;
    } finally {
      if (token == _generation) {
        _loading = false;
        _stopClock();
        notifyListeners();
      }
    }
  }

  /// 切到 [candidate]。成功返回后端给的定位结果，失败返回 `null` 并把原因
  /// 放进 [error]。
  ///
  /// 调用方拿到结果之后**必须用新源把整条链重算一遍**（`/reader/book` →
  /// `/reader/toc` → `/reader/content`）：`BookInfo.variables` 是上一个源的
  /// 规则状态，目录序号的含义也变了，一个都不能沿用。
  Future<SwitchSourceResult?> switchTo(SwitchCandidate candidate) async {
    if (_switching || !_onShelf) return null;
    _switching = true;
    _error = null;
    notifyListeners();
    try {
      // 先把读到哪写下去 —— 后端按库里那条记录定位，不按请求体。
      await saveProgressFirst?.call();
      return await _api.shelf.switchSource(
        _bookKey,
        urlId: candidate.urlId,
        bookUrl: candidate.bookUrl,
      );
    } on ApiException catch (error) {
      _error = error.message;
      return null;
    } finally {
      _switching = false;
      notifyListeners();
    }
  }

  void _startClock() {
    _elapsed = Duration.zero;
    _timer?.cancel();
    _timer = Timer.periodic(tick, (Timer timer) {
      _elapsed += tick;
      notifyListeners();
    });
  }

  void _stopClock() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    // 面板关掉之后计时器还在跑的话，它会继续 notify 一个已经 dispose 的
    // ChangeNotifier，而那是一条断言失败。
    _stopClock();
    // 在飞的请求没法取消（dio 的 CancelToken 没接进来），但令牌一变，
    // 它回来时就不会再去碰状态了。
    _generation++;
    super.dispose();
  }
}
