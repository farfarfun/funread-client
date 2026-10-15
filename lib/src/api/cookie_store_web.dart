import 'package:dio/browser.dart';
import 'package:dio/dio.dart';

/// 浏览器里 cookie 不归我们管：JS 读不到 HttpOnly cookie，也不允许手工设置
/// `Cookie` 请求头，所以 dio_cookie_manager 在 web 上是纯粹的空转
/// （挂上去只会多一层无效拦截器）。
///
/// 要让 session cookie 跟着请求走，只有两条路：
///
///  1. **同源部署** —— 反向代理把 `/api` 转到后端，前端和 API 同一个 origin，
///     浏览器自动带 cookie。这是推荐形态，funread-web 现在就是这么跑的。
///  2. **跨源 + withCredentials** —— 比如 `flutter run -d chrome` 调本机
///     18811。此时后端必须回 `Access-Control-Allow-Credentials: true`，
///     且 `Access-Control-Allow-Origin` **不能是 `*`**（带凭证时浏览器拒绝
///     通配符），还要放行预检。后端默认没开这个，所以跨源调试要自己配 CORS。
///
/// 这里统一打开 withCredentials：同源下它没有任何副作用，跨源下它是必要条件。
Future<void> attachCookieStore(Dio dio) async {
  dio.httpClientAdapter = BrowserHttpClientAdapter(withCredentials: true);
}

/// web 上没有我们自己的凭证存储 —— 清理由后端的 `Set-Cookie: ...; Max-Age=0`
/// 完成，客户端无能为力，也不需要能为力。
Future<void> clearCookieStore() async {}
