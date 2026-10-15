import 'json.dart';

/// 书籍详情，同时也是 `/reader/toc` 与 `/reader/content` 的**入参**。
///
/// 必须整体回传，一个字段都不能丢。原因在 [variables]：书源规则会在详情页用
/// `@put` 存变量、在目录页和正文页用 `@get` 取回来。中途把 variables 丢掉，
/// 用这个模式的源不会报错，而是**静默读到空目录或空正文** —— 这类 bug 在客户端
/// 这边看起来就是「这个源坏了」，极难定位。所以这个类有 [toJson]，
/// 并且 toJson 必须是 fromJson 的精确逆。
class BookInfo {
  const BookInfo({
    this.name = '',
    this.author = '',
    this.bookUrl = '',
    this.tocUrl = '',
    this.kind = '',
    this.wordCount = '',
    this.lastChapter = '',
    this.intro = '',
    this.coverUrl = '',
    this.sourceUrl = '',
    this.sourceName = '',
    this.canRename = false,
    this.variables = const <String, String>{},
  });

  factory BookInfo.fromJson(JsonMap json) {
    return BookInfo(
      name: asString(json['name']),
      author: asString(json['author']),
      bookUrl: asString(json['book_url']),
      tocUrl: asString(json['toc_url']),
      kind: asString(json['kind']),
      wordCount: asString(json['word_count']),
      lastChapter: asString(json['last_chapter']),
      intro: asString(json['intro']),
      coverUrl: asString(json['cover_url']),
      sourceUrl: asString(json['source_url']),
      sourceName: asString(json['source_name']),
      canRename: asBool(json['can_rename']),
      variables: asStringMap(json['variables']),
    );
  }

  final String name;
  final String author;
  final String bookUrl;
  final String tocUrl;
  final String kind;
  final String wordCount;
  final String lastChapter;
  final String intro;
  final String coverUrl;
  final String sourceUrl;
  final String sourceName;
  final bool canRename;

  /// 规则引擎跨请求携带的状态。**不要**在客户端读写它的内容。
  final Map<String, String> variables;

  JsonMap toJson() {
    return <String, dynamic>{
      'name': name,
      'author': author,
      'book_url': bookUrl,
      'toc_url': tocUrl,
      'kind': kind,
      'word_count': wordCount,
      'last_chapter': lastChapter,
      'intro': intro,
      'cover_url': coverUrl,
      'source_url': sourceUrl,
      'source_name': sourceName,
      'can_rename': canRename,
      'variables': variables,
    };
  }
}

/// 目录里的一章。和 [BookInfo] 一样要整体回传给 `/reader/content`。
class Chapter {
  const Chapter({
    this.index = 0,
    this.name = '',
    this.url = '',
    this.updateTime = '',
    this.isVip = false,
    this.isPay = false,
    this.variables = const <String, String>{},
  });

  factory Chapter.fromJson(JsonMap json) {
    return Chapter(
      index: asInt(json['index']),
      name: asString(json['name']),
      url: asString(json['url']),
      updateTime: asString(json['update_time']),
      isVip: asBool(json['is_vip']),
      isPay: asBool(json['is_pay']),
      variables: asStringMap(json['variables']),
    );
  }

  final int index;
  final String name;
  final String url;
  final String updateTime;
  final bool isVip;
  final bool isPay;
  final Map<String, String> variables;

  JsonMap toJson() {
    return <String, dynamic>{
      'index': index,
      'name': name,
      'url': url,
      'update_time': updateTime,
      'is_vip': isVip,
      'is_pay': isPay,
      'variables': variables,
    };
  }
}

/// `POST /api/v1/reader/toc` 的出参。
class TocPage {
  const TocPage({required this.items, required this.total});

  factory TocPage.fromJson(JsonMap json) {
    return TocPage(
      items: asList(json['items'], Chapter.fromJson),
      total: asInt(json['total']),
    );
  }

  final List<Chapter> items;
  final int total;
}

/// `POST /api/v1/reader/content` 的出参。
///
/// 后端刻意没有回 `pages`（分页抓取的未合并原文）—— 那是调试用的，
/// 带上会让每章的载荷差不多翻一倍。
class ChapterContent {
  const ChapterContent({
    required this.title,
    required this.text,
    required this.url,
    required this.nextUrl,
  });

  factory ChapterContent.fromJson(JsonMap json) {
    return ChapterContent(
      title: asString(json['title']),
      text: asString(json['text']),
      url: asString(json['url']),
      nextUrl: asString(json['next_url']),
    );
  }

  final String title;
  final String text;
  final String url;

  /// 空串 = 没有下一章（或者源没给）。
  final String nextUrl;
}
