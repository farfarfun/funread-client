import 'package:flutter_test/flutter_test.dart';
import 'package:funread_client/src/models/models.dart';

/// 这些样例贴的是 funread-api 的真实出参形状
/// （`funread_api/v1/reader.py`、`shelf.py`、`auth.py` 的 response_model）。
/// 后端改了契约，这里应该先红。
void main() {
  group('SearchPage', () {
    test('扁平的统计字段和 items 一起解析出来', () {
      final SearchPage page = SearchPage.fromJson(<String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{
            'book_key': 'abc123',
            'name': '诡秘之主',
            'author': '爱潜水的乌贼',
            'cover_url': 'http://example.test/cover.jpg',
            'intro': '蒸汽与机械的时代',
            'kind': '玄幻',
            'word_count': '460万字',
            'last_chapter': '第1430章',
            'sources': <dynamic>[
              <String, dynamic>{
                'url_id': 7,
                'source_name': '某书源',
                'book_url': 'http://src.test/book/1',
              },
              <String, dynamic>{
                'url_id': 9,
                'source_name': '另一个源',
                'book_url': 'http://src2.test/b/1',
              },
            ],
          },
        ],
        'total': 1,
        'limit': 20,
        'offset': 0,
        'sources_tried': 24,
        'sources_ok': 2,
        'hits': 1,
        'js_skipped': 5,
        'failed': 17,
        'waves': 3,
        'elapsed': 12.5,
        'exhausted': false,
        'stopped_by': 'enough',
      });

      expect(page.items, hasLength(1));
      expect(page.items.first.name, '诡秘之主');
      expect(page.items.first.sources.map((SourceRef r) => r.urlId), <int>[7, 9]);
      expect(page.total, 1);
      expect(page.stats.sourcesTried, 24);
      expect(page.stats.jsSkipped, 5);
      expect(page.stats.elapsed, 12.5);
      expect(page.stats.stoppedBy, 'enough');
      expect(page.hasMore, isFalse);
    });

    test('缺字段不抛，退化成零值 —— 后端加字段不该让客户端白屏', () {
      final SearchPage page = SearchPage.fromJson(<String, dynamic>{});
      expect(page.items, isEmpty);
      expect(page.total, 0);
      expect(page.stats.exhausted, isFalse);
    });

    test('空结果的解释按 stopped_by 分叉', () {
      SearchStats stats(String stoppedBy, {bool exhausted = false}) {
        return SearchStats.fromJson(<String, dynamic>{
          'sources_tried': 24,
          'stopped_by': stoppedBy,
          'exhausted': exhausted,
        });
      }

      // 「搜完了」才是确定的结论，其它都要告诉用户「可以再搜一次」。
      expect(stats('exhausted', exhausted: true).explainEmpty(), contains('确实没有'));
      expect(stats('budget').explainEmpty(), contains('再搜一次'));
      expect(stats('max_sources').explainEmpty(), contains('再搜一次'));
      expect(stats('empty').explainEmpty(), contains('scan'));
    });
  });

  group('BookInfo', () {
    test('toJson 是 fromJson 的逆 —— variables 丢了带变量的源会静默读空', () {
      final Map<String, dynamic> raw = <String, dynamic>{
        'name': '书名',
        'author': '作者',
        'book_url': 'http://src.test/b/1',
        'toc_url': 'http://src.test/b/1/toc',
        'kind': '都市',
        'word_count': '100万',
        'last_chapter': '第100章',
        'intro': '简介',
        'cover_url': 'http://src.test/c.jpg',
        'source_url': 'http://src.test',
        'source_name': '某书源',
        'can_rename': true,
        'variables': <String, dynamic>{'token': 'xyz', 'page': '2'},
      };

      final BookInfo info = BookInfo.fromJson(raw);
      expect(info.variables['token'], 'xyz');
      expect(BookInfo.fromJson(info.toJson()).toJson(), raw);
    });
  });

  group('Chapter', () {
    test('round-trip 保住 variables 和 index', () {
      final Chapter chapter = Chapter.fromJson(<String, dynamic>{
        'index': 12,
        'name': '第十三章',
        'url': 'http://src.test/c/13',
        'update_time': '2025-01-01',
        'is_vip': true,
        'is_pay': false,
        'variables': <String, dynamic>{'k': 'v'},
      });
      expect(chapter.index, 12);
      expect(chapter.isVip, isTrue);
      expect(Chapter.fromJson(chapter.toJson()).variables, <String, String>{'k': 'v'});
    });
  });

  group('ChapterContent', () {
    test('next_url 空串表示没有下一章', () {
      final ChapterContent content = ChapterContent.fromJson(<String, dynamic>{
        'title': '第一章',
        'text': '正文',
        'url': 'http://src.test/c/1',
        'next_url': '',
      });
      expect(content.nextUrl, isEmpty);
    });
  });

  group('ShelfBook', () {
    test('progress 可以为 null；group 空串是未分组', () {
      final List<ShelfBook> books = asList(<dynamic>[
        <String, dynamic>{
          'book_key': 'k1',
          'name': '有进度的书',
          'author': 'a',
          'cover_url': '',
          'intro': '',
          'url_id': 7,
          'book_url': 'u',
          'toc_url': 't',
          'last_chapter': '第9章',
          'updated_at': '2025-01-01T00:00:00',
          'progress': <String, dynamic>{
            'chapter_index': 3,
            'chapter_name': '第四章',
            'char_offset': 120,
          },
          'group': '玄幻',
          'chapter_count': 9,
          'unread': 5,
          'last_checked_at': '2025-01-02T00:00:00',
          'last_check_error': '',
        },
        <String, dynamic>{
          'book_key': 'k2',
          'name': '刚加的书',
          'url_id': null,
          'progress': null,
          'group': '',
          'last_check_error': '目录取不到',
        },
      ], ShelfBook.fromJson);

      expect(books, hasLength(2));
      expect(books[0].progress?.chapterIndex, 3);
      expect(books[0].hasUpdateError, isFalse);
      expect(books[1].progress, isNull);
      expect(books[1].urlId, isNull);
      expect(books[1].group, isEmpty);
      expect(books[1].hasUpdateError, isTrue);
    });
  });

  group('SessionState', () {
    test('一个账号都没有时后端给隐式本地身份：authenticated 真 + local 真', () {
      final SessionState state = SessionState.fromJson(<String, dynamic>{
        'auth_required': false,
        'admin': true,
        'reader_public': true,
        'register_open': true,
        'authenticated': true,
        'user_id': 0,
        'username': null,
        'local': true,
        'role': 'admin',
      });
      expect(state.authenticated, isTrue);
      expect(state.local, isTrue);
      expect(state.displayName, '本机身份');
    });

    test('登录之后显示用户名', () {
      final SessionState state = SessionState.fromJson(<String, dynamic>{
        'authenticated': true,
        'user_id': 3,
        'username': 'alice',
        'role': 'guest',
      });
      expect(state.displayName, 'alice');
      expect(state.admin, isFalse);
    });
  });
}
