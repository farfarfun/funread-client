import 'package:flutter/foundation.dart';

/// 编译期常量与默认值。
class AppConfig {
  const AppConfig._();

  static const String appName = 'funread';

  /// 后端 REST 的前缀，见 `funread_api/app.py`：
  /// `app.include_router(api_router, prefix="/api/v1")`。
  static const String apiPrefix = '/api/v1';

  /// `--dart-define=FUNREAD_API_BASE=http://nas.lan:18811`
  ///
  /// 打包给固定部署用时省掉首次配置。空串表示没指定。
  static const String compileTimeApiBase =
      String.fromEnvironment('FUNREAD_API_BASE');

  /// 原生端没有「同源」这回事时的兜底地址，也是后端的开发端口。
  static const String nativeDefaultApiBase = 'http://127.0.0.1:18811';

  /// 没有任何配置时用哪个地址。
  ///
  /// web 上默认**空串 = 同源**：浏览器里跨源请求要后端专门放行 CORS，
  /// 而自托管的标准形态是反向代理把 `/api` 和前端放在一个 origin 下
  /// （funread-web 就是这么跑的）。默认同源能让「构建产物丢进后端静态目录」
  /// 这条最省事的路开箱即用；要跨源调试就在设置里手填地址。
  ///
  /// 原生端没有「同源」这回事，必须给一个具体地址，默认取后端的开发端口。
  static String get defaultApiBase {
    if (compileTimeApiBase.isNotEmpty) return compileTimeApiBase;
    if (kIsWeb) return '';
    return nativeDefaultApiBase;
  }

  /// 聚合搜索的接收超时。
  ///
  /// 这个数字看着离谱，但它是后端行为的直接后果：一次搜索会并发扇出到几十个
  /// 书源，墙钟预算在服务端，客户端只能等。收得比服务端预算还紧，
  /// 结果就是「每次搜索都超时」而服务端其实正要返回。
  static const Duration searchTimeout = Duration(seconds: 120);
}
