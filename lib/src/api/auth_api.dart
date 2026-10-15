import '../models/models.dart';
import 'api_client.dart';
import 'cookie_store.dart';

/// `/api/v1/auth/*`。
class AuthApi {
  const AuthApi(this._client);

  final ApiClient _client;

  /// 当前会话。**不会抛 401** —— 这个端点对未登录也返回 200，
  /// 用 `authenticated` 字段表达结果。界面启动时先问它，再决定渲染哪一屏。
  Future<SessionState> me() async {
    final Object? data = await _client.get('/auth/me');
    return SessionState.fromJson(asMap(data));
  }

  /// 首次运行探针：没有任何账号时 `bootstrap` 为真，注册表单不该要邀请码。
  Future<AccountSummary> accounts() async {
    final Object? data = await _client.get('/auth/accounts');
    return AccountSummary.fromJson(asMap(data));
  }

  /// 读者登录。失败一律 401，文案由后端给（它刻意不区分
  /// 「用户不存在」和「密码错」，不要在客户端猜）。
  Future<SessionState> login(String username, String password) async {
    final Object? data = await _client.post(
      '/auth/login',
      body: <String, dynamic>{'username': username, 'password': password},
    );
    return SessionState.fromJson(asMap(data));
  }

  /// 注册。[code] 为邀请码；首次运行那条路不需要，传空串即可
  /// —— 后端要的就是空串而不是省略，这样失败是「邀请码不可用」
  /// 而不是一个前端要特殊处理的 422。
  Future<SessionState> register(
    String username,
    String password, {
    String code = '',
  }) async {
    final Object? data = await _client.post(
      '/auth/register',
      body: <String, dynamic>{
        'username': username,
        'password': password,
        'code': code,
      },
    );
    return SessionState.fromJson(asMap(data));
  }

  /// 登出。后端返回 204 并清 cookie；本地 jar 也要清，
  /// 原因见 `cookie_store_io.dart` 里 `clearCookieStore` 的注释。
  Future<void> logout() async {
    try {
      await _client.post('/auth/logout');
    } finally {
      // 后端够不到（断网、服务挂了）也必须把本地凭证清掉 —— 用户点了登出，
      // 界面就不能再是已登录状态，否则下次冷启动会「自己登回去」。
      await clearCookieStore();
    }
  }
}
