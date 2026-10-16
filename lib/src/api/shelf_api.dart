import '../models/models.dart';
import 'api_client.dart';

/// `/api/v1/shelf/*`。这一版只做读取与最基本的增删，
/// 下载 / 检查更新 / 换源那几组是带 task_id 轮询的异步接口，留到阅读器阶段。
class ShelfApi {
  const ShelfApi(this._client);

  final ApiClient _client;

  /// 书架列表。
  ///
  /// [group] 的三态是后端的约定，不要简化：
  ///   - `null`（默认）= 整个书架；
  ///   - `''` = **只看未分组的书**；
  ///   - 其它 = 该分组。
  /// 空串和不传是两个不同的查询，所以 `ApiClient._clean` 刻意保留空串。
  Future<List<ShelfBook>> list({String? group}) async {
    final Object? data = await _client.get(
      '/shelf',
      query: group == null ? null : <String, dynamic>{'group': group},
    );
    return asList(data, ShelfBook.fromJson);
  }

  Future<List<ShelfGroup>> groups() async {
    final Object? data = await _client.get('/shelf/groups');
    return asList(data, ShelfGroup.fromJson);
  }

  /// 加入书架。幂等 —— 主键是 `md5(书名\n作者)`，再点一次是更新不是重复。
  ///
  /// 不传 `group` 是故意的：从搜索结果里再点一次「加入书架」不该把书
  /// 从用户分好的组里踢回未分组。
  Future<String> add(SearchBook book, {SourceRef? source}) {
    final SourceRef? ref = source ?? (book.sources.isEmpty ? null : book.sources.first);
    return _add(<String, dynamic>{
      'name': book.name,
      'author': book.author,
      'cover_url': book.coverUrl,
      'intro': book.intro,
      'url_id': ref?.urlId,
      'book_url': ref?.bookUrl ?? '',
      'last_chapter': book.lastChapter,
    });
  }

  /// 从详情页加入书架。
  ///
  /// 和 [add] 的区别不只是入参类型：详情页已经拿到了 `toc_url`，而搜索结果里
  /// 没有这个字段。带上它，书架那边做「检查更新」时就不必先走一次
  /// `/reader/book`——那一步会再打一次源站，正是最容易失败的一步。
  Future<String> addBook(BookInfo info, {required int urlId}) {
    return _add(<String, dynamic>{
      'name': info.name,
      'author': info.author,
      'cover_url': info.coverUrl,
      'intro': info.intro,
      'url_id': urlId,
      'book_url': info.bookUrl,
      'toc_url': info.tocUrl,
      'last_chapter': info.lastChapter,
    });
  }

  /// 出参是 `{"book_key": ...}`。后端算出来的 key 才是权威的 —— 它按自己的
  /// 口径归一化书名和作者，客户端不要自己算。
  Future<String> _add(Map<String, dynamic> body) async {
    final Object? data = await _client.post('/shelf', body: body);
    final Object? key = asMap(data)['book_key'];
    return key is String ? key : '';
  }

  Future<void> remove(String bookKey) async {
    await _client.delete('/shelf/$bookKey');
  }

  /// 换源：把书架记录上的源坐标换成 [urlId] / [bookUrl]。
  ///
  /// [remapProgress] 为真（默认）时后端会**再抓一次新源的目录**，拿已经存着的
  /// 章节名去新目录里找同一章，所以：
  ///
  ///  - 调它之前必须先把当前进度写掉（[saveProgress]）。后端是按**库里那条
  ///    记录**定位的，不是按请求里的任何字段 —— 少写这一步的表现是换完源
  ///    回到第一章。
  ///  - 它要抓目录，所以慢，接收超时按 `/reader/toc` 的量级给。
  ///
  /// 出参说的是「进度落在新源的第几章、怎么定位的」，见 [SwitchSourceResult]。
  /// 新源抓不到目录时它回 `method=none` 而**不是** 502 —— 换源本身是一次本地
  /// 写库，在重定位之前就已经成功了，没成的只是重定位。
  ///
  /// 副作用：后端会清掉这本书在**服务端**那层的全部章节缓存（那层按
  /// `book_key + chapter_index` 索引、不带源，换源之后序号的含义就变了）。
  /// 本机那层离线缓存是另一回事，见 `offline/offline_store.dart`。
  Future<SwitchSourceResult> switchSource(
    String bookKey, {
    required int urlId,
    required String bookUrl,
    bool remapProgress = true,
  }) async {
    final Object? data = await _client.post(
      '/shelf/$bookKey/source',
      body: <String, dynamic>{
        'url_id': urlId,
        'book_url': bookUrl,
        'remap_progress': remapProgress,
      },
      receiveTimeout: const Duration(seconds: 90),
    );
    return SwitchSourceResult.fromJson(asMap(data));
  }

  /// 保存进度。返回 204，没有 body。
  Future<void> saveProgress(
    String bookKey, {
    required int chapterIndex,
    String chapterUrl = '',
    String chapterName = '',
    int charOffset = 0,
  }) async {
    await _client.put(
      '/shelf/$bookKey/progress',
      body: <String, dynamic>{
        'chapter_index': chapterIndex,
        'chapter_url': chapterUrl,
        'chapter_name': chapterName,
        'char_offset': charOffset,
      },
    );
  }
}
