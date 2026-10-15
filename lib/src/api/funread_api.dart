import 'package:dio/dio.dart';

import 'api_client.dart';
import 'auth_api.dart';
import 'reader_api.dart';
import 'shelf_api.dart';

export 'api_client.dart';
export 'api_exception.dart';
export 'auth_api.dart';
export 'reader_api.dart';
export 'shelf_api.dart';

/// 界面依赖的唯一入口。
///
/// 按后端 router 分组（auth / shelf / reader），而不是摊成一个上百个方法的
/// 大对象 —— 后端就是这么分的，保持一致之后「这个接口在哪」不用查。
///
/// 测试里不需要为它写 mock：传一个挂了假 `HttpClientAdapter` 的 [Dio] 进来，
/// 走的就是真实的序列化与错误翻译路径，比 mock 一层接口覆盖得多。
class FunreadApi {
  FunreadApi({String? baseUrl, Dio? dio})
      : this.fromClient(ApiClient(baseUrl: baseUrl, dio: dio));

  FunreadApi.fromClient(this.client)
      : auth = AuthApi(client),
        shelf = ShelfApi(client),
        reader = ReaderApi(client);

  final ApiClient client;
  final AuthApi auth;
  final ShelfApi shelf;
  final ReaderApi reader;

  String get baseUrl => client.baseUrl;

  void useBaseUrl(String value) => client.useBaseUrl(value);
}
