import 'package:flutter_test/flutter_test.dart';
import 'package:funread_client/src/config/settings_store.dart';
import 'package:funread_client/src/models/models.dart';
import 'package:funread_client/src/state/reader_settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_settings.dart';

/// 排版设置：取值的合法性、落盘时机、以及**不上云**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('取值', () {
    test('缺字段退化成默认值，不是零值', () {
      final ReaderSettings settings =
          ReaderSettings.fromJson(<String, dynamic>{});

      expect(settings.fontSize, ReaderSettings.defaultFontSize);
      expect(settings.lineHeight, ReaderSettings.defaultLineHeight);
      expect(settings.pageMargin, ReaderSettings.defaultPageMargin);
      expect(settings.theme, ReaderThemeId.day);
    });

    test('存坏了的值夹进合法区间 —— 否则正文会变成 2 像素高，而且重启也好不了', () {
      final ReaderSettings settings = ReaderSettings.fromJson(<String, dynamic>{
        'font_size': 2,
        'line_height': 99,
        'page_margin': -40,
        'theme': '幻彩',
      });

      expect(settings.fontSize, ReaderSettings.minFontSize);
      expect(settings.lineHeight, ReaderSettings.maxLineHeight);
      expect(settings.pageMargin, ReaderSettings.minPageMargin);
      // 认不出来的主题回日间，不是抛异常。
      expect(settings.theme, ReaderThemeId.day);
    });

    test('toJson 是 fromJson 的逆', () {
      const ReaderSettings settings = ReaderSettings(
        fontSize: 22,
        lineHeight: 2,
        pageMargin: 32,
        theme: ReaderThemeId.night,
      );

      expect(ReaderSettings.fromJson(settings.toJson()), settings);
    });

    test('段距跟着字号走，不单独给一个滑块', () {
      const ReaderSettings small = ReaderSettings(fontSize: 14);
      const ReaderSettings large = ReaderSettings(fontSize: 28);
      expect(large.paragraphSpacing, greaterThan(small.paragraphSpacing));
    });
  });

  group('落盘', () {
    test('存了能读回来', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsStore store = SettingsStore();
      const ReaderSettings settings = ReaderSettings(
        fontSize: 24,
        lineHeight: 1.4,
        pageMargin: 12,
        theme: ReaderThemeId.eye,
      );

      await store.saveReaderSettings(settings);

      expect(await store.loadReaderSettings(), settings);
    });

    test('偏好里是一串垃圾时回默认值，而不是让正文页起不来', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'reader_settings': '{不是 JSON',
      });

      expect(await SettingsStore().loadReaderSettings(), const ReaderSettings());
    });
  });

  group('控制器', () {
    test('拖滑块只改内存并通知，松手才写 —— 一次拖动否则要写几十遍', () async {
      final MemorySettings store = MemorySettings();
      final ReaderSettingsController controller =
          ReaderSettingsController(store: store);
      addTearDown(controller.dispose);
      int notified = 0;
      controller.addListener(() => notified++);

      controller.update(const ReaderSettings(fontSize: 20));
      controller.update(const ReaderSettings(fontSize: 21));

      expect(notified, 2);
      expect(controller.value.fontSize, 21);
      expect(store.writes, 0);

      await controller.persist();
      expect(store.writes, 1);
      expect(store.reader.fontSize, 21);
    });

    test('改成一样的值不通知 —— 否则滑块停在原地也会让整章重排', () {
      final ReaderSettingsController controller =
          ReaderSettingsController(store: MemorySettings());
      addTearDown(controller.dispose);
      int notified = 0;
      controller.addListener(() => notified++);

      controller.update(const ReaderSettings());

      expect(notified, 0);
    });

    test('切主题是一次性动作，改完立刻落盘', () async {
      final MemorySettings store = MemorySettings();
      final ReaderSettingsController controller =
          ReaderSettingsController(store: store);
      addTearDown(controller.dispose);

      await controller.commit(
        controller.value.copyWith(theme: ReaderThemeId.night),
      );

      expect(store.writes, 1);
      expect(store.reader.theme, ReaderThemeId.night);
    });

    test('冷启动读回上次的设置', () async {
      final MemorySettings store = MemorySettings()
        ..reader = const ReaderSettings(fontSize: 26);
      final ReaderSettingsController controller =
          ReaderSettingsController(store: store);
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.value.fontSize, 26);
    });
  });
}
