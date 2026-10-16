import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../models/models.dart';

/// 一章正文的**版面测量结果**：每段多高、从哪个像素开始、覆盖哪一段字符。
///
/// ## 为什么需要它
///
/// 正文从「`SingleChildScrollView` 套 `Column` 一次性建完」换成了懒构建
/// （`ListView.builder`）。懒构建有个直接后果：没建出来的 item 没有高度，
/// `maxScrollExtent` 只能按已经建出来的那几段的平均高度**估**，于是它会随着
/// 「你往下滚了多少」一直变。
///
/// 而原来的换算两头都架在这个值上（已读字符 / 总字符 × 可滚高度），
/// 一旦它会变，存进去的 `char_offset` 和恢复出来的位置就都在漂。
/// 这是这次改造最容易出错的地方，所以这里**不绕过去，而是把它拆掉**：
///
///  1. 开章时用 [TextPainter] 把每一段的高度量出来 —— 和渲染走同一套排版引擎，
///     量出来的就是实际高度；
///  2. 把这张表交给 `ListView.builder` 的 `itemExtentBuilder`，于是滚动范围
///     在第一帧就是**准确且恒定**的，跳到任何位置也不用先把中间的段落建一遍；
///  3. 字符 ↔ 像素改成**逐段插值**：先定位到哪一段，再在段内按比例。
///     不再假设字符在整章里均匀分布。
///
/// ## 代价
///
/// 开章时要把全章段落量一遍，是 O(段数) 次文本测量。它不建 widget、不进
/// render tree、不绘制，比「一次性建出几千个 `Text`」便宜得多；而且只有量过
/// 一遍才可能让 `itemExtentBuilder` 说真话。字号 / 边距 / 窗口宽度变了要重量，
/// 所以调用方必须按这些值做缓存（见 `reader_screen.dart` 的 `_LayoutKey`）。
class ChapterLayout {
  ChapterLayout._({
    required this.paragraphs,
    required this.totalChars,
    required this.paragraphSpacing,
    required this.topPadding,
    required this.bottomPadding,
    required List<double> textHeights,
    required List<double> tops,
    required this.contentExtent,
  })  : _textHeights = textHeights,
        _tops = tops;

  /// 量出一章的版面。
  ///
  /// [style] / [maxWidth] / [textScaler] / [textAlign] 必须和真正渲染那一段
  /// 用的完全一致，否则量出来的高度对不上，被 `itemExtentBuilder` 定死的行高
  /// 会把最后一行裁掉。渲染侧用的是不继承的 [TextStyle]（`inherit: false`），
  /// 就是为了保证这里不必去猜 `DefaultTextStyle` 会合并进来什么。
  factory ChapterLayout.measure({
    required List<ChapterParagraph> paragraphs,
    required int totalChars,
    required TextStyle style,
    required double maxWidth,
    required TextScaler textScaler,
    required double paragraphSpacing,
    required double topPadding,
    required double bottomPadding,
    TextAlign textAlign = TextAlign.justify,
  }) {
    final List<double> heights = <double>[];
    final List<double> tops = <double>[];
    double cursor = topPadding;
    for (final ChapterParagraph paragraph in paragraphs) {
      final double height = _measure(
        text: paragraph.text,
        style: style,
        maxWidth: math.max(1.0, maxWidth),
        textScaler: textScaler,
        textAlign: textAlign,
      );
      heights.add(height);
      tops.add(cursor);
      cursor += height + paragraphSpacing;
    }
    return ChapterLayout._(
      paragraphs: paragraphs,
      totalChars: math.max(totalChars, paragraphs.isEmpty ? 0 : paragraphs.last.end),
      paragraphSpacing: paragraphSpacing,
      topPadding: topPadding,
      bottomPadding: bottomPadding,
      textHeights: heights,
      tops: tops,
      contentExtent: cursor + bottomPadding,
    );
  }

  final List<ChapterParagraph> paragraphs;

  /// 原始正文的字符数。`char_offset` 的上界。
  final int totalChars;

  final double paragraphSpacing;
  final double topPadding;
  final double bottomPadding;

  /// 每段正文本身的高度（不含段距）。
  final List<double> _textHeights;

  /// 每段顶边在滚动坐标里的位置（含 [topPadding]）。
  final List<double> _tops;

  /// 整章内容的总高度，含上下留白。**不依赖已经建出来多少段**。
  final double contentExtent;

  int get length => paragraphs.length;

  bool get isEmpty => paragraphs.isEmpty;

  /// 交给 `itemExtentBuilder` 的那个值：正文高度 + 段距。
  ///
  /// 越界也要给一个**正数**：`SliverVariedExtentList` 在找「这个滚动位置对应
  /// 哪一段」时会往后多问几个下标，返回 0 会让它原地死循环。
  double extentOf(int index) {
    if (_textHeights.isEmpty) return 1;
    final int clamped = index.clamp(0, _textHeights.length - 1);
    return math.max(1.0, _textHeights[clamped] + paragraphSpacing);
  }

  /// 这个视口高度下滚得到的最大位置。
  double maxScrollFor(double viewportHeight) =>
      math.max(0.0, contentExtent - viewportHeight);

  /// 视口顶端那个字符在原文里的下标。
  ///
  /// 口径是「屏幕最上面显示的是第几个字」—— 恢复的时候把同一个字重新顶到
  /// 屏幕顶上，于是存 → 取是闭合的。
  int charOffsetAt(double pixels) {
    if (paragraphs.isEmpty || totalChars <= 0) return 0;
    // 还在顶部留白里，等于没开始读。
    if (pixels <= _tops.first) return 0;
    final int index = _indexAtPixels(pixels);
    final ChapterParagraph paragraph = paragraphs[index];
    final double within = pixels - _tops[index];
    final double height = _textHeights[index];
    if (within <= 0) return paragraph.start;
    // 落在段距里：这一段整个在屏幕上面了，记到段尾。
    if (within >= height || height <= 0) return math.min(paragraph.end, totalChars);
    final int offset =
        paragraph.start + (within / height * paragraph.length).round();
    return offset.clamp(0, totalChars);
  }

  /// 让 [charOffset] 这个字落在视口顶端所需要的滚动位置。
  ///
  /// 调用方自己夹到 `maxScrollExtent` —— 章末那一屏的滚动位置取决于视口多高，
  /// 这里不知道。
  double pixelsFor(int charOffset) {
    if (charOffset <= 0 || paragraphs.isEmpty) return 0;
    final int index = _indexAtChar(charOffset);
    // 超过最后一段 = 读完了，落到章尾。
    if (index < 0) return contentExtent;
    final ChapterParagraph paragraph = paragraphs[index];
    // 落在段与段之间（被 trim 掉的空白）：顶到下一段的开头。
    if (charOffset <= paragraph.start || paragraph.length <= 0) {
      return _tops[index];
    }
    final double ratio = (charOffset - paragraph.start) / paragraph.length;
    return _tops[index] + ratio * _textHeights[index];
  }

  /// 最后一个顶边不超过 [pixels] 的段。
  int _indexAtPixels(double pixels) {
    int low = 0;
    int high = _tops.length - 1;
    while (low < high) {
      final int mid = (low + high + 1) ~/ 2;
      if (_tops[mid] <= pixels) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  /// 第一个段尾超过 [charOffset] 的段。没有就回 -1。
  int _indexAtChar(int charOffset) {
    int low = 0;
    int high = paragraphs.length - 1;
    int found = -1;
    while (low <= high) {
      final int mid = (low + high) ~/ 2;
      if (paragraphs[mid].end > charOffset) {
        found = mid;
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }
    return found;
  }

  static double _measure({
    required String text,
    required TextStyle style,
    required double maxWidth,
    required TextScaler textScaler,
    required TextAlign textAlign,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: textAlign,
      textScaler: textScaler,
      textHeightBehavior: const TextHeightBehavior(),
    )..layout(maxWidth: maxWidth);
    final double height = painter.height;
    painter.dispose();
    // 向上取整：量出来的高度和渲染时差一个浮点尾数，就足以裁掉半行字。
    // 多出来的不到 1px 落进段距里，看不出来。
    return height.ceilToDouble();
  }
}
