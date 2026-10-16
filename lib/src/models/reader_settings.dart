import 'json.dart';

/// 阅读主题。只有三个，不做自定义配色。
///
/// 这三个覆盖的是三种真实光照：白天（白底）、长时间阅读（米黄底，降低对比）、
/// 夜里（深底浅字）。再多就是调色板，而调色板的结果通常是一个没人想读的配色。
enum ReaderThemeId {
  day('日间'),
  eye('护眼'),
  night('夜间');

  const ReaderThemeId(this.label);

  /// 界面上显示的名字。
  final String label;

  /// 存下来的是枚举名。认不出来就回日间 —— 配置坏掉不该让人没法读书。
  static ReaderThemeId parse(Object? value) {
    final String name = asString(value);
    for (final ReaderThemeId id in ReaderThemeId.values) {
      if (id.name == name) return id;
    }
    return ReaderThemeId.day;
  }
}

/// 排版设置。**只存在本地**，不同步到服务端。
///
/// 这是故意的：手机和桌面的合适字号本来就不一样（一个是 390 逻辑像素宽、
/// 一手之距，一个是 1600 像素宽、一臂之距）。同步过去的结果是两边互相打架，
/// 每次换设备都要再调一次。进度要同步，排版不要。
class ReaderSettings {
  const ReaderSettings({
    this.fontSize = defaultFontSize,
    this.lineHeight = defaultLineHeight,
    this.pageMargin = defaultPageMargin,
    this.theme = ReaderThemeId.day,
  });

  factory ReaderSettings.fromJson(JsonMap json) {
    return ReaderSettings(
      fontSize: _number(
        json['font_size'],
        minFontSize,
        maxFontSize,
        defaultFontSize,
      ),
      lineHeight: _number(
        json['line_height'],
        minLineHeight,
        maxLineHeight,
        defaultLineHeight,
      ),
      pageMargin: _number(
        json['page_margin'],
        minPageMargin,
        maxPageMargin,
        defaultPageMargin,
      ),
      theme: ReaderThemeId.parse(json['theme']),
    );
  }

  static const double defaultFontSize = 18;
  static const double minFontSize = 12;
  static const double maxFontSize = 30;

  static const double defaultLineHeight = 1.7;
  static const double minLineHeight = 1.2;
  static const double maxLineHeight = 2.4;

  static const double defaultPageMargin = 20;
  static const double minPageMargin = 8;
  static const double maxPageMargin = 48;

  final double fontSize;

  /// 行距倍数（[TextStyle.height]）。
  final double lineHeight;

  /// 左右页边距。上下留白不可调 —— 它们是为刘海和手势条让的位置，不是审美。
  final double pageMargin;

  final ReaderThemeId theme;

  /// 段间距跟着字号走，不单独给一个滑块。
  ///
  /// 它和字号是同一件事的两面：18px 的字配 16px 的段距好看，28px 的字配
  /// 同样的 16px 就挤成一团。多一个滑块只会让人调出一个难看的版面。
  double get paragraphSpacing => fontSize * 0.9;

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    double? pageMargin,
    ReaderThemeId? theme,
  }) {
    return ReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      pageMargin: pageMargin ?? this.pageMargin,
      theme: theme ?? this.theme,
    );
  }

  JsonMap toJson() {
    return <String, dynamic>{
      'font_size': fontSize,
      'line_height': lineHeight,
      'page_margin': pageMargin,
      'theme': theme.name,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is ReaderSettings &&
        other.fontSize == fontSize &&
        other.lineHeight == lineHeight &&
        other.pageMargin == pageMargin &&
        other.theme == theme;
  }

  @override
  int get hashCode => Object.hash(fontSize, lineHeight, pageMargin, theme);

  /// 读回来的值一律夹进合法区间。
  ///
  /// 存坏了（手改、跨版本、浮点写成字符串）的表现否则是「正文变成 2 像素高」
  /// 或者「页边距吃掉整个屏幕」，而且重启也好不了 —— 坏值被存着。
  static double _number(Object? value, double min, double max, double fallback) {
    final double parsed = value is num
        ? value.toDouble()
        : double.tryParse(asString(value)) ?? fallback;
    if (parsed.isNaN || parsed.isInfinite) return fallback;
    return parsed.clamp(min, max);
  }
}
