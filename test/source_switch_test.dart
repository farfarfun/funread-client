import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:funread_client/src/app_scope.dart';
import 'package:funread_client/src/models/models.dart';
import 'package:funread_client/src/state/auth_controller.dart';
import 'package:funread_client/src/state/book_detail_controller.dart';
import 'package:funread_client/src/state/reader_controller.dart';
import 'package:funread_client/src/state/source_switch_controller.dart';
import 'package:funread_client/src/ui/book_detail_screen.dart';

import 'support/backend.dart';

/// 换源。
///
/// 这里守住的是四件在真实后端上**不会报错**、只会读到错东西的事：
///  1. `exact=false` 的候选被藏起来 → 换源列表永远是空的；
///  2. 换源前没写进度 → 后端没东西可定位，换完回到第一章；
///  3. 换完只改了 url_id 没重算整条链 → 旧源的 variables / 旧目录序号被沿用，
///     表现是静默读到空正文；
///  4. 正文页换完把人弹回详情页 → 上千章的目录里重新找位置，
///     而那正是换源想省掉的事。
void main() {
  const BookRef ref = BookRef(
    bookKey: FakeBackend.bookKey,
    urlId: FakeBackend.currentUrlId,
    bookUrl: 'http://src.test/b/1',
    name: '书名',
    author: '作者',
  );

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 10));

  Future<void> drain(WidgetTester tester) async {
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  SourceSwitchController controllerFor(
    FakeBackend backend, {
    bool onShelf = true,
    Future<void> Function()? saveProgressFirst,
    Duration tick = const Duration(seconds: 1),
  }) {
    final SourceSwitchController controller = SourceSwitchController(
      api: backend.api,
      bookKey: FakeBackend.bookKey,
      onShelf: onShelf,
      saveProgressFirst: saveProgressFirst,
      tick: tick,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  group('换源列表', () {
    test('近似匹配一条都不能少 —— 那些源往往恰恰还活着', () async {
      final FakeBackend backend = FakeBackend();
      final SourceSwitchController controller = controllerFor(backend);

      await controller.load();

      final SwitchSourcePage page = controller.page!;
      expect(page.items, hasLength(2));
      expect(page.exactItems, hasLength(1));
      expect(page.looseItems, hasLength(1));
      // 作者写法不同的那一条照样在，而且还带着它自己的作者名。
      expect(page.looseItems.single.author, '作者（著）');
      expect(controller.error, isNull);
    });

    test('只带 book_key，而且每次打开都重搜（不缓存上一轮的结果）', () async {
      final FakeBackend backend = FakeBackend();
      final SourceSwitchController controller = controllerFor(backend);

      await controller.load();
      await controller.load();

      final List<RequestOptions> calls = backend.requestsTo('/reader/sources');
      expect(calls, hasLength(2));
      expect(calls.last.queryParameters, <String, dynamic>{
        'book_key': FakeBackend.bookKey,
      });
    });

    test('不在书架时一个请求都不发，并说清为什么', () async {
      final FakeBackend backend = FakeBackend(onShelf: false);
      final SourceSwitchController controller =
          controllerFor(backend, onShelf: false);

      await controller.load();

      // 关键：不是发出去换一个 404 回来，而是根本不发。
      expect(backend.requestsTo('/reader/sources'), isEmpty);
      expect(controller.page, isNull);
      expect(controller.error, contains('加入书架'));
      expect(controller.error, contains('书名'));
    });

    test('后端 404 时把它那句话原样显示出来', () async {
      final FakeBackend backend = FakeBackend()..sourcesStatus = 404;
      final SourceSwitchController controller = controllerFor(backend);

      await controller.load();

      expect(controller.error, '书架里没有这本书');
    });

    test('等待期间要报时 —— 十几秒的转圈和卡死在屏幕上没有区别', () async {
      final FakeBackend backend = FakeBackend()
        ..sourcesDelay = const Duration(milliseconds: 120);
      final SourceSwitchController controller = controllerFor(
        backend,
        tick: const Duration(milliseconds: 10),
      );

      unawaited(controller.load());
      await Future<void>.delayed(const Duration(milliseconds: 45));

      expect(controller.loading, isTrue);
      expect(controller.elapsed, greaterThan(Duration.zero));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(controller.loading, isFalse);
    });

    test('面板关掉时计时器必须停，否则它会 notify 一个已经 dispose 的对象', () async {
      final FakeBackend backend = FakeBackend()
        ..sourcesDelay = const Duration(milliseconds: 60);
      final SourceSwitchController controller = SourceSwitchController(
        api: backend.api,
        bookKey: FakeBackend.bookKey,
        onShelf: true,
        tick: const Duration(milliseconds: 5),
      );

      unawaited(controller.load());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      controller.dispose();

      // 没 cancel 的话，接下来几个 tick 会在 dispose 之后调 notifyListeners()，
      // 那是一条框架断言失败。顺带等在飞的那个响应回来，确认它也不碰状态。
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });

  group('提交换源', () {
    test('进度的 PUT 必须排在换源的 POST 前面', () async {
      final FakeBackend backend = FakeBackend();
      final BookDetailController detail =
          BookDetailController(api: backend.api, ref: ref);
      addTearDown(detail.dispose);
      await detail.load();
      final ReaderController reader = ReaderController(
        api: backend.api,
        ref: detail.ref,
        info: detail.info!,
        chapters: detail.chapters,
        position: 0,
        onShelf: true,
        saveThrottle: const Duration(minutes: 5),
      );
      addTearDown(reader.dispose);
      await reader.load();
      reader.onOffsetChanged(321);

      final SourceSwitchController controller = controllerFor(
        backend,
        saveProgressFirst: reader.flush,
      );
      await controller.load();
      await controller.switchTo(controller.page!.looseItems.single);
      await settle();

      final List<String> paths = <String>[
        for (final RequestOptions options in backend.adapter.requests)
          options.path,
      ];
      final int post = paths.indexOf('/shelf/${FakeBackend.bookKey}/source');
      expect(post, greaterThan(-1));
      // 后端是拿**库里那条记录**的章节名去新目录里找同一章的。少写这一笔，
      // 换完源就落回第一章，而且只在「读到一半才换源」时出现。
      final List<dynamic> offsetsBefore = <dynamic>[
        for (int i = 0; i < post; i++)
          if (paths[i] == '/shelf/${FakeBackend.bookKey}/progress')
            (backend.adapter.requests[i].data as Map<String, dynamic>)
                ['char_offset'],
      ];
      expect(offsetsBefore, contains(321));
    });

    test('body 只有三个字段，并把后端的定位结果原样带回来', () async {
      final FakeBackend backend = FakeBackend()
        ..switchMethod = 'position'
        ..switchApproximate = true
        ..switchChapterIndex = 2
        ..switchTotal = 5;
      final SourceSwitchController controller = controllerFor(backend);
      await controller.load();

      final SwitchSourceResult? result =
          await controller.switchTo(controller.page!.looseItems.single);

      expect(result, isNotNull);
      expect(result!.method, SwitchMethod.position);
      expect(result.needsConfirm, isTrue);
      final Map<String, dynamic> body = backend
          .lastRequestTo('/shelf/${FakeBackend.bookKey}/source')!
          .data as Map<String, dynamic>;
      expect(body, <String, dynamic>{
        'url_id': FakeBackend.otherUrlId,
        'book_url': FakeBackend.otherBookUrl,
        'remap_progress': true,
      });
    });
  });

  group('换源之后整条链要用新源重算', () {
    test('正文页：新源的 variables 进了目录和正文，而且人留在正文页', () async {
      final FakeBackend backend = FakeBackend()..switchChapterIndex = 1;
      final BookDetailController detail =
          BookDetailController(api: backend.api, ref: ref);
      addTearDown(detail.dispose);
      await detail.load();
      final ReaderController reader = ReaderController(
        api: backend.api,
        ref: detail.ref,
        info: detail.info!,
        chapters: detail.chapters,
        position: 0,
        onShelf: true,
      );
      addTearDown(reader.dispose);
      await reader.load();

      await reader.adoptSource(
        urlId: FakeBackend.otherUrlId,
        bookUrl: FakeBackend.otherBookUrl,
        chapterIndex: 1,
      );
      await settle();

      // 目录整个换成新源的。
      expect(reader.chapters, hasLength(FakeBackend.otherChapterCount));
      expect(reader.chapters[1].name, '新源第 2 章');
      expect(reader.position, 1);
      expect(reader.ref.urlId, FakeBackend.otherUrlId);
      // 书名兜底也要跟着换到新源那份详情上。
      expect(reader.info.sourceName, '另一个源');

      // 最要命的一条：带去正文的必须是**新源**的两份 variables。
      // 沿用旧源的那份不会报错，只会静默读到空正文。
      final Map<String, dynamic> content = backend
          .lastRequestTo('/reader/content')!
          .data as Map<String, dynamic>;
      expect((content['book'] as Map<String, dynamic>)['variables'],
          <String, String>{'token': 'src${FakeBackend.otherUrlId}'});
      expect((content['chapter'] as Map<String, dynamic>)['variables'],
          <String, String>{'ck': 'src${FakeBackend.otherUrlId}'});
      expect(content['url_id'], FakeBackend.otherUrlId);

      final Map<String, dynamic> toc =
          backend.lastRequestTo('/reader/toc')!.data as Map<String, dynamic>;
      expect((toc['book'] as Map<String, dynamic>)['variables'],
          <String, String>{'token': 'src${FakeBackend.otherUrlId}'});
    });

    test('正文页：章内偏移跟着清零 —— 两个源的同一章字数对不上', () async {
      final FakeBackend backend = FakeBackend();
      final BookDetailController detail =
          BookDetailController(api: backend.api, ref: ref);
      addTearDown(detail.dispose);
      await detail.load();
      final ReaderController reader = ReaderController(
        api: backend.api,
        ref: detail.ref,
        info: detail.info!,
        chapters: detail.chapters,
        position: 1,
        charOffset: 900,
        onShelf: true,
        saveThrottle: const Duration(minutes: 5),
      );
      addTearDown(reader.dispose);
      await reader.load();
      expect(reader.restoreOffset, 900);

      await reader.adoptSource(
        urlId: FakeBackend.otherUrlId,
        bookUrl: FakeBackend.otherBookUrl,
        chapterIndex: 2,
      );
      await settle();

      expect(reader.restoreOffset, 0);
      final Map<String, dynamic> progress = backend
          .lastRequestTo('/shelf/${FakeBackend.bookKey}/progress')!
          .data as Map<String, dynamic>;
      expect(progress['char_offset'], 0);
      expect(progress['chapter_index'], 2);
      // 章节名也要是新源的，否则下一次换源会拿旧源的名字去新目录里找。
      expect(progress['chapter_name'], '新源第 3 章');
    });

    test('新源的目录是空的时候报错，而不是留在一个空页面上', () async {
      final FakeBackend backend = FakeBackend();
      final BookDetailController detail =
          BookDetailController(api: backend.api, ref: ref);
      addTearDown(detail.dispose);
      await detail.load();
      final ReaderController reader = ReaderController(
        api: backend.api,
        ref: detail.ref,
        info: detail.info!,
        chapters: detail.chapters,
        position: 0,
        onShelf: true,
      );
      addTearDown(reader.dispose);
      await reader.load();

      // 第三个源在假后端上没有目录（otherChapterCount 只给 otherUrlId）。
      backend.tocEmptyForUrlId = 11;
      await reader.adoptSource(
        urlId: 11,
        bookUrl: 'http://src3.test/b/1',
        chapterIndex: 0,
      );

      expect(reader.error, isNotNull);
      expect(reader.loading, isFalse);
    });

    test('详情页：目录和「续读第几章」都跟着新源走', () async {
      final FakeBackend backend = FakeBackend()..switchChapterIndex = 3;
      final BookDetailController detail =
          BookDetailController(api: backend.api, ref: ref);
      addTearDown(detail.dispose);
      await detail.load();
      expect(detail.chapters, hasLength(3));

      await backend.api.shelf.switchSource(
        FakeBackend.bookKey,
        urlId: FakeBackend.otherUrlId,
        bookUrl: FakeBackend.otherBookUrl,
      );
      await detail.adoptSource(
        urlId: FakeBackend.otherUrlId,
        bookUrl: FakeBackend.otherBookUrl,
      );

      expect(detail.chapters, hasLength(FakeBackend.otherChapterCount));
      expect(detail.chapters.first.name, '新源第 1 章');
      expect(detail.ref.urlId, FakeBackend.otherUrlId);
      // 后端重定位之后进度在第 4 章；重读书架才能让底部那颗按钮说对话。
      expect(detail.progressPosition, 3);
      expect(detail.progressOffset, 0);
    });
  });

  group('界面入口', () {
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

    testWidgets('试读时换源是禁用的，并且说明了为什么', (WidgetTester tester) async {
      final FakeBackend backend = FakeBackend(onShelf: false);

      await tester.pumpWidget(wrap(backend));
      await drain(tester);

      // 禁用态自己不会解释自己，所以页面上要写一遍。
      expect(find.byTooltip('换源需要先把这本书加入书架'), findsOneWidget);
      expect(
        find.textContaining('换源需要先加入书架'),
        findsOneWidget,
      );
      final IconButton button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.swap_horiz),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(backend.requestsTo('/reader/sources'), isEmpty);
    });

    testWidgets('正文页换源：换完留在正文页，读的是新源的章节', (WidgetTester tester) async {
      final FakeBackend backend = FakeBackend()
        ..switchChapterIndex = 1
        ..switchTotal = FakeBackend.otherChapterCount;

      await tester.pumpWidget(wrap(backend));
      await drain(tester);
      await tester.tap(find.text('第 1 章'));
      await drain(tester);
      expect(find.text('1 / 3'), findsOneWidget);

      await tester.tap(find.byTooltip('换源'));
      await drain(tester);
      // 近似匹配那一组要有标题说明作者为什么不一样，而且候选本身在列表里。
      expect(find.textContaining('作者写法不同'), findsOneWidget);

      await tester.tap(find.text('另一个源'));
      // 面板要先收起（有退场动画），然后才轮到 /reader/book + /reader/toc +
      // /reader/content 三趟往返，所以这里要多放一会儿。
      await drain(tester);
      await drain(tester);

      // 还在正文页（底部翻章条还在），而且用的是新源的目录。
      expect(find.text('2 / ${FakeBackend.otherChapterCount}'), findsOneWidget);
      expect(find.text('新源第 2 章'), findsWidgets);
    });

    testWidgets('position 定位要停下来让人确认落点', (WidgetTester tester) async {
      final FakeBackend backend = FakeBackend()
        ..switchMethod = 'position'
        ..switchApproximate = true
        ..switchChapterIndex = 2
        ..switchTotal = FakeBackend.otherChapterCount;

      await tester.pumpWidget(wrap(backend));
      await drain(tester);
      await tester.tap(find.text('第 1 章'));
      await drain(tester);
      await tester.tap(find.byTooltip('换源'));
      await drain(tester);
      await tester.tap(find.text('另一个源'));
      await drain(tester);
      await drain(tester);

      expect(find.text('确认一下落点'), findsOneWidget);
      expect(find.textContaining('按位置估'), findsOneWidget);

      await tester.tap(find.text('打开目录'));
      await drain(tester);
      await drain(tester);

      // 目录抽屉开着，用户可以自己挑一章。
      expect(find.text('新源第 1 章'), findsWidgets);
    });
  });
}
