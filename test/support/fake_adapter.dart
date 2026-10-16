import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 假的 [HttpClientAdapter]。
///
/// 用它而不是 mock 一层自己的接口：这样测试跑的是**真实的** dio 路径 ——
/// query 拼接、JSON 序列化、状态码判定、错误翻译全都算数，
/// 只有最后那次 socket 读写被换掉。mock 掉 `FunreadApi` 的话，
/// 这些恰恰是最容易出错的地方就一行都测不到。
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.respond);

  /// 根据请求决定回什么。测试里直接用 `options.path` / `options.queryParameters`
  /// 做断言，所以每次请求都留一份在 [requests] 里。
  final FakeResponse Function(RequestOptions options) respond;

  final List<RequestOptions> requests = <RequestOptions>[];

  RequestOptions get lastRequest => requests.last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final FakeResponse reply = respond(options);
    // 真实后端里「慢」是一等公民（聚合搜索十几秒），测试里默认零延迟。
    // 只有要观察等待期间的界面状态（计时、禁用）时才把它调大。
    if (reply.delay > Duration.zero) await Future<void>.delayed(reply.delay);
    if (reply.statusCode == 204) {
      return ResponseBody.fromString('', 204);
    }
    return ResponseBody.fromString(
      reply.body is String ? reply.body as String : jsonEncode(reply.body),
      reply.statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class FakeResponse {
  const FakeResponse(
    this.body, {
    this.statusCode = 200,
    this.delay = Duration.zero,
  });

  /// `body` 是 String 就原样当报文发（测非 JSON 的代理错误页），
  /// 其它类型走 jsonEncode。
  final Object? body;
  final int statusCode;

  /// 回这一条之前先等多久。默认不等。
  final Duration delay;
}
