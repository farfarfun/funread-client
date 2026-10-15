import '../config/app_config.dart';
import '../models/models.dart';
import 'api_client.dart';

/// `/api/v1/reader/*`：搜索 → 详情 → 目录 → 正文这条主链路。
class ReaderApi {
  const ReaderApi(this._client);

  final ApiClient _client;

  /// 聚合搜索。
  ///
  /// **慢**：一次调用在服务端扇出到几十个书源，十几秒是正常的，所以单独
  /// 放宽接收超时（[AppConfig.searchTimeout]）。界面必须给进度指示，
  /// 并且允许用户在等待时改关键词。
  ///
  /// [maxSources] 不传就用后端默认值。不要在客户端往下收 —— 候选池里
  /// 实跑可用率只有个位数百分比，卡在几十个源上就等于「这本书搜不到」。
  /// 真正护住响应时间的是服务端的墙钟预算。
  Future<SearchPage> search(
    String keyword, {
    int limit = 20,
    int offset = 0,
    int? maxSources,
  }) async {
    final Object? data = await _client.get(
      '/reader/search',
      query: <String, dynamic>{
        'keyword': keyword,
        'limit': limit,
        'offset': offset,
        'max_sources': maxSources,
      },
      receiveTimeout: AppConfig.searchTimeout,
    );
    return SearchPage.fromJson(asMap(data));
  }

  /// 书籍详情。[name] / [author] 是给源做二次校验用的，有就传。
  Future<BookInfo> bookInfo({
    required int urlId,
    required String bookUrl,
    String name = '',
    String author = '',
  }) async {
    final Object? data = await _client.get(
      '/reader/book',
      query: <String, dynamic>{
        'url_id': urlId,
        'book_url': bookUrl,
        'name': name,
        'author': author,
      },
    );
    return BookInfo.fromJson(asMap(data));
  }

  /// 目录。是 POST 不是 GET：引擎需要**整个** [BookInfo]（含 variables）
  /// 才能继续往下走，详见 `BookInfo` 的类注释。
  Future<TocPage> toc(int urlId, BookInfo book) async {
    final Object? data = await _client.post(
      '/reader/toc',
      body: <String, dynamic>{'url_id': urlId, 'book': book.toJson()},
      // 有的源目录是分页抓的，几千章要抓很久。
      receiveTimeout: const Duration(seconds: 90),
    );
    return TocPage.fromJson(asMap(data));
  }

  /// 正文。
  ///
  /// [bookKey] 非空时后端会走离线缓存（命中直接读，未命中抓完写回），
  /// 所以书架里的书**一定要带上它**，否则离线下载等于白做。
  Future<ChapterContent> content({
    required int urlId,
    required Chapter chapter,
    BookInfo? book,
    String bookKey = '',
  }) async {
    final Object? data = await _client.post(
      '/reader/content',
      body: <String, dynamic>{
        'url_id': urlId,
        'chapter': chapter.toJson(),
        'book': book?.toJson(),
        'book_key': bookKey,
      },
      receiveTimeout: const Duration(seconds: 60),
    );
    return ChapterContent.fromJson(asMap(data));
  }
}
