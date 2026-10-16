import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'app_config.dart';

/// 本地偏好：后端地址 + 排版设置。
///
/// 两项都必须持久化，理由不同：自托管没有「官方服务器」，每次冷启动重输地址
/// 不能接受；排版则是**只该存在本地**的东西（手机和桌面的合适字号不一样，
/// 同步到服务端只会让两边互相打架）。
///
/// 所有方法都**吞掉异常**。偏好读不出来最多是回到默认值，
/// 为此让应用起不来是本末倒置；单元测试里没注册插件也会走到这条路。
class SettingsStore {
  static const String _apiBaseKey = 'api_base';
  static const String _readerKey = 'reader_settings';

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

  /// 排版设置。存成一个 JSON 串而不是四个键：以后加一项不用再动存储层，
  /// 而且「读出来的是不是同一次存的」是原子的。
  Future<ReaderSettings> loadReaderSettings() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_readerKey);
      if (raw == null || raw.isEmpty) return const ReaderSettings();
      // 存坏了（手改、跨版本）也要能起来：解析失败回默认，
      // 值越界由 ReaderSettings.fromJson 夹住。
      return ReaderSettings.fromJson(asMap(jsonDecode(raw)));
    } catch (_) {
      return const ReaderSettings();
    }
  }

  Future<void> saveReaderSettings(ReaderSettings value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_readerKey, jsonEncode(value.toJson()));
    } catch (_) {
      return;
    }
  }
}
