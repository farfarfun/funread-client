import 'json.dart';
import 'search.dart';

/// 换源列表里的一项：一个源 + 这本书**在该源下**的样子。
///
/// 后端只给这八个字段，没有封面 / 简介 / 字数 —— 换源要判断的是「这是不是
/// 同一本书、这个源活不活」，不是重新挑一本书。
class SwitchCandidate {
  const SwitchCandidate({
    required this.urlId,
    required this.sourceName,
    required this.bookUrl,
    this.name = '',
    this.author = '',
    this.lastChapter = '',
    this.exact = false,
    this.current = false,
  });

  factory SwitchCandidate.fromJson(JsonMap json) {
    return SwitchCandidate(
      urlId: asInt(json['url_id']),
      sourceName: asString(json['source_name']),
      bookUrl: asString(json['book_url']),
      name: asString(json['name']),
      author: asString(json['author']),
      lastChapter: asString(json['last_chapter']),
      exact: asBool(json['exact']),
      current: asBool(json['current']),
    );
  }

  final int urlId;
  final String sourceName;
  final String bookUrl;

  /// 这个源里这本书叫什么。后端已经按归一化书名筛过，所以它和书架里的书名
  /// 要么相同、要么只差标点空白。
  final String name;

  /// 这个源里登记的作者。和书架里的**可能不一样** —— 见 [exact]。
  final String author;
  final String lastChapter;

  /// 书名**和作者**都对得上（后端算出来的 `book_key` 完全相同）。
  ///
  /// 为 `false` 的候选**不能隐藏**。作者名的写法差异（空白、繁简、
  /// 「（著）」后缀、把笔名写成本名）在书源里非常常见，而那些源往往恰恰
  /// 还活着 —— 把它们筛掉的结果是「换源列表永远是空的」。
  /// 界面可以把 `exact` 的排在前面并解释清楚差异，但不能过滤。
  final bool exact;

  /// 正在读的就是这个源。
  final bool current;

  /// 界面上怎么称呼这个源。源名可能是空的。
  String get displayName => sourceName.isEmpty ? '源 #$urlId' : sourceName;

  /// 复用搜索结果那套坐标类型，省得下游再认一种。
  SourceRef get source =>
      SourceRef(urlId: urlId, sourceName: sourceName, bookUrl: bookUrl);
}

/// `GET /api/v1/reader/sources` 的出参。
///
/// 它和 `/reader/search` 一样带着一整组搜索统计，原因也一样：这是一次
/// **实时聚合搜索**（书架只记了当前在读的那个源），空列表既可能是
/// 「真的只有这一个源有」，也可能是「这一轮试的源全挂了」，
/// 不把统计说出来的话两者在界面上长得一模一样。
class SwitchSourcePage {
  const SwitchSourcePage({
    required this.items,
    required this.total,
    required this.bookKey,
    required this.name,
    required this.stats,
  });

  factory SwitchSourcePage.fromJson(JsonMap json) {
    return SwitchSourcePage(
      items: asList(json['items'], SwitchCandidate.fromJson),
      total: asInt(json['total']),
      bookKey: asString(json['book_key']),
      name: asString(json['name']),
      // 统计是**平铺**在同一层的，不是嵌在 `stats` 里。
      stats: SearchStats.fromJson(json),
    );
  }

  final List<SwitchCandidate> items;

  /// 这一轮搜出来的候选数，不是全网总数。
  final int total;
  final String bookKey;

  /// 书架里记的书名。换源搜的就是它。
  final String name;
  final SearchStats stats;

  /// 书名和作者都对得上的那批。后端已经把它们排在前面了。
  List<SwitchCandidate> get exactItems => <SwitchCandidate>[
        for (final SwitchCandidate item in items)
          if (item.exact) item,
      ];

  /// 书名对得上、作者写法不同的那批。
  ///
  /// **它们要照样显示出来**，只是单独分一组并说明原因 —— 见
  /// [SwitchCandidate.exact]。
  List<SwitchCandidate> get looseItems => <SwitchCandidate>[
        for (final SwitchCandidate item in items)
          if (!item.exact) item,
      ];

  /// 空列表时给用户的一句解释。三种处境的下一步动作完全不同。
  String explainEmpty() {
    if (stats.sourcesTried == 0) {
      return '候选源池是空的 —— 后端还没跑过 `POST /reader/scan`。';
    }
    if (stats.sourcesOk == 0) {
      return '这一轮试的 ${stats.sourcesTried} 个源都没有响应。'
          '不是没有别的源，是它们这次都没答上来，再搜一次通常会换一批。';
    }
    if (stats.exhausted) {
      return '候选池已经搜完，确实只有当前这一个源有这本书。';
    }
    return '搜到的源里没有同名的书。可以再搜一次 —— 每次试的源不完全一样。';
  }
}

/// 换源之后，原来的阅读进度被重新定位到了哪一章，以及**怎么**定位的。
///
/// 这个区分不是实现细节，它决定界面该说什么、要不要拦一下用户：
/// 按章节名对上的可以直接接着读，按比例估的则**必然不准**。
enum SwitchMethod {
  /// 章节名完全一致。
  exact,

  /// 章节名归一化（去掉卷名前缀、全半角、空白）之后一致。
  normalized,

  /// 新源里找不到同名章节，**按比例估**的位置。两个源的分卷方式、
  /// 有没有收录番外、章节拆分粒度都不一样，所以这个落点必然不准，
  /// 要让用户确认而不是直接开始读。
  position,

  /// 新源的目录取不到（或者是空的），进度没动。要用户自己选章。
  none,

  /// 本来就没有进度可搬（还没开始读）。
  skipped,

  /// 后端给了一个这一版不认识的值。当成「不确定落点对不对」处理 ——
  /// 多问一次远好过把人放在一个错误的章节上。
  unknown;

  static SwitchMethod parse(Object? value) {
    final String name = asString(value);
    for (final SwitchMethod method in SwitchMethod.values) {
      if (method != SwitchMethod.unknown && method.name == name) return method;
    }
    return SwitchMethod.unknown;
  }
}

/// `POST /api/v1/shelf/{book_key}/source` 的出参。
///
/// 注意它**没有** `char_offset`：后端在重定位时一律把章内偏移清零
/// （偏移不能跨章沿用，两个源的同一章字数也对不上），所以换源之后永远从
/// 章首开始读。
class SwitchSourceResult {
  const SwitchSourceResult({
    required this.method,
    required this.chapterIndex,
    required this.chapterName,
    required this.total,
    required this.isApproximate,
  });

  factory SwitchSourceResult.fromJson(JsonMap json) {
    return SwitchSourceResult(
      method: SwitchMethod.parse(json['method']),
      chapterIndex: asInt(json['chapter_index']),
      chapterName: asString(json['chapter_name']),
      total: asInt(json['total']),
      isApproximate: asBool(json['is_approximate']),
    );
  }

  /// 新源目录里的序号（`Chapter.index` 的口径，不是列表下标）。
  final int chapterIndex;
  final String chapterName;

  /// 新源的目录有多少章。`method` 是 `none` / `skipped` 时是 **0**，
  /// 此时不要往界面上写「第 N / 0 章」。
  final int total;

  final SwitchMethod method;

  /// 后端自己标的「这个落点是估的」。目前只有 [SwitchMethod.position] 会为真。
  final bool isApproximate;

  /// 定位成功，可以直接把人放到那一章。
  bool get relocated =>
      method == SwitchMethod.exact ||
      method == SwitchMethod.normalized ||
      method == SwitchMethod.position;

  /// 落点靠不住，**要先问一句**再接着读。
  ///
  /// 比后端的 [isApproximate] 多收两种：拿不到目录（`none`）和这一版不认识的
  /// 方式（`unknown`）。这两种同样是「程序说不准人读到哪了」。
  bool get needsConfirm =>
      isApproximate ||
      method == SwitchMethod.position ||
      method == SwitchMethod.none ||
      method == SwitchMethod.unknown;

  /// 一句给用户看的话。[sourceName] 是换到的那个源。
  String describe(String sourceName) {
    final String where = sourceName.isEmpty ? '新源' : '「$sourceName」';
    // total 为 0 时后端根本没拿到新目录，写「/ 0 章」只会让人以为书没了。
    final String position = total > 0
        ? '第 ${chapterIndex + 1} / $total 章'
        : '第 ${chapterIndex + 1} 章';
    switch (method) {
      case SwitchMethod.exact:
        return '已切换到$where，定位到$position。';
      case SwitchMethod.normalized:
        return '已切换到$where，按章节名定位到$position。';
      case SwitchMethod.position:
        return '已切换到$where，按位置估到$position —— 两个源的分卷和章节拆分'
            '方式不一样，这个落点多半有偏差。';
      case SwitchMethod.none:
        return '已切换到$where，但没能取到新源的目录，进度没有移动。'
            '请自己在目录里找一下读到哪了。';
      case SwitchMethod.skipped:
        return '已切换到$where。这本书还没有阅读进度，不需要重新定位。';
      case SwitchMethod.unknown:
        return '已切换到$where，但后端给的定位方式这一版还不认识，'
            '请确认一下落在了对的地方。';
    }
  }
}
