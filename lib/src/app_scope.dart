import 'package:flutter/widgets.dart';

import 'api/funread_api.dart';
import 'state/auth_controller.dart';
import 'state/reader_settings_controller.dart';

/// 全应用共享的长生命周期对象。
///
/// 没有引 provider / riverpod / get_it：这一版只有三个单例，
/// 一个 InheritedWidget 就够了，而每多一个状态管理依赖，
/// 以后换架构就多一层要拆的东西。等真的出现跨页面的复杂依赖图再说。
class AppServices {
  AppServices({
    required this.api,
    required this.auth,
    ReaderSettingsController? readerSettings,
  }) : readerSettings = readerSettings ?? ReaderSettingsController();

  factory AppServices.create({String? baseUrl}) {
    final FunreadApi api = FunreadApi(baseUrl: baseUrl);
    return AppServices(api: api, auth: AuthController(api: api));
  }

  final FunreadApi api;
  final AuthController auth;

  /// 排版设置。放在这一层而不是正文页里：退出正文再进来不该回到默认字号，
  /// 而每屏一个控制器的那套（搜索 / 详情 / 正文）生命周期正是跟着屏幕走的。
  final ReaderSettingsController readerSettings;

  void dispose() {
    auth.dispose();
    readerSettings.dispose();
  }
}

/// 把 [AppServices] 挂到 widget 树上。
class AppScope extends InheritedWidget {
  const AppScope({required this.services, required super.child, super.key});

  final AppServices services;

  static AppServices of(BuildContext context) {
    final AppScope? scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 不在当前 context 之上，检查 runApp 的根 widget。');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => oldWidget.services != services;
}
