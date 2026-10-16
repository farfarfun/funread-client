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

  static const String bookKey = 'k1';

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
              'url_id': 7,
              'book_url': 'http://src.test/b/1',
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
      case '/reader/book':
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
