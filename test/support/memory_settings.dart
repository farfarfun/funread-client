import 'package:funread_client/src/config/settings_store.dart';
import 'package:funread_client/src/models/models.dart';

/// 偏好的内存实现，顶掉 shared_preferences。
///
/// 真实的那个走平台通道，而 widget 测试里的平台通道要么抛
/// `MissingPluginException`、要么根本回不来 —— 两种都会让「这个测试为什么
/// 没反应」变成一道谜题。[writes] 顺带钉住「什么时候才真的落盘」。
class MemorySettings implements SettingsStore {
  MemorySettings({String apiBase = 'http://nas.test:18811'}) : _base = apiBase;

  String _base;

  ReaderSettings reader = const ReaderSettings();

  /// 写过几次。拖滑块只该在松手时写一次。
  int writes = 0;

  @override
  Future<String> loadApiBase() async => _base;

  @override
  Future<void> saveApiBase(String value) async {
    _base = value;
  }

  @override
  Future<ReaderSettings> loadReaderSettings() async => reader;

  @override
  Future<void> saveReaderSettings(ReaderSettings value) async {
    reader = value;
    writes++;
  }
}
