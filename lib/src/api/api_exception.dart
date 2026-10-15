/// 整个 API 层对外**只抛这一棵异常树**。
///
/// 界面不该见到 `DioException` —— 一旦见到，换 HTTP 库就要改所有 catch，
/// 而且 dio 的报错文案（"DioException [connection error]..."）直接显示给
/// 读者是没有意义的。所有翻译发生在 `ApiClient._translate`。
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.isNetwork = false});

  /// 已经是中文人话，可以直接显示。优先取 FastAPI 的 `detail`。
  final String message;

  /// `null` = 请求根本没到达服务端（连不上、超时、被取消）。
  final int? statusCode;

  /// 网络层问题而不是业务拒绝。界面据此决定给不给「重试」按钮。
  final bool isNetwork;

  @override
  String toString() => message;
}

/// 后端回了 401。
///
/// 单独一个类型是因为调用方的处理方式完全不同：不是弹个错误框，
/// 而是把会话状态切回未登录并跳登录页。和 funread-web 的
/// `UnauthorizedError` 是同一个约定。
class UnauthorizedException extends ApiException {
  const UnauthorizedException([String message = '需要登录'])
      : super(message, statusCode: 401);
}

/// 后端回了 403：身份有效，但权限不够（比如非 admin 访问管理端）。
/// 和 401 分开，是因为跳登录页对它没有任何帮助。
class ForbiddenException extends ApiException {
  const ForbiddenException([String message = '没有权限'])
      : super(message, statusCode: 403);
}
