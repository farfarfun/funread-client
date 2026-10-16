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

  /// 换源候选列表。
  ///
  /// **这不是查库，是又一次实时聚合搜索。** 书架只记了当前在读的那一个源，
  /// 「这本书还能在哪儿读」只能现搜：服务端按书架里的书名扇出到候选池，
  /// 攒够 20 个命中或者墙钟预算（25 秒）用完才停。十几秒是常态，
  /// 所以这里用和搜索同一个放宽后的接收超时，界面必须给进度反馈。
  ///
  /// 唯一的入参就是 [bookKey] —— 后端要靠**调用者自己的书架记录**恢复书名，
  /// 所以书不在书架时它回 404（`书架里没有这本书`）。试读时不要发这个请求，
  /// 入口该直接禁用并说明原因。
  ///
  /// 出参里 `exact=false` 的候选**不要过滤掉**，理由见 [SwitchCandidate.exact]。
  Future<SwitchSourcePage> sources(String bookKey) async {
    final Object? data = await _client.get(
      '/reader/sources',
      query: <String, dynamic>{'book_key': bookKey},
      receiveTimeout: AppConfig.searchTimeout,
    );
    return SwitchSourcePage.fromJson(asMap(data));
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
  /// [bookKey] 非空时后端会走**服务端那层**章节缓存（命中直接读，未命中抓完
  /// 写回），所以一定要带上它 —— 不带就是每次都实抓源站。
  ///
  /// 注意服务端缓存命中时出参的 `next_url` 是**空串**（缓存表里没存它）。
  /// 翻章一律按目录下标走，不要去读 `next_url`，否则「第二次读同一章」
  /// 之后就没有下一章了。
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
