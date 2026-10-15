import 'dart:async';

import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'config/app_config.dart';
import 'state/auth_controller.dart';
import 'ui/login_screen.dart';
import 'ui/search_screen.dart';

/// 应用根。
///
/// [services] 只为测试存在：传进来就用，不传就自己建一套。这样 widget 测试
/// 不用去 mock 全局单例，也不会在测试之间串状态。
class FunreadApp extends StatefulWidget {
  const FunreadApp({super.key, this.services});

  final AppServices? services;

  @override
  State<FunreadApp> createState() => _FunreadAppState();
}

class _FunreadAppState extends State<FunreadApp> {
  late final AppServices _services = widget.services ?? AppServices.create();

  /// 自己建的才自己销毁。测试传进来的那份由测试管，这里 dispose 掉会让
  /// 同一份 services 在第二个 testWidgets 里炸。
  late final bool _ownsServices = widget.services == null;

  @override
  void initState() {
    super.initState();
    // 冷启动探测是 fire-and-forget 的：结果通过 AuthController 的通知回来，
    // 不需要 await，也没有地方可以 await。
    unawaited(_services.auth.bootstrap());
  }

  @override
  void dispose() {
    if (_ownsServices) _services.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: _services,
      child: MaterialApp(
        title: AppConfig.appName,
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: const AuthGate(),
      ),
    );
  }

  static ThemeData _theme(Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4C6B4F),
        brightness: brightness,
      ),
    );
  }
}

/// 根据会话状态决定渲染哪一屏。
///
/// 没有用命名路由 / go_router：这一版只有两屏，而且它们之间是**状态驱动**的
/// 互斥关系，不是导航关系 —— 用路由表达就要在每个 401 之后手动 pop 到登录页，
/// 那是出 bug 的地方。等页面多起来（书架 / 阅读器 / 发现 / 设置）再引路由，
/// 届时这个闸门变成路由的 redirect。
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final AuthController auth = AppScope.of(context).auth;
    return ListenableBuilder(
      listenable: auth,
      builder: (BuildContext context, Widget? child) {
        switch (auth.stage) {
          case AuthStage.checking:
            return const _Splash();
          case AuthStage.loggedOut:
          case AuthStage.unreachable:
            return const LoginScreen();
          case AuthStage.loggedIn:
            return const SearchScreen();
        }
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在连接服务器…'),
          ],
        ),
      ),
    );
  }
}
