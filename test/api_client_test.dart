import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:funread_client/src/api/funread_api.dart';
import 'package:funread_client/src/models/models.dart';

import 'support/fake_adapter.dart';

void main() {
  // cookie jar 会去问 path_provider，而测试里没有插件实现。
  // ApiClient 把失败吞成内存 jar，这里只是让消息通道有个 binding 可用。
  TestWidgetsFlutterBinding.ensureInitialized();

  ({FunreadApi api, FakeAdapter adapter}) build(
    FakeResponse Function(RequestOptions options) respond,
  ) {
    final FakeAdapter adapter = FakeAdapter(respond);
    final Dio dio = Dio()..httpClientAdapter = adapter;
    return (
      api: FunreadApi(baseUrl: 'http://nas.test:18811', dio: dio),
      adapter: adapter,
    );
  }

  group('基址归一化', () {
    test('收掉尾斜杠、误粘的 /api/v1，并补上默认 scheme', () {
      expect(ApiClient(baseUrl: 'http://nas.test:18811/').baseUrl,
          'http://nas.test:18811');
      expect(ApiClient(baseUrl: 'http://nas.test:18811/api/v1').baseUrl,
          'http://nas.test:18811');
      expect(ApiClient(baseUrl: 'http://nas.test:18811/api/v1/').baseUrl,
          'http://nas.test:18811');
      // 用户只写主机端口是最常见的输入，不补 scheme 会直接连不上。
      expect(ApiClient(baseUrl: 'nas.test:18811').baseUrl, 'http://nas.test:18811');
      // 空串 = web 上的同源，必须原样保留。
      expect(ApiClient(baseUrl: '').baseUrl, '');
    });
  });

  group('reader', () {
    test('search 打在 /api/v1/reader/search 上，参数原样带过去', () async {
      final ({FunreadApi api, FakeAdapter adapter}) t = build(
        (RequestOptions options) => const FakeResponse(<String, dynamic>{
          'items': <dynamic>[],
          'total': 0,
          'limit': 20,
          'offset': 0,
          'sources_tried': 24,
          'stopped_by': 'budget',
        }),
      );

      final SearchPage page = await t.api.reader.search('诡秘', limit: 5);

      expect(t.adapter.lastRequest.uri.path, '/api/v1/reader/search');
      expect(t.adapter.lastRequest.queryParameters['keyword'], '诡秘');
      expect(t.adapter.lastRequest.queryParameters['limit'], 5);
      // max_sources 没传就不该出现在 query 里 —— 后端有自己的默认值，
      // 客户端擅自填一个小数字等于把搜索范围砍掉。
      expect(t.adapter.lastRequest.queryParameters.containsKey('max_sources'),
          isFalse);
      expect(page.stats.sourcesTried, 24);
    });

    test('toc 用 POST，并且把整个 BookInfo（含 variables）送回去', () async {
      final ({FunreadApi api, FakeAdapter adapter}) t = build(
        (RequestOptions options) => const FakeResponse(<String, dynamic>{
          'items': <dynamic>[],
          'total': 0,
        }),
      );

      await t.api.reader.toc(
        7,
        const BookInfo(
          name: '书',
          bookUrl: 'http://src.test/b/1',
          variables: <String, String>{'token': 'xyz'},
        ),
      );

      final RequestOptions sent = t.adapter.lastRequest;
      expect(sent.method, 'POST');
      expect(sent.uri.path, '/api/v1/reader/toc');
      final Map<String, dynamic> body = sent.data as Map<String, dynamic>;
      expect(body['url_id'], 7);
      final Map<String, dynamic> book = body['book'] as Map<String, dynamic>;
      expect(book['variables'], <String, String>{'token': 'xyz'});
      expect(book['book_url'], 'http://src.test/b/1');
    });
  });

  group('shelf', () {
    test('不传 group 时不带这个参数；传空串时必须带（= 只看未分组）', () async {
      final ({FunreadApi api, FakeAdapter adapter}) t =
          build((RequestOptions options) => const FakeResponse(<dynamic>[]));

      await t.api.shelf.list();
      expect(t.adapter.lastRequest.queryParameters.containsKey('group'), isFalse);

      await t.api.shelf.list(group: '');
      expect(t.adapter.lastRequest.queryParameters['group'], '');
    });
  });

  group('错误翻译', () {
    test('401 抛 UnauthorizedException，并带上后端的 detail', () async {
      final ({FunreadApi api, FakeAdapter adapter}) t = build(
        (RequestOptions options) => const FakeResponse(
          <String, dynamic>{'detail': '用户名或密码不正确'},
          statusCode: 401,
        ),
      );

      await expectLater(
        t.api.auth.login('alice', 'wrong'),
        throwsA(
          isA<UnauthorizedException>()
              .having((ApiException e) => e.message, 'message', '用户名或密码不正确'),
        ),
      );
    });

    test('403 抛 ForbiddenException —— 跳登录页对它没用', () async {
      final ({FunreadApi api, FakeAdapter adapter}) t = build(
        (RequestOptions options) => const FakeResponse(
          <String, dynamic>{'detail': '需要管理员'},
          statusCode: 403,
        ),
      );

      await expectLater(
        t.api.shelf.list(),
        throwsA(isA<ForbiddenException>()),
      );
    });

    test('422 的 detail 是数组，要拼成一句人话而不是空白提示', () async {
      final ({FunreadApi api, FakeAdapter adapter}) t = build(
        (RequestOptions options) => const FakeResponse(
          <String, dynamic>{
            'detail': <dynamic>[
              <String, dynamic>{
                'loc': <dynamic>['query', 'keyword'],
                'msg': 'ensure this value has at least 1 characters',
                'type': 'value_error',
              },
            ],
          },
          statusCode: 422,
        ),
      );

      await expectLater(
        t.api.reader.search('x'),
        throwsA(
          isA<ApiException>().having(
            (ApiException e) => e.message,
            'message',
            contains('keyword'),
          ),
        ),
      );
    });

    test('非 JSON 的错误体（反代的 HTML 错误页）退回 HTTP 码', () async {
      final ({FunreadApi api, FakeAdapter adapter}) t = build(
        (RequestOptions options) =>
            const FakeResponse('<html>502 Bad Gateway</html>', statusCode: 404),
      );

      await expectLater(
        t.api.auth.me(),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('logout', () {
    test('204 没有 body，不该当成解析失败', () async {
      final ({FunreadApi api, FakeAdapter adapter}) t = build(
        (RequestOptions options) => const FakeResponse(null, statusCode: 204),
      );

      await t.api.auth.logout();
      expect(t.adapter.lastRequest.uri.path, '/api/v1/auth/logout');
      expect(t.adapter.lastRequest.method, 'POST');
    });
  });
}
