import 'json.dart';

/// 阅读进度。`char_offset` 是章内字符偏移，换源之后不保证还对得上。
class ReadingProgress {
  const ReadingProgress({
    required this.chapterIndex,
    required this.chapterName,
    required this.charOffset,
  });

  factory ReadingProgress.fromJson(JsonMap json) {
    return ReadingProgress(
      chapterIndex: asInt(json['chapter_index']),
      chapterName: asString(json['chapter_name']),
      charOffset: asInt(json['char_offset']),
    );
  }

  final int chapterIndex;
  final String chapterName;
  final int charOffset;
}

/// `GET /api/v1/shelf` 的一行。
class ShelfBook {
  const ShelfBook({
    required this.bookKey,
    required this.name,
    required this.author,
    required this.coverUrl,
    required this.intro,
    required this.urlId,
    required this.bookUrl,
    required this.tocUrl,
    required this.lastChapter,
    required this.updatedAt,
    required this.progress,
    required this.group,
    required this.chapterCount,
    required this.unread,
    required this.lastCheckedAt,
    required this.lastCheckError,
  });

  factory ShelfBook.fromJson(JsonMap json) {
    final Object? progress = json['progress'];
    return ShelfBook(
      bookKey: asString(json['book_key']),
      name: asString(json['name']),
      author: asString(json['author']),
      coverUrl: asString(json['cover_url']),
      intro: asString(json['intro']),
      urlId: asIntOrNull(json['url_id']),
      bookUrl: asString(json['book_url']),
      tocUrl: asString(json['toc_url']),
      lastChapter: asString(json['last_chapter']),
      updatedAt: asString(json['updated_at']),
      progress: progress == null ? null : ReadingProgress.fromJson(asMap(progress)),
      group: asString(json['group']),
      chapterCount: asInt(json['chapter_count']),
      unread: asInt(json['unread']),
      lastCheckedAt: asString(json['last_checked_at']),
      lastCheckError: asString(json['last_check_error']),
    );
  }

  final String bookKey;
  final String name;
  final String author;
  final String coverUrl;
  final String intro;

  /// 当前在读的源。`null` = 书架里有这本书但还没定源（手动加的）。
  final int? urlId;
  final String bookUrl;
  final String tocUrl;
  final String lastChapter;
  final String updatedAt;
  final ReadingProgress? progress;

  /// 分组名。空串 = 未分组。
  final String group;

  /// 上次检查更新时数到的章节数。**0 表示还没查过**，不是「没有章节」。
  final int chapterCount;

  /// 后端按 [chapterCount] 和进度算出来的，不是独立字段。
  final int unread;

  /// 空串 = 还没查过。
  final String lastCheckedAt;

  /// 上次检查失败的原因，成功一次就清掉。界面据此在这本书上标个感叹号。
  final String lastCheckError;

  bool get hasUpdateError => lastCheckError.isNotEmpty;
}

/// `GET /api/v1/shelf/groups` 的一行。空串那组是「未分组」，后端排在最后。
class ShelfGroup {
  const ShelfGroup({required this.name, required this.count});

  factory ShelfGroup.fromJson(JsonMap json) {
    return ShelfGroup(
      name: asString(json['name']),
      count: asInt(json['count']),
    );
  }

  final String name;
  final int count;

  String get displayName => name.isEmpty ? '未分组' : name;
}
