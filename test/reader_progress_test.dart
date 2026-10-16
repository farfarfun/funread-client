import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:funread_client/src/models/models.dart';
import 'package:funread_client/src/state/book_detail_controller.dart';
import 'package:funread_client/src/state/reader_controller.dart';

import 'support/backend.dart';

/// 多设备进度冲突。
///
/// 进度是一人一本书**一条**记录、后写覆盖先写。这一组钉的是「只问不跳」：
/// 回到前台时比一次服务端进度，不一致**只弹窗**，跳不跳由人决定。
/// 自动跳转在「我就是想回头重读前面几章」时会把人强行拽走，而那种情况下
/// 服务端进度同样比本地靠后，程序分不出来。
void main() {
  const BookRef ref = BookRef(
    bookKey: FakeBackend.bookKey,
    urlId: 7,
    bookUrl: 'http://src.test/b/1',
    name: '书名',
    author: '作者',
  );

  /// 进度回写是 fire-and-forget 的，断言之前给它一个跑完的机会。
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

  Future<BookDetailController> openDetail(FakeBackend backend) async {
    final BookDetailController detail =
        BookDetailController(api: backend.api, ref: ref);
    addTearDown(detail.dispose);
    await detail.load();
    return detail;
  }

  Future<ReaderController> openReader(
    FakeBackend backend,
    BookDetailController detail, {
    int position = 0,
    // 节流窗口拉到测试里不可能到期：这样每一次写都能追溯到具体的触发点，
    // 而不是「刚好那个定时器响了」。
    Duration throttle = const Duration(minutes: 5),
  }) async {
    final ReaderController reader = ReaderController(
      api: backend.api,
      ref: detail.ref,
      info: detail.info!,
      chapters: detail.chapters,
      position: position,
      onShelf: detail.onShelf,
      saveThrottle: throttle,
    );
    addTearDown(reader.dispose);
    await reader.load();
    await settle();
    return reader;
  }

  List<int> offsetsWritten(FakeBackend backend) => <int>[
        for (final RequestOptions options
            in backend.requestsTo('/shelf/${FakeBackend.bookKey}/progress'))
          (options.data as Map<String, dynamic>)['char_offset'] as int,
      ];

  List<int> chaptersWritten(FakeBackend backend) => <int>[
        for (final RequestOptions options
            in backend.requestsTo('/shelf/${FakeBackend.bookKey}/progress'))
          (options.data as Map<String, dynamic>)['chapter_index'] as int,
      ];

  test('别的设备读到了后面：只问不跳 —— 位置不动，只多出一个待回答的问题', () async {
    final FakeBackend backend = FakeBackend();
    final BookDetailController detail = await openDetail(backend);
    final ReaderController reader = await openReader(backend, detail);

    // 这一页停在第 1 章；手机上读到了第 3 章。
    backend.progressChapterIndex = 2;
    backend.progressCharOffset = 500;
    await reader.checkRemoteProgress();

    expect(reader.conflict, isNotNull);
    expect(reader.conflict!.position, 2);
    expect(reader.conflict!.localPosition, 0);
    expect(reader.conflict!.charOffset, 500);
    expect(reader.conflict!.chapterName, '第 3 章');
    // 关键：**没有**自己跳过去。
    expect(reader.position, 0);
    expect(reader.current!.index, 0);
  });

  test('待回答期间一次进度都不写 —— 否则弹窗还没点完远端就被盖了', () async {
    final FakeBackend backend = FakeBackend();
    final BookDetailController detail = await openDetail(backend);
    final ReaderController reader = await openReader(backend, detail);
    final int before = offsetsWritten(backend).length;

    backend.progressChapterIndex = 2;
    await reader.checkRemoteProgress();

    // 回到前台那一下的滚动事件（惯性回弹、键盘收起都会触发）不该写出去。
    reader.onOffsetChanged(7);
    await reader.flush();
    await settle();

    expect(offsetsWritten(backend), hasLength(before));
  });

  test('「跳过去」才落到远端那一章，而且带着远端的章内偏移', () async {
    final FakeBackend backend = FakeBackend();
    final BookDetailController detail = await openDetail(backend);
    final ReaderController reader = await openReader(backend, detail);

    backend.progressChapterIndex = 2;
    backend.progressCharOffset = 500;
    await reader.checkRemoteProgress();
    await reader.acceptRemoteProgress();
    await settle();

    expect(reader.conflict, isNull);
    expect(reader.position, 2);
    expect(reader.restoreOffset, 500);
    // 正文是新章的，不是把旧章留在屏幕上。
    final Map<String, dynamic> body =
        backend.lastRequestTo('/reader/content')!.data as Map<String, dynamic>;
    expect((body['chapter'] as Map<String, dynamic>)['index'], 2);
    expect(chaptersWritten(backend).last, 2);
  });

  test('「留在这里」留在原地，并立刻把本地位置写出去 —— 这是用户自己选的覆盖', () async {
    final FakeBackend backend = FakeBackend();
    final BookDetailController detail = await openDetail(backend);
    final ReaderController reader = await openReader(backend, detail);

    reader.onOffsetChanged(66);
    backend.progressChapterIndex = 2;
    await reader.checkRemoteProgress();
    reader.keepLocalProgress();
    await settle();

    expect(reader.conflict, isNull);
    expect(reader.position, 0);
    // 攒着的那一笔补上了：不写的话，另一台设备再读一下又会把它翻过来。
    expect(offsetsWritten(backend), contains(66));
    expect(chaptersWritten(backend).last, 0);
  });

  test('远端和本地在同一章就别打扰 —— 否则每次切回前台都弹一次', () async {
    final FakeBackend backend = FakeBackend();
    final BookDetailController detail = await openDetail(backend);
    final ReaderController reader = await openReader(backend, detail, position: 1);

    // 服务端那条记录本来就是第 2 章（下标 1），章内偏移差一截也不算冲突。
    backend.progressCharOffset = 9999;
    await reader.checkRemoteProgress();

    expect(reader.conflict, isNull);
  });

  test('问题还挂着的时候不重复问', () async {
    final FakeBackend backend = FakeBackend();
    final BookDetailController detail = await openDetail(backend);
    final ReaderController reader = await openReader(backend, detail);
    final int before = backend.requestsTo('/shelf').length;

    backend.progressChapterIndex = 2;
    await reader.checkRemoteProgress();
    await reader.checkRemoteProgress();

    expect(backend.requestsTo('/shelf'), hasLength(before + 1));
  });

  test('试读时一次都不问 —— 书不在书架，那条记录根本不存在', () async {
    final FakeBackend backend = FakeBackend(onShelf: false);
    final BookDetailController detail = await openDetail(backend);
    final ReaderController reader = await openReader(backend, detail);
    final int before = backend.requestsTo('/shelf').length;

    await reader.checkRemoteProgress();

    expect(reader.conflict, isNull);
    expect(backend.requestsTo('/shelf'), hasLength(before));
  });

  test('书架问不到（掉线 / 会话过期）就当没问过，本地照常回写', () async {
    final FakeBackend backend = FakeBackend(shelfStatus: 500);
    final BookDetailController detail = await openDetail(backend);
    // 书架 500 时详情页把书当成「不在书架」，这里要的是「在书架但问不到」，
    // 所以手搓一个 onShelf 的控制器。
    final ReaderController reader = ReaderController(
      api: backend.api,
      ref: ref,
      info: detail.info!,
      chapters: detail.chapters,
      position: 0,
      onShelf: true,
      saveThrottle: const Duration(minutes: 5),
    );
    addTearDown(reader.dispose);
    await reader.load();
    await settle();

    await reader.checkRemoteProgress();
    reader.onOffsetChanged(88);
    await reader.flush();
    await settle();

    expect(reader.conflict, isNull);
    // 问不到不等于要停写：用户什么都没做错，停写只会白丢进度。
    expect(offsetsWritten(backend), contains(88));
  });
}
