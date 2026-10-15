import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import 'api_exception.dart';
import 'cookie_store.dart';

/// 往 [Dio] 上装会话凭证的那一步。
///
/// 抽成函数类型有两个理由：后端的设备 token 落地之后，换掉的就是这一个值
/// （不用动 [ApiClient] 的其它部分）；以及 widget 测试要能把它换成空实现 ——
/// 默认实现在原生端会去问 path_provider，而平台通道的往返在
/// `flutter_test` 的 fake async 里永远回不来，整个应用会卡在启动闸门上。
typedef CredentialInstaller = Future<void> Function(Dio dio);

/// 所有 HTTP 细节收口在这里：基址拼接、凭证、超时、错误翻译。
///
/// 上面的 `AuthApi` / `ShelfApi` / `ReaderApi` 只负责「哪个路径、什么形状」，
/// 不碰 dio。这样换 HTTP 库、加 Bearer token、加重试，都只动这一个文件。
class ApiClient {
  ApiClient({String? baseUrl, Dio? dio, CredentialInstaller? installCredentials})
      : _dio = dio ?? Dio(),
        _installCredentials = installCredentials ?? attachCookieStore,
        _baseUrl = _normalize(baseUrl ?? AppConfig.defaultApiBase) {
    _dio.options
      ..baseUrl = _endpoint(_baseUrl)
      // 连不上要快点报错：自托管服务常常就没开，让用户等 30 秒没有意义。
      ..connectTimeout = const Duration(seconds: 8)
      // 默认接收超时按「一次普通查询」定。搜索那种实时聚合的接口在
      // ReaderApi 里单独放宽，不要为了它把所有接口都拖成 2 分钟 ——
      // 那样一个挂住的详情请求会一直占着 loading 不放。
      ..receiveTimeout = const Duration(seconds: 30)
      ..sendTimeout = const Duration(seconds: 30)
      ..headers = <String, dynamic>{'Accept': 'application/json'}
      ..responseType = ResponseType.json
      // 自己判状态码，别让 dio 在 4xx/5xx 上抛掉 body —— FastAPI 的
      // `detail` 就在 body 里，那才是唯一能给用户看的东西。
      //
      // 外面那层括号是必须的：箭头函数的函数体会把后面的 `..` 一起吃进去，
      // 于是 `..responseType` 被当成 `bool` 上的 cascade，报一个和真实原因
      // 完全无关的「bool 没有 responseType 这个 setter」。
      ..validateStatus = ((int? status) => status != null && status < 500);
  }

  final Dio _dio;
  final CredentialInstaller _installCredentials;
  String _baseUrl;

  /// 当前后端地址（不含 `/api/v1`）。空串 = 同源（只在 web 上有意义）。
  String get baseUrl => _baseUrl;

  /// 凭证层只装一次。放成 late final 的 Future 而不是在构造函数里 fire-and-forget，
  /// 是为了让第一个请求**等它装完**：cookie 拦截器装晚了，首个请求就是匿名的。
  late final Future<void> _ready = _installCredentials(_dio);

  /// 切后端。地址是用户可改的（自托管没有「官方服务器」），
  /// 改完之后原来的会话多半不再适用，所以调用方要跟着重新探一次 `/auth/me`。
  void useBaseUrl(String value) {
    _baseUrl = _normalize(value);
    _dio.options.baseUrl = _endpoint(_baseUrl);
  }

  static String _normalize(String value) {
    final String trimmed = value.trim();
    // 空串在 web 上是「同源」，basePath 会变成相对的 `/api/v1`。
    // 原生端没有这个概念，而且 dio 在非 web 平台上会直接拒收相对 baseUrl
    // （"Must be a valid URL on platforms other than Web"），所以兜回默认地址
    // —— 否则「把地址清空」会炸在构造函数里，而不是给出一个能用的默认值。
    if (trimmed.isEmpty) return kIsWeb ? '' : AppConfig.nativeDefaultApiBase;
    // 用户多半会把尾斜杠带进来，也可能把 /api/v1 一起粘进来。都收掉，
    // 否则拼出 `//api/v1/api/v1/...` 这种只有 404 能告诉你的错。
    String cleaned = trimmed;
    while (cleaned.endsWith('/')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    if (cleaned.endsWith(AppConfig.apiPrefix)) {
      cleaned = cleaned.substring(0, cleaned.length - AppConfig.apiPrefix.length);
    }
    // 只粘了 `/api/v1` 进来的话，上面两步会把它削成空串。和一开始就是空串
    // 同一个处理，不要掉下去拼成 `http:///api/v1`。
    if (cleaned.isEmpty) return kIsWeb ? '' : AppConfig.nativeDefaultApiBase;
    // 只写了 host:port 的时候补上 scheme，默认 http —— 自托管实例绝大多数
    // 跑在局域网明文 http 上。
    if (!cleaned.startsWith('http://') && !cleaned.startsWith('https://')) {
      cleaned = 'http://$cleaned';
    }
    return cleaned;
  }

  static String _endpoint(String base) => '$base${AppConfig.apiPrefix}';

  Future<Object?> get(
    String path, {
    Map<String, dynamic>? query,
    Duration? receiveTimeout,
  }) {
    return _send(path, method: 'GET', query: query, receiveTimeout: receiveTimeout);
  }

  Future<Object?> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Duration? receiveTimeout,
  }) {
    return _send(
      path,
      method: 'POST',
      body: body,
      query: query,
      receiveTimeout: receiveTimeout,
    );
  }

  Future<Object?> put(String path, {Object? body}) {
    return _send(path, method: 'PUT', body: body);
  }

  Future<Object?> delete(String path, {Map<String, dynamic>? query}) {
    return _send(path, method: 'DELETE', query: query);
  }

  Future<Object?> _send(
    String path, {
    required String method,
    Object? body,
    Map<String, dynamic>? query,
    Duration? receiveTimeout,
  }) async {
    await _ready;
    Response<dynamic> response;
    try {
      response = await _dio.request<dynamic>(
        path,
        data: body,
        queryParameters: _clean(query),
        options: Options(method: method, receiveTimeout: receiveTimeout),
      );
    } on DioException catch (error) {
      throw _translate(error);
    }

    final int status = response.statusCode ?? 0;
    if (status >= 400) throw _fromStatus(status, response.data);
    // 204 的 body 是空的，dio 会给 null 或空串。调用方按 void 处理。
    if (status == 204) return null;
    return response.data;
  }

  /// 丢掉 `null` 的查询参数，**但保留空串**。
  ///
  /// 这点和 funread-web 的 `query()` 不一样，是故意的：后端有真正把空串当信号
  /// 的参数（`GET /shelf?group=` = 只看未分组，不传 = 整个书架）。
  /// 在通用层把空串吃掉，这类筛选就永远触发不了，而且报错是「结果不对」
  /// 不是「请求失败」，极难发现。需要省略的参数，调用方传 `null`。
  static Map<String, dynamic>? _clean(Map<String, dynamic>? query) {
    if (query == null) return null;
    final Map<String, dynamic> cleaned = <String, dynamic>{};
    for (final MapEntry<String, dynamic> entry in query.entries) {
      if (entry.value != null) cleaned[entry.key] = entry.value;
    }
    return cleaned;
  }

  ApiException _translate(DioException error) {
    final Response<dynamic>? response = error.response;
    if (response != null) {
      return _fromStatus(response.statusCode ?? 0, response.data);
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
        return ApiException(
          '连接 ${_display()} 超时。确认服务在跑、端口没被防火墙挡住。',
          isNetwork: true,
        );
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      // 响应体解析超时（dio 5.11 新增）。对用户来说和接收超时是一回事。
      case DioExceptionType.transformTimeout:
        return const ApiException(
          '服务器没有在预期时间内响应。聚合搜索本来就慢，但这一次超过了上限。',
          isNetwork: true,
        );
      case DioExceptionType.connectionError:
        return ApiException(
          '连不上 ${_display()}。检查地址是否正确、设备和服务端是否在同一网络。',
          isNetwork: true,
        );
      case DioExceptionType.badCertificate:
        return const ApiException('服务器证书不被信任。', isNetwork: true);
      case DioExceptionType.cancel:
        return const ApiException('请求已取消。');
      case DioExceptionType.badResponse:
        return const ApiException('服务器返回了无法解析的响应。');
      case DioExceptionType.unknown:
        return ApiException(
          '请求失败：${error.message ?? '未知错误'}',
          isNetwork: true,
        );
    }
  }

  String _display() => _baseUrl.isEmpty ? '当前站点' : _baseUrl;

  static ApiException _fromStatus(int status, Object? data) {
    final String detail = _detailOf(data) ?? '请求失败（HTTP $status）';
    if (status == 401) return UnauthorizedException(detail);
    if (status == 403) return ForbiddenException(detail);
    return ApiException(detail, statusCode: status);
  }

  /// FastAPI 的错误体有两种形状：`{"detail": "一句话"}`，
  /// 以及 422 校验失败时的 `{"detail": [{loc, msg, type}, ...]}`。
  /// 两种都要能说成人话，否则 422 在界面上就是一个空白提示。
  static String? _detailOf(Object? data) {
    if (data is Map) {
      final Object? detail = data['detail'];
      if (detail is String && detail.isNotEmpty) return detail;
      if (detail is List && detail.isNotEmpty) {
        final List<String> parts = <String>[];
        for (final Object? item in detail) {
          if (item is Map) {
            final Object? loc = item['loc'];
            final String field = loc is List && loc.isNotEmpty ? '${loc.last}' : '';
            final String msg = '${item['msg'] ?? ''}';
            parts.add(field.isEmpty ? msg : '$field: $msg');
          } else {
            parts.add('$item');
          }
        }
        return parts.join('；');
      }
    }
    if (data is String && data.isNotEmpty) return data;
    return null;
  }
}
