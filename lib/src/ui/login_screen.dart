import 'dart:async';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../state/auth_controller.dart';

/// 登录页。
///
/// 服务器地址和账号密码放在同一张表单里，而不是把地址藏进设置页：自托管应用
/// 第一次启动时，「连哪台机器」和「我是谁」是同一个动作的两半，拆开会让
/// 新用户在一个默认地址上反复输密码，然后以为是密码错了。
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _base = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _obscure = true;
  bool _seeded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 地址框的初值要从 AuthController 拿，而 InheritedWidget 在 initState 里
    // 还读不到，所以放这儿。只灌一次 —— 否则用户的编辑会被每次重建冲掉。
    if (_seeded) return;
    _seeded = true;
    _base.text = AppScope.of(context).auth.baseUrl;
  }

  @override
  void dispose() {
    _base.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _retry() async {
    final AuthController auth = AppScope.of(context).auth;
    await auth.setBaseUrl(_base.text);
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    // context 的读取全部发生在 await 之前 —— 登录成功之后 AuthGate 会把这个
    // State 换掉，之后再碰 context 就是 use_build_context_synchronously。
    final AuthController auth = AppScope.of(context).auth;
    final String base = _base.text.trim();
    if (base != auth.baseUrl) {
      await auth.setBaseUrl(base);
    }
    await auth.login(_username.text.trim(), _password.text);
    // 不用手动跳转：AuthGate 在监听 auth，登录成功它自己换屏。
  }

  void _onSubmitPressed() => unawaited(_submit());

  void _onRetryPressed() => unawaited(_retry());

  @override
  Widget build(BuildContext context) {
    final AuthController auth = AppScope.of(context).auth;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: ListenableBuilder(
                listenable: auth,
                builder: (BuildContext context, Widget? child) =>
                    _buildForm(context, auth),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context, AuthController auth) {
    final ThemeData theme = Theme.of(context);
    final bool unreachable = auth.stage == AuthStage.unreachable;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('funread', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 4),
          Text('自托管的小说与订阅阅读器', style: theme.textTheme.bodySmall),
          const SizedBox(height: 24),
          TextFormField(
            controller: _base,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'http://127.0.0.1:18811',
              helperText: '只写主机和端口即可，/api/v1 由客户端补',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _username,
            autocorrect: false,
            autofillHints: const <String>[AutofillHints.username],
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: '用户名',
              border: OutlineInputBorder(),
            ),
            validator: (String? value) =>
                (value == null || value.trim().isEmpty) ? '请输入用户名' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _password,
            obscureText: _obscure,
            autofillHints: const <String>[AutofillHints.password],
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (String value) => _onSubmitPressed(),
            decoration: InputDecoration(
              labelText: '密码',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示密码' : '隐藏密码',
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            validator: (String? value) =>
                (value == null || value.isEmpty) ? '请输入密码' : null,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: auth.busy ? null : _onSubmitPressed,
            child: auth.busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('登录'),
          ),
          if (unreachable) ...<Widget>[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: auth.busy ? null : _onRetryPressed,
              icon: const Icon(Icons.refresh),
              label: const Text('重试连接'),
            ),
          ],
          if (auth.session.readerPublic && !auth.session.authenticated) ...<Widget>[
            const SizedBox(height: 12),
            TextButton(
              onPressed: auth.continueAsGuest,
              child: const Text('不登录，先搜搜看'),
            ),
          ],
          if (auth.error != null) ...<Widget>[
            const SizedBox(height: 16),
            _ErrorBanner(message: auth.error!, unreachable: unreachable),
          ],
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.unreachable});

  final String message;
  final bool unreachable;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color =
        unreachable ? theme.colorScheme.tertiary : theme.colorScheme.error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            unreachable ? Icons.cloud_off : Icons.error_outline,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: TextStyle(color: color))),
        ],
      ),
    );
  }
}
