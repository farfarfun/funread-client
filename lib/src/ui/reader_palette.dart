import 'package:flutter/material.dart';

import '../models/models.dart';

/// 阅读主题的实际配色。
///
/// 不走 `ThemeData`：正文页的配色和应用主题是两件事 —— 夜里读书的人不一定
/// 把整个系统切成深色，而「护眼」那个米黄底在 Material 的色彩体系里根本没有
/// 对应概念。这里就是三组写死的颜色，简单到不会出错。
@immutable
class ReaderPalette {
  const ReaderPalette({
    required this.background,
    required this.text,
    required this.muted,
  });

  /// 正文底色。
  final Color background;

  /// 正文颜色。
  ///
  /// 夜间刻意**不是纯白**：纯白配纯黑的对比度在暗处会让字边缘发光（晕影），
  /// 读久了比亮屏还累。
  final Color text;

  /// 页码、提示这类次要文字。
  final Color muted;

  static const ReaderPalette day = ReaderPalette(
    background: Color(0xFFFFFFFF),
    text: Color(0xFF1B1B1B),
    muted: Color(0xFF6B6B6B),
  );

  /// 米黄底、暖褐字。降的是对比度，不是亮度。
  static const ReaderPalette eye = ReaderPalette(
    background: Color(0xFFF4EBD9),
    text: Color(0xFF3B3326),
    muted: Color(0xFF7A6E57),
  );

  static const ReaderPalette night = ReaderPalette(
    background: Color(0xFF121212),
    text: Color(0xFFB7B7B7),
    muted: Color(0xFF6E6E6E),
  );

  static ReaderPalette of(ReaderThemeId theme) {
    switch (theme) {
      case ReaderThemeId.day:
        return day;
      case ReaderThemeId.eye:
        return eye;
      case ReaderThemeId.night:
        return night;
    }
  }

  /// 状态栏图标该用深色还是浅色，以及这一页里 Material 控件的明暗。
  Brightness get brightness =>
      ThemeData.estimateBrightnessForColor(background);
}
