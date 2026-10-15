import 'json.dart';

/// `GET /api/v1/auth/me` 的出参，也是登录 / 注册的出参。
///
/// 这个结构决定界面渲染哪一屏，所以几个布尔值的区别要分清楚：
///
/// - [authenticated]：这次请求有没有一个读者身份。**它为真不代表有人登录过** ——
///   后端在「一个账号都还没建」的时候会发一个隐式本地身份，此时
///   [local] 也为真。客户端该直接进应用，并（以后）提示去注册。
/// - [authRequired]：**采集管理端**要不要口令。和读者登录是两套东西。
/// - [admin]：当前身份是不是管理员角色，决定放不放行管理页。
/// - [readerPublic]：只读的阅读接口对未登录开放。为真时搜索页不登录也能用，
///   但书架仍然要身份。
class SessionState {
  const SessionState({
    required this.authRequired,
    required this.admin,
    required this.readerPublic,
    required this.registerOpen,
    required this.authenticated,
    required this.userId,
    required this.username,
    required this.local,
    required this.role,
  });

  factory SessionState.fromJson(JsonMap json) {
    return SessionState(
      authRequired: asBool(json['auth_required']),
      admin: asBool(json['admin']),
      readerPublic: asBool(json['reader_public']),
      registerOpen: asBool(json['register_open']),
      authenticated: asBool(json['authenticated']),
      userId: asIntOrNull(json['user_id']),
      username: asStringOrNull(json['username']),
      local: asBool(json['local']),
      role: asStringOrNull(json['role']),
    );
  }

  static const SessionState anonymous = SessionState(
    authRequired: false,
    admin: false,
    readerPublic: false,
    registerOpen: false,
    authenticated: false,
    userId: null,
    username: null,
    local: false,
    role: null,
  );

  final bool authRequired;
  final bool admin;
  final bool readerPublic;
  final bool registerOpen;
  final bool authenticated;
  final int? userId;
  final String? username;
  final bool local;
  final String? role;

  /// 界面上怎么称呼当前这个人。隐式本地身份没有用户名。
  String get displayName {
    final String? name = username;
    if (name != null && name.isNotEmpty) return name;
    if (local) return '本机身份';
    return '未登录';
  }
}

/// `GET /api/v1/auth/accounts`：首次运行探针，只暴露计数，不暴露用户列表。
class AccountSummary {
  const AccountSummary({
    required this.users,
    required this.registerOpen,
    required this.minPasswordLength,
    required this.bootstrap,
  });

  factory AccountSummary.fromJson(JsonMap json) {
    return AccountSummary(
      users: asInt(json['users']),
      registerOpen: asBool(json['register_open']),
      minPasswordLength: asInt(json['min_password_length']),
      bootstrap: asBool(json['bootstrap']),
    );
  }

  final int users;
  final bool registerOpen;
  final int minPasswordLength;

  /// 还没有任何账号。注册表单此时**不能**要邀请码。
  final bool bootstrap;
}
