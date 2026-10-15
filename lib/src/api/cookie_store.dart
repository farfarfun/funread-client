/// 会话凭证的平台分支。
///
/// ## 这是临时方案
///
/// funread 后端目前**只发 HttpOnly + SameSite=Lax 的 session cookie**
/// （见 `funread_api/v1/auth.py` 与 `funread_api/security.py`）。浏览器会自动
/// 管好它，原生端不会 —— 所以这里在 io 平台上自己挂一个 cookie jar 落盘。
///
/// cookie 对原生客户端是个糟糕的载体，原因不止「要自己存」：
///   - 没有过期协商，续期只能靠后端重发 Set-Cookie；
///   - 多账号 / 多服务器要自己做 jar 隔离；
///   - 撤销只能等 TTL 到期，丢手机之后没法远程下线；
///   - 和将来的 App Links / 分享打开等场景不好配合。
///
/// 后端已经计划加**设备 token（Bearer）**，但还没做。等它上线之后这一层的
/// 收口动作是：删掉 cookie_jar / dio_cookie_manager 两个依赖，把
/// [attachCookieStore] 换成一个往 header 里塞 `Authorization: Bearer <token>`
/// 的拦截器，并把 token 存到 flutter_secure_storage。**除了这个文件和
/// `auth_controller.dart` 里取登录态的那几行，其它地方不应该知道凭证长什么样。**
library;

export 'cookie_store_stub.dart'
    if (dart.library.io) 'cookie_store_io.dart'
    if (dart.library.js_interop) 'cookie_store_web.dart';
