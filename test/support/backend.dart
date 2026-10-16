import 'package:dio/dio.dart';
import 'package:funread_client/src/api/funread_api.dart';

import 'fake_adapter.dart';

/// 凭证层的空实现。真实的那个在原生端会去问 path_provider，
/// 而平台通道在测试里要么抛 MissingPluginException、要么根本回不来。
Future<void> noCredentials(Dio dio) async {}

/// 一个假后端：覆盖阅读链路上用到的全部端点。
///
/// 用它而不是给每个测试手搓一个 responder：这条链有五个端点，少接一个的表现
/// 是测试里冒出一个和被测行为无关的 404，排查成本远高于多写这几行。
class FakeBackend {
  FakeBackend({
    this.bookVariables = const <String, String>{'token': 'xyz'},
    this.chapterVariables = const <String, String>{'ck': '1'},
    this.chapterCount = 3,
    this.onShelf = true,
    this.text = '第一段。\n\n第二段。',
    this.shelfStatus = 200,
  });

  /// 详情里的规则变量。目录和正文都要原样收到它。
  final Map<String, String> bookVariables;

  /// 目录里每一章自己的变量。正文那一步要原样收到它。
  final Map<String, String> chapterVariables;

  final int chapterCount;

  /// 书在不在书架。决定 `GET /shelf` 回不回这本书。
  final bool onShelf;
  final String text;

  /// `GET /shelf` 的状态码。401 用来模拟「没登录也要能试读」。
  final int shelfStatus;

  /// 服务端那条进度记录。**故意不是 final**：测试跑到一半改掉它，就等于
  /// 「另一台设备在这期间读到了别的地方」—— 多设备冲突只能这么复现。
  int progressChapterIndex = 1;
  int progressCharOffset = 42;

  /// 书架记录上当前在读的源。换源会改它。
  int shelfUrlId = currentUrlId;

  /// `POST /shelf/{key}/source` 的出参。测试按需改，用来覆盖
  /// exact / position / none 三条说法完全不同的分支。
  String switchMethod = 'exact';
  int switchChapterIndex = 1;
  int switchTotal = 5;
  bool switchApproximate = false;

  /// `GET /reader/sources` 的状态码。404 = 书不在书架（后端的真实行为）。
  int sourcesStatus = 200;

  /// 换源列表在真实后端上要十几秒。要观察等待期间的界面状态时把它调大。
  Duration sourcesDelay = Duration.zero;

  /// 这个源的目录回空。书源池里能跑通的只有个位数百分比，「换过去发现
  /// 新源也是空的」是常态，不是边角情况。
  int? tocEmptyForUrlId;

  static const String bookKey = 'k1';

  /// 默认源，也是现有测试里那一个。
  static const int currentUrlId = 7;

  /// 换源要切到的那个。它的 variables、章节数、章节名都和 [currentUrlId]
  /// 不一样 —— 换源之后整条链必须用新源重算，这是唯一能钉住它的办法。
  static const int otherUrlId = 9;
  static const String otherBookUrl = 'http://src2.test/b/1';
  static const int otherChapterCount = 5;

  late final FakeAdapter adapter = FakeAdapter(_respond);

  /// `late final` 不是手滑：每次 get 都 new 一个 FunreadApi 的话，
  /// 测试里拿到的请求记录会散在好几个 adapter 上。
  late final FunreadApi api = FunreadApi(
    baseUrl: 'http://nas.test:18811',
    dio: Dio()..httpClientAdapter = adapter,
    installCredentials: noCredentials,
  );

  /// 打到某个路径的全部请求，按时间顺序。
  List<RequestOptions> requestsTo(String path) => <RequestOptions>[
        for (final RequestOptions options in adapter.requests)
          if (options.path == path) options,
      ];

  RequestOptions? lastRequestTo(String path) {
    final List<RequestOptions> all = requestsTo(path);
    return all.isEmpty ? null : all.last;
  }

  FakeResponse _respond(RequestOptions options) {
    switch (options.path) {
      case '/shelf':
        // 整个 /shelf 都要登录（后端是 `Depends(require_user)`），所以 401
        // 不能只套在 GET 上 —— 否则「没登录时点加入书架」这条分支测不到。
        if (shelfStatus != 200) {
          return FakeResponse(
            const <String, dynamic>{'detail': '需要登录'},
            statusCode: shelfStatus,
          );
        }
        if (options.method == 'POST') {
          return const FakeResponse(<String, dynamic>{'book_key': bookKey});
        }
        return FakeResponse(<dynamic>[
          if (onShelf)
            <String, dynamic>{
              'book_key': bookKey,
              'name': '书名',
              'author': '作者',
              'url_id': shelfUrlId,
              'book_url': shelfUrlId == currentUrlId
                  ? 'http://src.test/b/1'
                  : otherBookUrl,
              'progress': <String, dynamic>{
                'chapter_index': progressChapterIndex,
                'chapter_name': '第 ${progressChapterIndex + 1} 章',
                'char_offset': progressCharOffset,
              },
            },
        ]);
      case '/shelf/$bookKey':
        return const FakeResponse(null, statusCode: 204);
      case '/shelf/$bookKey/progress':
        return const FakeResponse(null, statusCode: 204);
      case '/shelf/$bookKey/source':
        if (!onShelf) {
          return const FakeResponse(
            <String, dynamic>{'detail': '书架里没有这本书'},
            statusCode: 404,
          );
        }
        // 换源是一次本地写库：书架记录上的源跟着变，进度被重定位到新目录的
        // 某一章，而章内偏移**一律清零**（偏移不能跨章沿用）。
        shelfUrlId = int.tryParse(
              '${(options.data as Map<String, dynamic>?)?['url_id']}',
            ) ??
            shelfUrlId;
        if (switchMethod != 'none' && switchMethod != 'skipped') {
          progressChapterIndex = switchChapterIndex;
          progressCharOffset = 0;
        }
        return FakeResponse(<String, dynamic>{
          'method': switchMethod,
          'chapter_index': switchChapterIndex,
          'chapter_name': '第 ${switchChapterIndex + 1} 章',
          'total': switchTotal,
          'is_approximate': switchApproximate,
        });
      case '/reader/sources':
        if (sourcesStatus != 200) {
          return FakeResponse(
            const <String, dynamic>{'detail': '书架里没有这本书'},
            statusCode: sourcesStatus,
          );
        }
        return FakeResponse(
          <String, dynamic>{
            'items': <dynamic>[
              <String, dynamic>{
                'url_id': currentUrlId,
                'source_name': '某书源',
                'book_url': 'http://src.test/b/1',
                'name': '书名',
                'author': '作者',
                'last_chapter': '第 3 章',
                'exact': true,
                'current': true,
              },
              <String, dynamic>{
                'url_id': otherUrlId,
                'source_name': '另一个源',
                'book_url': otherBookUrl,
                'name': '书名',
                // 同一个人，录入写法不同。这种候选**不能被藏起来**。
                'author': '作者（著）',
                'last_chapter': '第 5 章',
                'exact': false,
                'current': false,
              },
            ],
            'total': 2,
            'book_key': bookKey,
            'name': '书名',
            'sources_tried': 48,
            'sources_ok': 11,
            'hits': 2,
            'js_skipped': 6,
            'failed': 37,
            'waves': 2,
            'elapsed': 18.4,
            'exhausted': false,
            'stopped_by': 'budget',
          },
          delay: sourcesDelay,
        );
      case '/reader/book':
        final int urlId = int.tryParse('${options.queryParameters['url_id']}') ??
            currentUrlId;
        if (urlId != currentUrlId) {
          return FakeResponse(<String, dynamic>{
            'name': '书名',
            'author': '作者（著）',
            'book_url': otherBookUrl,
            'toc_url': '$otherBookUrl/toc',
            'intro': '简介',
            'source_name': '另一个源',
            'last_chapter': '第 $otherChapterCount 章',
            // 新源有自己的一套规则状态，和旧源的那份完全无关。
            'variables': <String, String>{'token': 'src$urlId'},
          });
        }
        return FakeResponse(<String, dynamic>{
          'name': '书名',
          'author': '作者',
          'book_url': 'http://src.test/b/1',
          'toc_url': 'http://src.test/b/1/toc',
          'intro': '简介',
          'cover_url': '',
          'source_name': '某书源',
          'last_chapter': '第 3 章',
          'variables': bookVariables,
        });
      case '/reader/toc':
        final Map<String, dynamic> tocBody =
            options.data as Map<String, dynamic>? ?? <String, dynamic>{};
        final int tocUrlId =
            tocBody['url_id'] is int ? tocBody['url_id'] as int : currentUrlId;
        if (tocUrlId == tocEmptyForUrlId) {
          return const FakeResponse(<String, dynamic>{
            'items': <dynamic>[],
            'total': 0,
          });
        }
        if (tocUrlId != currentUrlId) {
          // 章节数、章节名、章节 url 全都和旧源不一样：换源之后界面上还显示
          // 旧目录的话，这个差异会立刻露馅。
          return FakeResponse(<String, dynamic>{
            'items': <dynamic>[
              for (int i = 0; i < otherChapterCount; i++)
                <String, dynamic>{
                  'index': i,
                  'name': '新源第 ${i + 1} 章',
                  'url': '$otherBookUrl/c/$i',
                  'variables': <String, String>{'ck': 'src$tocUrlId'},
                },
            ],
            'total': otherChapterCount,
          });
        }
        return FakeResponse(<String, dynamic>{
          'items': <dynamic>[
            for (int i = 0; i < chapterCount; i++)
              <String, dynamic>{
                'index': i,
                'name': '第 ${i + 1} 章',
                'url': 'http://src.test/c/$i',
                'variables': chapterVariables,
              },
          ],
          'total': chapterCount,
        });
      case '/reader/content':
        final Map<String, dynamic> body =
            options.data as Map<String, dynamic>? ?? <String, dynamic>{};
        final Map<String, dynamic> chapter =
            body['chapter'] as Map<String, dynamic>? ?? <String, dynamic>{};
        return FakeResponse(<String, dynamic>{
          'title': chapter['name'] ?? '',
          'text': text,
          'url': chapter['url'] ?? '',
          'next_url': '',
        });
    }
    return const FakeResponse(
      <String, dynamic>{'detail': '假后端没有这个端点'},
      statusCode: 404,
    );
  }
}
