import 'package:flutter/foundation.dart';

import '../config/settings_store.dart';
import '../models/models.dart';

/// 排版设置的持有者。
///
/// 它是第三个长生命周期对象（前两个是 `FunreadApi` 和 `AuthController`）：
/// 设置要跨章节、跨书、跨页面活着，挂在 `ReaderScreen` 上的话，
/// 退出正文再进来就回到默认值了。
///
/// **不同步到服务端。** 手机和桌面的合适字号本来就不一样，同步过去只会
/// 让两边互相打架。进度要同步，排版不要 —— 见 [ReaderSettings] 的类注释。
class ReaderSettingsController extends ChangeNotifier {
  ReaderSettingsController({SettingsStore? store, ReaderSettings? initial})
      : _store = store ?? SettingsStore(),
        _value = initial ?? const ReaderSettings();

  final SettingsStore _store;
  ReaderSettings _value;

  ReaderSettings get value => _value;

  /// 冷启动时把存下来的设置读回来。
  ///
  /// 读不出来就保持默认，不抛也不等 —— 偏好读失败最多是字号回到 18，
  /// 为它卡住启动是本末倒置。
  Future<void> load() async {
    final ReaderSettings loaded = await _store.loadReaderSettings();
    if (loaded == _value) return;
    _value = loaded;
    notifyListeners();
  }

  /// 只改内存并通知，**不落盘**。
  ///
  /// 拖滑块一秒钟几十次，每一次都写一遍偏好没有意义。松手时调 [persist]，
  /// 或者直接用 [commit]。
  void update(ReaderSettings next) {
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }

  Future<void> persist() => _store.saveReaderSettings(_value);

  /// 一次性的改动（切主题）用它：改完立刻落盘。
  Future<void> commit(ReaderSettings next) async {
    update(next);
    await persist();
  }
}
