import 'package:flutter/foundation.dart';

import '../api/funread_api.dart';
import '../config/settings_store.dart';
import '../models/models.dart';

/// 启动闸门的四种状态。用枚举而不是三个布尔，是因为「加载中 + 出错」
/// 这种组合根本不存在，用布尔表达就要靠约定来排除。
enum AuthStage {
  /// 正在问 `/auth/me`，还不知道该渲染什么。
  checking,

  /// 要登录。
  loggedOut,

  /// 有身份了（可能是真账号，也可能是后端的隐式本地身份）。
  loggedIn,

  /// 连不上后端。和 [loggedOut] 必须分开：让用户在一个连不上的服务器上
  /// 反复输密码是最糟糕的体验，这种情况该引导他改地址。
  unreachable,
}

/// 会话状态。应用里唯一的真相来源，登录页和主界面都读它。
class AuthController extends ChangeNotifier {
  AuthController({required FunreadApi api, SettingsStore? settings})
      : _api = api,
        _settings = settings ?? SettingsStore();

  final FunreadApi _api;
  final SettingsStore _settings;

  AuthStage _stage = AuthStage.checking;
  SessionState _session = SessionState.anonymous;
  String? _error;
  bool _busy = false;

  AuthStage get stage => _stage;
  SessionState get session => _session;

  /// 给界面看的最近一次失败原因。换屏时清空。
  String? get error => _error;

  /// 有请求在飞。按钮据此禁用，避免重复提交。
  bool get busy => _busy;

  String get baseUrl => _api.baseUrl;

  /// 冷启动：先把存下来的地址装回去，再探一次会话。
  ///
  /// 顺序不能反 —— 先探会用默认地址打，用户配的那台机器根本没被问到。
  Future<void> bootstrap() async {
    final String saved = await _settings.loadApiBase();
    _api.useBaseUrl(saved);
    await refresh();
  }

  /// 重新探一次 `/auth/me`。
  ///
  /// 这个端点对未登录也回 200，所以它只有两种结局：拿到状态，或者网络不通。
  Future<void> refresh() async {
    _stage = AuthStage.checking;
    _error = null;
    notifyListeners();
    try {
      final SessionState state = await _api.auth.me();
      _session = state;
      _stage = state.authenticated ? AuthStage.loggedIn : AuthStage.loggedOut;
    } on ApiException catch (error) {
      _session = SessionState.anonymous;
      // 只有网络层不通才算「够不到」。后端回了 4xx 说明它活着，
      // 那是业务问题，该让用户去登录页看具体文案。
      _stage = error.isNetwork ? AuthStage.unreachable : AuthStage.loggedOut;
      _error = error.message;
    }
    notifyListeners();
  }

  /// 换后端地址。会顺带重探会话 —— 换了机器，原来的 cookie 多半不再适用。
  Future<void> setBaseUrl(String value) async {
    _api.useBaseUrl(value);
    // 存归一化之后的值，不是用户输的原文：下次冷启动不该再归一化一遍，
    // 而且让设置页显示的和实际用的是同一个串。
    await _settings.saveApiBase(_api.baseUrl);
    await refresh();
  }

  Future<bool> login(String username, String password) async {
    if (_busy) return false;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      _session = await _api.auth.login(username, password);
      _stage = AuthStage.loggedIn;
      return true;
    } on ApiException catch (error) {
      _error = error.message;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      await _api.auth.logout();
    } on ApiException catch (error) {
      // 登出失败不拦着用户走。本地凭证在 AuthApi.logout 的 finally 里
      // 已经清掉了，所以这里只是把原因留给界面。
      _error = error.message;
    } finally {
      _session = SessionState.anonymous;
      _stage = AuthStage.loggedOut;
      _busy = false;
      notifyListeners();
    }
  }

  /// 后端开了 `[auth] reader_public` 时，只读的阅读接口不需要身份。
  /// 让用户先用起来，碰到书架再提示登录 —— 自托管场景下「先看看搜不搜得到书」
  /// 是第一需求，先要密码会劝退一大半人。
  void continueAsGuest() {
    if (!_session.readerPublic) return;
    _stage = AuthStage.loggedIn;
    _error = null;
    notifyListeners();
  }

  /// 收到 401 时由任意一个请求调用：把会话打回未登录，让闸门跳登录页。
  void onUnauthorized() {
    if (_stage == AuthStage.loggedOut) return;
    _session = SessionState.anonymous;
    _stage = AuthStage.loggedOut;
    _error = '登录已过期，请重新登录。';
    notifyListeners();
  }
}
