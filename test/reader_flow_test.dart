import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:funread_client/src/models/models.dart';
import 'package:funread_client/src/state/book_detail_controller.dart';
import 'package:funread_client/src/state/reader_controller.dart';

import 'support/backend.dart';

/// 阅读链路的回归：详情 → 目录 → 正文 → 进度。
///
/// 这里反复断言的那件事 —— `variables` 有没有一路带到底 —— 在真实后端上
/// **不会报错**：带变量的源会静默返回空目录或空正文，看起来和「这个源挂了」
/// 一模一样。所以它只能靠测试守住。
void main() {
  const BookRef ref = BookRef(
    bookKey: FakeBackend.bookKey,
    urlId: 7,
    bookUrl: 'http://src.test/b/1',
    name: '书名',
    author: '作者',
  );

  /// 把事件队列放干。
  ///
  /// 进度回写是 fire-and-forget 的（它不该挡着正文显示），所以 `await load()`
  /// 返回时那个 PUT 可能还没发出去。断言之前要给它一个跑完的机会。
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

  /// 走完详情 + 目录，返回已经加载好的控制器。
  Future<BookDetailController> openDetail(FakeBackend backend) async {
    final BookDetailController detail =
        BookDetailController(api: backend.api, ref: ref);
    addTearDown(detail.dispose);
    await detail.load();
    return detail;
  }

  ReaderController openReader(
    FakeBackend backend,
    BookDetailController detail, {
    int position = 0,
    int charOffset = 0,
    Duration throttle = const Duration(milliseconds: 20),
  }) {
    final ReaderController reader = ReaderController(
      api: backend.api,
      ref: detail.ref,
      info: detail.info!,
      chapters: detail.chapters,
      position: position,
      charOffset: charOffset,
      onShelf: detail.onShelf,
      saveThrottle: throttle,
    );
    addTearDown(reader.dispose);
    return reader;
  }

  group('variables 端到端', () {
    test('详情的 variables 原样进 /reader/toc', () async {
      final FakeBackend backend = FakeBackend();
      final BookDetailController detail = await openDetail(backend);

      expect(detail.error, isNull);
      expect(detail.chapters, hasLength(3));

      final Map<String, dynamic> body =
          backend.lastRequestTo('/reader/toc')!.data as Map<String, dynamic>;
      final Map<String, dynamic> book = body['book'] as Map<String, dynamic>;
      expect(book['variables'], <String, String>{'token': 'xyz'});
      // url_id 和整本书的坐标也要对上，否则引擎会去问另一个源。
      expect(body['url_id'], 7);
      expect(book['book_url'], 'http://src.test/b/1');
    });

    test('详情和章节两份 variables 都要进 /reader/content', () async {
      final FakeBackend backend = FakeBackend();
      final BookDetailController detail = await openDetail(backend);
      final ReaderController reader = openReader(backend, detail);

      await reader.load();

      final Map<String, dynamic> body =
          backend.lastRequestTo('/reader/content')!.data as Map<String, dynamic>;
      final Map<String, dynamic> book = body['book'] as Map<String, dynamic>;
      final Map<String, dynamic> chapter = body['chapter'] as Map<String, dynamic>;
      // 详情页 @put 的变量（在 book 上）和目录行自己的变量（在 chapter 上）
      // 是两份，丢哪一份都是静默读空。
      expect(book['variables'], <String, String>{'token': 'xyz'});
      expect(chapter['variables'], <String, String>{'ck': '1'});
      expect(chapter['index'], 0);
      expect(chapter['url'], 'http://src.test/c/0');
    });

    test('翻到下一章时带的是下一章的 chapter，不是缓存住的第一章', () async {
      final FakeBackend backend = FakeBackend();
      final BookDetailController detail = await openDetail(backend);
      final ReaderController reader = openReader(backend, detail);
      await reader.load();

      await reader.next();

      final Map<String, dynamic> body =
          backend.lastRequestTo('/reader/content')!.data as Map<String, dynamic>;
      final Map<String, dynamic> chapter = body['chapter'] as Map<String, dynamic>;
      expect(chapter['index'], 1);
      expect(reader.position, 1);
      expect(reader.hasPrev, isTrue);
    });
  });

  group('服务端章节缓存', () {
    test('/reader/content 必须带 book_key，否则每次都实抓源站', () async {
      final FakeBackend backend = FakeBackend();
      final BookDetailController detail = await openDetail(backend);
      final ReaderController reader = openReader(backend, detail);

      await reader.load();

      final Map<String, dynamic> body =
          backend.lastRequestTo('/reader/content')!.data as Map<String, dynamic>;
      expect(body['book_key'], FakeBackend.bookKey);
    });
  });

  group('进度', () {
    test('进了一章就先落一次进度 —— 短到不用滚的章节否则永远不会被记下来', () async {
      final FakeBackend backend = FakeBackend();
      final BookDetailController detail = await openDetail(backend);
      final ReaderController reader = openReader(backend, detail, position: 1);

      await reader.load();
      await settle();

      final Map<String, dynamic> body =
          backend.lastRequestTo('/shelf/${FakeBackend.bookKey}/progress')!.data
              as Map<String, dynamic>;
      expect(body['chapter_index'], 1);
      expect(body['chapter_name'], '第 2 章');
      expect(body['chapter_url'], 'http://src.test/c/1');
    });

    test('存的是 char_offset，不是滚动像素', () async {
      final FakeBackend backend = FakeBackend();
      final BookDetailController detail = await openDetail(backend);
      final ReaderController reader = openReader(backend, detail);
      await reader.load();

      reader.onOffsetChanged(123);
      await reader.flush();
      await settle();

      final Map<String, dynamic> body =
          backend.lastRequestTo('/shelf/${FakeBackend.bookKey}/progress')!.data
              as Map<String, dynamic>;
      expect(body['char_offset'], 123);
    });

    test('翻章前要把上一章读到哪落下去，否则节流窗口里的那一段就丢了', () async {
      final FakeBackend backend = FakeBackend();
      final BookDetailController detail = await openDetail(backend);
      // 节流窗口拉长到测试里不可能到期，确保写入只可能来自翻章前的补写。
      final ReaderController reader = openReader(
        backend,
        detail,
        throttle: const Duration(minutes: 5),
      );
      await reader.load();

      reader.onOffsetChanged(456);
      await reader.next();
      await settle();

      final List<RequestOptions> writes =
          backend.requestsTo('/shelf/${FakeBackend.bookKey}/progress');
      final List<dynamic> offsets = <dynamic>[
        for (final RequestOptions options in writes)
          (options.data as Map<String, dynamic>)['char_offset'],
      ];
      expect(offsets, contains(456));
      // 新章节要从 0 重新开始计，不能把上一章的偏移带过去。
      expect(offsets.last, 0);
    });

    test('不在书架就一次进度都不发 —— 后端会 404，而试读本来就不需要进度', () async {
      final FakeBackend backend = FakeBackend(onShelf: false);
      final BookDetailController detail = await openDetail(backend);
      expect(detail.onShelf, isFalse);

      final ReaderController reader = openReader(backend, detail);
      await reader.load();
      reader.onOffsetChanged(99);
      await reader.flush();
      await settle();

      expect(backend.requestsTo('/shelf/${FakeBackend.bookKey}/progress'), isEmpty);
    });

    test('没登录（书架 401）也要能读，详情页不能因此报错', () async {
      final FakeBackend backend = FakeBackend(shelfStatus: 401);
      final BookDetailController detail = await openDetail(backend);

      expect(detail.error, isNull);
      expect(detail.onShelf, isFalse);
      expect(detail.chapters, hasLength(3));
      expect(detail.progressPosition, -1);
    });

    test('书架上的进度换算成目录下标，续读落在那一章', () async {
      final FakeBackend backend = FakeBackend();
      final BookDetailController detail = await openDetail(backend);

      expect(detail.onShelf, isTrue);
      expect(detail.progressPosition, 1);
      expect(detail.progressOffset, 42);
    });
  });

  group('书架', () {
    test('加入书架带上 toc_url，并以后端返回的 book_key 为准', () async {
      final FakeBackend backend = FakeBackend(onShelf: false);
      final BookDetailController detail = await openDetail(backend);

      final String message = await detail.addToShelf();

      expect(message, '已加入书架');
      expect(detail.onShelf, isTrue);
      expect(detail.ref.bookKey, FakeBackend.bookKey);
      final List<RequestOptions> posts = <RequestOptions>[
        for (final RequestOptions options in backend.requestsTo('/shelf'))
          if (options.method == 'POST') options,
      ];
      final Map<String, dynamic> body = posts.single.data as Map<String, dynamic>;
      // 搜索结果里没有 toc_url，详情页有。带上它，书架的「检查更新」
      // 就不用再走一次 /reader/book。
      expect(body['toc_url'], 'http://src.test/b/1/toc');
      expect(body['url_id'], 7);
      // group 不传：再点一次「加入书架」不该把书踢回未分组。
      expect(body.containsKey('group'), isFalse);
    });

    test('移出书架走 DELETE，本地状态跟着退回「不在书架」', () async {
      final FakeBackend backend = FakeBackend();
      final BookDetailController detail = await openDetail(backend);

      final String message = await detail.removeFromShelf();

      expect(message, '已移出书架');
      expect(detail.onShelf, isFalse);
      expect(backend.lastRequestTo('/shelf/${FakeBackend.bookKey}')!.method,
          'DELETE');
    });

    test('书架 401 时说清「没登录也能接着读」，而不是干巴巴一句加入失败', () async {
      final FakeBackend backend = FakeBackend(shelfStatus: 401);
      final BookDetailController detail = await openDetail(backend);

      final String message = await detail.addToShelf();

      expect(message, contains('登录'));
      expect(message, contains('接着读'));
      expect(detail.onShelf, isFalse);
      // 关键：加不进书架不影响读 —— 目录还在手上。
      expect(detail.chapters, hasLength(3));
    });
  });

  group('目录下标换算', () {
    final List<Chapter> chapters = <Chapter>[
      for (int i = 0; i < 5; i++) Chapter(index: i, name: '第 ${i + 1} 章'),
    ];

    test('序号等于下标时直接命中', () {
      expect(positionOfChapter(chapters, 3), 3);
    });

    test('源给了带洞的序号也要找得到', () {
      final List<Chapter> holey = <Chapter>[
        const Chapter(index: 10, name: 'a'),
        const Chapter(index: 20, name: 'b'),
        const Chapter(index: 30, name: 'c'),
      ];
      expect(positionOfChapter(holey, 20), 1);
      // 找不到就夹住 —— 读错一章远好过悄悄回到第一章。
      expect(positionOfChapter(holey, 99), 2);
    });

    test('空目录回 -1，不要当成第 0 章', () {
      expect(positionOfChapter(const <Chapter>[], 3), -1);
    });
  });
}
