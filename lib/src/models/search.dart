import 'json.dart';

/// 一本书在某个源下的落点。`url_id` + `book_url` 是后续所有调用的坐标。
class SourceRef {
  const SourceRef({
    required this.urlId,
    required this.sourceName,
    required this.bookUrl,
  });

  factory SourceRef.fromJson(JsonMap json) {
    return SourceRef(
      urlId: asInt(json['url_id']),
      sourceName: asString(json['source_name']),
      bookUrl: asString(json['book_url']),
    );
  }

  final int urlId;
  final String sourceName;
  final String bookUrl;
}

/// 一轮聚合搜索的统计。
///
/// 没有这组数字，「这本书没有」和「这轮试的源全死了」在界面上长得一模一样，
/// 而后者才是常态 —— 书源池里几千个源，实跑可用率只有个位数百分比。
/// 所以搜索页必须把它说出来，否则每次空结果都会被当成客户端的 bug。
class SearchStats {
  const SearchStats({
    required this.sourcesTried,
    required this.sourcesOk,
    required this.hits,
    required this.jsSkipped,
    required this.failed,
    required this.waves,
    required this.elapsed,
    required this.exhausted,
    required this.stoppedBy,
  });

  factory SearchStats.fromJson(JsonMap json) {
    return SearchStats(
      sourcesTried: asInt(json['sources_tried']),
      sourcesOk: asInt(json['sources_ok']),
      hits: asInt(json['hits']),
      jsSkipped: asInt(json['js_skipped']),
      failed: asInt(json['failed']),
      waves: asInt(json['waves']),
      elapsed: asDouble(json['elapsed']),
      exhausted: asBool(json['exhausted']),
      stoppedBy: asString(json['stopped_by']),
    );
  }

  final int sourcesTried;
  final int sourcesOk;

  /// 答出了结果的源数。攒够就停，所以它通常远小于 [sourcesTried]。
  final int hits;

  /// 需要 JS 运行时而被跳过的源数。这是结构性的，换关键词没用。
  final int jsSkipped;
  final int failed;

  /// 搜了几波并发。
  final int waves;
  final double elapsed;

  /// 候选池真的搜完了。只有此时「没搜到」才是确定的结论。
  final bool exhausted;

  /// `enough` | `budget` | `max_sources` | `exhausted` | `empty`
  final String stoppedBy;

  /// 空结果时给用户的一句解释。区分「确实没有」和「没搜完 / 源都挂了」。
  String explainEmpty() {
    if (exhausted) return '候选源池已经搜完，确实没有这本书。';
    if (stoppedBy == 'budget') {
      return '时间预算用完了（试了 $sourcesTried 个源，${elapsed.toStringAsFixed(1)} 秒），'
          '再搜一次可能会搜到别的源。';
    }
    if (stoppedBy == 'max_sources') {
      return '试满了 $sourcesTried 个源还没有命中，没搜完的源还有很多，可以再搜一次。';
    }
    if (stoppedBy == 'empty') {
      return '候选源池是空的 —— 后端还没跑过 `POST /reader/scan`。';
    }
    return '试了 $sourcesTried 个源，$failed 个失败、$jsSkipped 个需要 JS 被跳过。';
  }

  /// 结果列表底部那行小字。
  String summaryLine() {
    return '试了 $sourcesTried 个源 · $sourcesOk 个答了 · $hits 个有结果 · '
        '$failed 失败 · $jsSkipped 需 JS · $waves 波 · '
        '${elapsed.toStringAsFixed(1)}s · 停因 $stoppedBy';
  }
}

/// 搜索结果里的一本书。同名同作者的结果已经在后端按 `book_key` 合并过，
/// 所以 [sources] 往往不止一个 —— 哪个源能读要到详情页才知道。
class SearchBook {
  const SearchBook({
    required this.bookKey,
    required this.name,
    required this.author,
    required this.coverUrl,
    required this.intro,
    required this.kind,
    required this.wordCount,
    required this.lastChapter,
    required this.sources,
  });

  factory SearchBook.fromJson(JsonMap json) {
    return SearchBook(
      bookKey: asString(json['book_key']),
      name: asString(json['name']),
      author: asString(json['author']),
      coverUrl: asString(json['cover_url']),
      intro: asString(json['intro']),
      kind: asString(json['kind']),
      wordCount: asString(json['word_count']),
      lastChapter: asString(json['last_chapter']),
      sources: asList(json['sources'], SourceRef.fromJson),
    );
  }

  /// `md5(书名\n作者)`。书架、缓存、换源都用它当主键。
  final String bookKey;
  final String name;
  final String author;
  final String coverUrl;
  final String intro;
  final String kind;

  /// 字数是源里的原文（「123万字」这种），不是数字。
  final String wordCount;
  final String lastChapter;
  final List<SourceRef> sources;
}

/// `GET /api/v1/reader/search` 的出参：一页结果 + 这一轮的统计。
///
/// 分页是**当轮切片**，不是游标。每次调用都重跑一次实时聚合，
/// 所以第 2 页不保证接着第 1 页 —— 够用来做「加载更多」，不能做深翻页。
class SearchPage {
  const SearchPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
    required this.stats,
  });

  factory SearchPage.fromJson(JsonMap json) {
    return SearchPage(
      items: asList(json['items'], SearchBook.fromJson),
      total: asInt(json['total']),
      limit: asInt(json['limit']),
      offset: asInt(json['offset']),
      stats: SearchStats.fromJson(json),
    );
  }

  final List<SearchBook> items;

  /// 这一轮的总数，不是全网总数。客户端据此判断还要不要往下翻。
  final int total;
  final int limit;
  final int offset;
  final SearchStats stats;

  bool get hasMore => offset + items.length < total;
}
