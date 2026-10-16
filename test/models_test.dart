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

  group('SwitchSourcePage', () {
    /// 贴的是 `funread_api/v1/reader.py` 的 `SwitchSourcePage` / `SwitchCandidate`：
    /// 统计字段和 `/reader/search` 一样**平铺**在同一层。
    SwitchSourcePage parse() {
      return SwitchSourcePage.fromJson(<String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{
            'url_id': 7,
            'source_name': '某书源',
            'book_url': 'http://src.test/b/1',
            'name': '诡秘之主',
            'author': '爱潜水的乌贼',
            'last_chapter': '第1430章',
            'exact': true,
            'current': true,
          },
          <String, dynamic>{
            'url_id': 9,
            'source_name': '另一个源',
            'book_url': 'http://src2.test/b/1',
            'name': '诡秘之主',
            // 同一个人，写法不一样。这一条恰恰常常是还活着的那个源。
            'author': '爱潜水的乌贼（著）',
            'last_chapter': '第1431章',
            'exact': false,
            'current': false,
          },
        ],
        'total': 2,
        'book_key': 'abc123',
        'name': '诡秘之主',
        'sources_tried': 48,
        'sources_ok': 11,
        'hits': 2,
        'js_skipped': 6,
        'failed': 37,
        'waves': 2,
        'elapsed': 18.4,
        'exhausted': false,
        'stopped_by': 'budget',
      });
    }

    test('候选和平铺的统计一起解析出来', () {
      final SwitchSourcePage page = parse();
      expect(page.items, hasLength(2));
      expect(page.bookKey, 'abc123');
      expect(page.name, '诡秘之主');
      expect(page.stats.sourcesTried, 48);
      expect(page.stats.stoppedBy, 'budget');
      expect(page.items.first.displayName, '某书源');
      expect(page.items.first.current, isTrue);
    });

    test('exact=false 的候选分到另一组，但一条都不能少', () {
      final SwitchSourcePage page = parse();
      expect(page.exactItems, hasLength(1));
      expect(page.looseItems, hasLength(1));
      // 关键：两组加起来就是全部。过滤掉近似匹配 = 换源列表永远是空的。
      expect(page.exactItems.length + page.looseItems.length, page.items.length);
      expect(page.looseItems.single.author, '爱潜水的乌贼（著）');
    });

    test('源名为空时退回「源 #id」，不要显示一个空行', () {
      final SwitchCandidate candidate = SwitchCandidate.fromJson(
        <String, dynamic>{'url_id': 12, 'source_name': '', 'book_url': 'u'},
      );
      expect(candidate.displayName, '源 #12');
      expect(candidate.exact, isFalse);
    });

    test('空列表的解释要区分「源都没答」和「确实只有这一个源」', () {
      SwitchSourcePage empty(Map<String, dynamic> stats) =>
          SwitchSourcePage.fromJson(<String, dynamic>{
            'items': <dynamic>[],
            'total': 0,
            ...stats,
          });

      expect(empty(<String, dynamic>{'sources_tried': 0}).explainEmpty(),
          contains('候选源池是空的'));
      expect(
        empty(<String, dynamic>{'sources_tried': 40, 'sources_ok': 0}).explainEmpty(),
        contains('都没有响应'),
      );
      expect(
        empty(<String, dynamic>{
          'sources_tried': 400,
          'sources_ok': 90,
          'exhausted': true,
        }).explainEmpty(),
        contains('只有当前这一个源'),
      );
    });
  });

  group('SwitchSourceResult', () {
    SwitchSourceResult parse(Map<String, dynamic> json) =>
        SwitchSourceResult.fromJson(json);

    test('按章节名定位到了就直接接着读，不必打扰用户', () {
      final SwitchSourceResult result = parse(<String, dynamic>{
        'method': 'normalized',
        'chapter_index': 101,
        'chapter_name': '第 102 章',
        'total': 1430,
        'is_approximate': false,
      });
      expect(result.method, SwitchMethod.normalized);
      expect(result.relocated, isTrue);
      expect(result.needsConfirm, isFalse);
      expect(result.describe('某书源'), contains('第 102 / 1430 章'));
    });

    test('position 是按比例估的，必然不准 —— 要提示确认', () {
      final SwitchSourceResult result = parse(<String, dynamic>{
        'method': 'position',
        'chapter_index': 90,
        'chapter_name': '第 91 章',
        'total': 1200,
        'is_approximate': true,
      });
      expect(result.relocated, isTrue);
      expect(result.needsConfirm, isTrue);
      expect(result.describe('某书源'), contains('偏差'));
    });

    test('none：目录都没拿到，total 是 0，不要写成「第 N / 0 章」', () {
      final SwitchSourceResult result = parse(<String, dynamic>{
        'method': 'none',
        'chapter_index': 30,
        'chapter_name': '第 31 章',
        'total': 0,
      });
      expect(result.relocated, isFalse);
      expect(result.needsConfirm, isTrue);
      expect(result.describe(''), isNot(contains('/ 0')));
      expect(result.describe(''), contains('目录'));
    });

    test('skipped = 本来就没有进度可搬，不是失败', () {
      final SwitchSourceResult result =
          parse(<String, dynamic>{'method': 'skipped', 'total': 0});
      expect(result.method, SwitchMethod.skipped);
      expect(result.needsConfirm, isFalse);
      expect(result.describe('某书源'), contains('还没有阅读进度'));
    });

    test('不认识的 method 当成「说不准」，宁可多问一次', () {
      final SwitchSourceResult result =
          parse(<String, dynamic>{'method': 'fuzzy-v2', 'total': 5});
      expect(result.method, SwitchMethod.unknown);
      expect(result.needsConfirm, isTrue);
    });
  });
}
