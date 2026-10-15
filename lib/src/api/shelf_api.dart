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
  Future<String> add(SearchBook book, {SourceRef? source}) async {
    final SourceRef? ref = source ?? (book.sources.isEmpty ? null : book.sources.first);
    final Object? data = await _client.post(
      '/shelf',
      body: <String, dynamic>{
        'name': book.name,
        'author': book.author,
        'cover_url': book.coverUrl,
        'intro': book.intro,
        'url_id': ref?.urlId,
        'book_url': ref?.bookUrl ?? '',
        'last_chapter': book.lastChapter,
      },
    );
    return asMap(data)['book_key'] as String? ?? '';
  }

  Future<void> remove(String bookKey) async {
    await _client.delete('/shelf/$bookKey');
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
