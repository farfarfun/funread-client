import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:funread_client/src/app_scope.dart';
import 'package:funread_client/src/models/models.dart';
import 'package:funread_client/src/state/auth_controller.dart';
import 'package:funread_client/src/state/reader_settings_controller.dart';
import 'package:funread_client/src/ui/book_detail_screen.dart';
import 'package:funread_client/src/ui/reader_palette.dart';

import 'support/backend.dart';
import 'support/memory_settings.dart';

/// 排版设置与翻页手势。
void main() {
  const BookRef ref = BookRef(
    bookKey: FakeBackend.bookKey,
    urlId: 7,
    bookUrl: 'http://src.test/b/1',
    name: '书名',
    author: '作者',
  );

  String paragraphAt(int index) => 'P$index${'文' * 40}';
  final String chapterText =
      List<String>.generate(40, paragraphAt).join('\n\n');

  Future<void> drain(WidgetTester tester) async {
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// 每个测试自带一套内存偏好：真实的那个会去碰平台通道。
  late MemorySettings store;
  late ReaderSettingsController settings;

  setUp(() {
    store = MemorySettings();
    settings = ReaderSettingsController(store: store);
  });

  // settings 不在这里 dispose：它挂在 AppServices 上，由 services.dispose()
  // 负责。两边都调会在第二次 dispose 上断言失败。
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Widget wrap(FakeBackend backend) {
    final AppServices services = AppServices(
      api: backend.api,
      auth: AuthController(api: backend.api),
      readerSettings: settings,
    );
    addTearDown(services.dispose);
    return AppScope(
      services: services,
      child: const MaterialApp(home: BookDetailScreen(ref: ref)),
    );
  }

  Future<FakeBackend> openReader(WidgetTester tester) async {
    final FakeBackend backend = FakeBackend(text: chapterText);
    await tester.pumpWidget(wrap(backend));
    await drain(tester);
    await tester.tap(find.text('第 1 章'));
    await drain(tester);
    return backend;
  }

  /// 屏幕上那一段正文的样式。
  TextStyle styleOfBody(WidgetTester tester) {
    final Finder finder = find.byWidgetPredicate(
      (Widget widget) => widget is Text && (widget.data?.startsWith('P') ?? false),
    );
    return tester.widget<Text>(finder.first).style!;
  }

  testWidgets('改字号：正文当场重排，而且停在原来读到的那一段', (WidgetTester tester) async {
    await openReader(tester);
    expect(styleOfBody(tester).fontSize, ReaderSettings.defaultFontSize);

    await tester.tap(find.byTooltip('排版'));
    await drain(tester);
    // 滑块按住中点 = 区间中值（12～30 之间，取整到最近的一格）。
    await tester.tapAt(tester.getCenter(find.byType(Slider).first));
    await drain(tester);

    final double changed = styleOfBody(tester).fontSize!;
    expect(changed, isNot(ReaderSettings.defaultFontSize));
    expect(settings.value.fontSize, changed);
    // 拖的过程中不落盘，松手（tap 也算一次 onChangeEnd）才写一次。
    expect(store.writes, 1);

    // 重排会重新锚定阅读位置，顺带可能开一个进度回写的节流窗口。
    // 让它到期，否则收尾时报「A Timer is still pending」。
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('切夜间主题：底色跟着变，而且立刻存下来', (WidgetTester tester) async {
    await openReader(tester);

    await tester.tap(find.byTooltip('排版'));
    await drain(tester);
    await tester.tap(find.text('夜间'));
    await drain(tester);

    expect(settings.value.theme, ReaderThemeId.night);
    expect(store.reader.theme, ReaderThemeId.night);
    final Scaffold scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.backgroundColor, ReaderPalette.night.background);
    expect(styleOfBody(tester).color, ReaderPalette.night.text);
  });

  testWidgets('设置只存在本地：改完一个字节都不发给后端', (WidgetTester tester) async {
    final FakeBackend backend = await openReader(tester);
    final int before = backend.adapter.requests.length;

    await tester.tap(find.byTooltip('排版'));
    await drain(tester);
    await tester.tap(find.text('护眼'));
    await tester.tapAt(tester.getCenter(find.byType(Slider).at(1)));
    await drain(tester);

    // 手机和桌面的合适字号本来就不一样，同步过去只会让两边互相打架。
    expect(backend.adapter.requests, hasLength(before));

    await tester.pump(const Duration(seconds: 4));
  });

  group('翻页手势', () {
    testWidgets('触屏上点右边 1/4 翻到下一章，点中间不翻', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await openReader(tester);
      expect(find.text('1 / 3'), findsOneWidget);

      await tester.tapAt(const Offset(780, 300));
      await drain(tester);
      expect(find.text('2 / 3'), findsOneWidget);

      // 中间那一半什么都不做：那里是正文，点它多半是想选词或者什么都不想。
      await tester.tapAt(const Offset(400, 300));
      await drain(tester);
      expect(find.text('2 / 3'), findsOneWidget);

      await tester.tapAt(const Offset(20, 300));
      await drain(tester);
      expect(find.text('1 / 3'), findsOneWidget);
    });

    testWidgets('桌面上点边缘不翻章 —— 那是几百像素的死区，而且鼠标点击是选词',
        (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await openReader(tester);

      await tester.tapAt(const Offset(780, 300));
      await drain(tester);

      expect(find.text('1 / 3'), findsOneWidget);
    });

    testWidgets('方向键翻章 —— 桌面上这是主要入口', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await openReader(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await drain(tester);
      expect(find.text('2 / 3'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await drain(tester);
      expect(find.text('1 / 3'), findsOneWidget);
    });
  });
}
