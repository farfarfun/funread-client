import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:funread_client/src/app_scope.dart';
import 'package:funread_client/src/models/models.dart';
import 'package:funread_client/src/state/auth_controller.dart';
import 'package:funread_client/src/ui/book_detail_screen.dart';

import 'support/backend.dart';

/// 详情页 → 正文页这一跳的回归。
///
/// 和 `login_flow_test` 同样的两个坑：
///  1. **不能用 `pumpAndSettle`** —— 加载态里的 [CircularProgressIndicator]
///     会一直调度新帧，settle 会一直等到超时。固定次数地 pump 才对。
///  2. **不能让真实插件进来** —— 凭证层在 `FakeBackend` 里已经换成空实现。
Future<void> drain(WidgetTester tester) async {
  for (int i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 模拟一次「切走再切回来」。
///
/// 走平台消息而不是直接调 `handleAppLifecycleStateChanged`：后者是
/// `@protected`，从测试里调会被 `flutter analyze` 判成
/// `invalid_use_of_protected_member`，而本仓库的 analyze 对 info 也返回非零。
///
/// 中间状态一个都不能跳：框架会校验相邻状态的合法性，
/// 从 resumed 直接跳 paused 在断言打开时会炸。
Future<void> backgroundAndResume(WidgetTester tester) async {
  const List<AppLifecycleState> path = <AppLifecycleState>[
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ];
  for (final AppLifecycleState state in path) {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/lifecycle',
      const StringCodec().encodeMessage(state.toString()),
      null,
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  const BookRef ref = BookRef(
    bookKey: FakeBackend.bookKey,
    urlId: 7,
    bookUrl: 'http://src.test/b/1',
    name: '书名',
    author: '作者',
  );

  Widget wrap(FakeBackend backend) {
    final AppServices services = AppServices(
      api: backend.api,
      auth: AuthController(api: backend.api),
    );
    addTearDown(services.dispose);
    return AppScope(
      services: services,
      child: const MaterialApp(home: BookDetailScreen(ref: ref)),
    );
  }

  testWidgets('详情页把书名、来源和目录都显示出来', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();

    await tester.pumpWidget(wrap(backend));
    await drain(tester);

    expect(find.text('作者'), findsOneWidget);
    expect(find.text('目录（共 3 章）'), findsOneWidget);
    expect(find.text('第 1 章'), findsOneWidget);
    // 书架上有进度，底部的主按钮应该是「续读」而不是「开始阅读」。
    expect(find.text('续读第 2 章'), findsOneWidget);
    expect(find.text('移出书架'), findsOneWidget);
  });

  testWidgets('点目录里的一章进正文页，正文和翻章按钮都在', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();

    await tester.pumpWidget(wrap(backend));
    await drain(tester);

    await tester.tap(find.text('第 1 章'));
    await drain(tester);

    expect(find.text('第一段。'), findsOneWidget);
    expect(find.text('第二段。'), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);

    await tester.tap(find.text('下一章'));
    await drain(tester);

    expect(find.text('2 / 3'), findsOneWidget);
    // 翻章之后请求的是第二章，而且 variables 还在。
    final Map<String, dynamic> body =
        backend.lastRequestTo('/reader/content')!.data as Map<String, dynamic>;
    final Map<String, dynamic> chapter = body['chapter'] as Map<String, dynamic>;
    expect(chapter['index'], 1);
    expect(chapter['variables'], <String, String>{'ck': '1'});
    expect((body['book'] as Map<String, dynamic>)['variables'],
        <String, String>{'token': 'xyz'});
  });

  testWidgets('不在书架也能读，底部给的是「加入书架」', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend(onShelf: false);

    await tester.pumpWidget(wrap(backend));
    await drain(tester);

    expect(find.text('加入书架'), findsOneWidget);
    expect(find.text('开始阅读'), findsOneWidget);

    await tester.tap(find.text('开始阅读'));
    await drain(tester);

    expect(find.text('第一段。'), findsOneWidget);
    // 试读不写进度：后端会 404，发了也只是白打一次。
    expect(backend.requestsTo('/shelf/${FakeBackend.bookKey}/progress'), isEmpty);
  });

  testWidgets('切回前台发现别处读到了新进度：弹窗问，点「跳过去」才跳', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();

    await tester.pumpWidget(wrap(backend));
    await drain(tester);
    await tester.tap(find.text('第 1 章'));
    await drain(tester);
    expect(find.text('1 / 3'), findsOneWidget);

    // 这一页在后台挂着的时候，手机上读到了第 3 章。
    backend.progressChapterIndex = 2;
    await backgroundAndResume(tester);
    await drain(tester);

    expect(find.text('别处读到了新进度'), findsOneWidget);
    // 弹窗摆在那儿的时候还没有跳。
    expect(find.text('1 / 3'), findsOneWidget);

    await tester.tap(find.text('跳过去'));
    await drain(tester);

    expect(find.text('3 / 3'), findsOneWidget);
  });

  testWidgets('点「留在这里」就真的留在这里', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();

    await tester.pumpWidget(wrap(backend));
    await drain(tester);
    await tester.tap(find.text('第 1 章'));
    await drain(tester);

    backend.progressChapterIndex = 2;
    await backgroundAndResume(tester);
    await drain(tester);

    await tester.tap(find.text('留在这里'));
    await drain(tester);

    expect(find.text('别处读到了新进度'), findsNothing);
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('目录抓不到时单独报错，详情本身还看得见', (WidgetTester tester) async {
    // 目录返回 0 章是最常见的「这个源挂了」的形态 —— 不报错，就是空的。
    final FakeBackend backend = FakeBackend(chapterCount: 0);

    await tester.pumpWidget(wrap(backend));
    await drain(tester);

    expect(find.text('目录读不出来'), findsOneWidget);
    expect(find.textContaining('换一个源'), findsWidgets);
    // 详情还在：书名作者都读出来了，只是目录空的。
    expect(find.text('作者'), findsOneWidget);
  });
}
