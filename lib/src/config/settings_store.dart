import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';

/// 本地偏好。现在只有一项（后端地址），但它必须持久化：
/// 自托管没有「官方服务器」，每次冷启动都要重输地址是不能接受的。
///
/// 所有方法都**吞掉异常**。偏好读不出来最多是回到默认值，
/// 为此让应用起不来是本末倒置；单元测试里没注册插件也会走到这条路。
class SettingsStore {
  static const String _apiBaseKey = 'api_base';

  Future<String> loadApiBase() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? saved = prefs.getString(_apiBaseKey);
      if (saved != null && saved.isNotEmpty) return saved;
    } catch (_) {
      return AppConfig.defaultApiBase;
    }
    return AppConfig.defaultApiBase;
  }

  Future<void> saveApiBase(String value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_apiBaseKey, value);
    } catch (_) {
      // 存不下就算了，这一次会话照样能用。
      return;
    }
  }
}
