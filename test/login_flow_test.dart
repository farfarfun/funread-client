import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:funread_client/src/api/funread_api.dart';
import 'package:funread_client/src/app.dart';
import 'package:funread_client/src/app_scope.dart';
import 'package:funread_client/src/config/settings_store.dart';
import 'package:funread_client/src/state/auth_controller.dart';

import 'support/fake_adapter.dart';

/// 启动闸门这条路的回归：冷启动探会话 → 落在登录页 → 登录成功换屏。
///
/// 两个和 widget 测试环境有关的坑，都是踩过的：
///
///  1. **不能用 `pumpAndSettle`。** 加载态里有 [CircularProgressIndicator]，
///     它会一直调度新帧，pumpAndSettle 会一直等到超时。固定次数地 pump 才对。
///  2. **不能让真实插件进来。** `testWidgets` 跑在 fake async 里，平台通道的
///     往返（path_provider 要目录、shared_preferences 要偏好）在 `pump()`
///     之间永远回不来，整个应用会一直卡在启动闸门上，症状是「找不到任何
///     控件」而不是报错。所以凭证层和偏好存储在这里都换成内存实现。
Future<void> drain(WidgetTester tester) async {
  for (int i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 凭证层的空实现，顶掉会去问 path_provider 的那个。
Future<void> noCredentials(Dio dio) async {}

/// 偏好的内存实现，顶掉 shared_preferences。
class MemorySettings implements SettingsStore {
  String _base = 'http://nas.test:18811';

  @override
  Future<String> loadApiBase() async => _base;

  @override
  Future<void> saveApiBase(String value) async {
    _base = value;
  }
}

void main() {
  testWidgets('未登录时停在登录页，带着服务器地址输入框', (WidgetTester tester) async {
    final FakeAdapter adapter = FakeAdapter(
      (RequestOptions options) => const FakeResponse(<String, dynamic>{
        'auth_required': true,
        'authenticated': false,
        'reader_public': false,
      }),
    );
    final AppServices services = _services(adapter);
    addTearDown(services.dispose);

    await tester.pumpWidget(FunreadApp(services: services));
    await drain(tester);

    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
  });

  testWidgets('登录成功之后 AuthGate 自己换到搜索页', (WidgetTester tester) async {
    bool loggedIn = false;
    final FakeAdapter adapter = FakeAdapter((RequestOptions options) {
      if (options.path == '/auth/login') {
        loggedIn = true;
        return const FakeResponse(<String, dynamic>{
          'authenticated': true,
          'username': 'alice',
          'role': 'guest',
        });
      }
      return FakeResponse(<String, dynamic>{
        'authenticated': loggedIn,
        'username': loggedIn ? 'alice' : null,
      });
    });
    final AppServices services = _services(adapter);
    addTearDown(services.dispose);

    await tester.pumpWidget(FunreadApp(services: services));
    await drain(tester);

    await tester.enterText(find.byType(TextFormField).at(1), 'alice');
    await tester.enterText(find.byType(TextFormField).at(2), 'secret');
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await drain(tester);

    expect(find.text('搜索'), findsOneWidget);
    // 登录态要显示出来：自托管常有多个账号，看不到自己是谁很容易改错书架。
    expect(find.text('alice'), findsOneWidget);
  });

  testWidgets('连不上后端时给的是「重试连接」，不是让人反复输密码', (WidgetTester tester) async {
    final FakeAdapter adapter = FakeAdapter((RequestOptions options) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'connection refused',
      );
    });
    final AppServices services = _services(adapter);
    addTearDown(services.dispose);

    await tester.pumpWidget(FunreadApp(services: services));
    await drain(tester);

    expect(find.text('重试连接'), findsOneWidget);
  });
}

AppServices _services(FakeAdapter adapter) {
  final Dio dio = Dio()..httpClientAdapter = adapter;
  final FunreadApi api = FunreadApi(
    baseUrl: 'http://nas.test:18811',
    dio: dio,
    installCredentials: noCredentials,
  );
  return AppServices(
    api: api,
    auth: AuthController(api: api, settings: MemorySettings()),
  );
}
