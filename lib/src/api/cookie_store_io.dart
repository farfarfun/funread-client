import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:path_provider/path_provider.dart';

/// 全进程共用一个 jar。多个 [Dio] 实例（比如以后给下载单独起一个）必须
/// 看到同一份会话，否则换一个实例就变成未登录。
CookieJar? _jar;

/// 给 [dio] 挂上 cookie 拦截器。重复调用安全。
Future<void> attachCookieStore(Dio dio) async {
  final CookieJar jar = _jar ??= await _openJar();
  final bool already = dio.interceptors.any((Interceptor it) => it is CookieManager);
  if (already) return;
  dio.interceptors.add(CookieManager(jar));
}

Future<CookieJar> _openJar() async {
  try {
    final Directory base = await getApplicationSupportDirectory();
    final Directory dir = Directory('${base.path}/cookies');
    await dir.create(recursive: true);
    // FileStorage 要的是目录，而且要带尾斜杠 —— 它是直接拼文件名的。
    return PersistCookieJar(storage: FileStorage('${dir.path}/'));
  } catch (_) {
    // 落盘失败（沙箱只读、权限被拒、单元测试里没有 path_provider 插件）
    // 不该让应用起不来。退回内存 jar，代价只是下次冷启动要重新登录。
    return CookieJar();
  }
}

/// 退出登录时清掉本地那一份。
///
/// 后端的 `POST /auth/logout` 会 delete_cookie，但那只覆盖它知道的那一个；
/// 本地 jar 里还可能留着换服务器之前的残留，不清会在下次指回去时
/// 以一个**已经失效的 session** 复活，表现为「明明登出了却还显示已登录」。
Future<void> clearCookieStore() async {
  await _jar?.deleteAll();
}
