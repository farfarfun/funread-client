import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:funread_client/src/models/models.dart';
import 'package:funread_client/src/ui/chapter_layout.dart';

/// 字符偏移 ↔ 滚动位置的换算精度。
///
/// 这一组钉的是改造里最容易出错的那件事：正文换成懒构建之后，
/// `maxScrollExtent` 变成了「按已经建出来的那几段估的」，会随着你往下滚一直
/// 变。原来的换算（已读字符 / 总字符 × 可滚高度）两头都架在这个值上，
/// 于是恢复点会漂。[ChapterLayout] 的做法是先把每段量出来，
/// 换算改成逐段插值 —— 下面这些断言就是那个口径的定义。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 不继承的样式：和正文渲染时用的是同一份，测量才有意义。
  const TextStyle style = TextStyle(inherit: false, fontSize: 20, height: 1.5);
  const double width = 200;
  const double spacing = 16;
  const double top = 16;
  const double bottom = 40;

  ChapterLayout layoutOf(String text) {
    final List<ChapterParagraph> paragraphs = splitParagraphs(text);
    return ChapterLayout.measure(
      paragraphs: paragraphs,
      totalChars: text.length,
      style: style,
      maxWidth: width,
      textScaler: TextScaler.noScaling,
      paragraphSpacing: spacing,
      topPadding: top,
      bottomPadding: bottom,
    );
  }

  String para(String seed, int times) => List<String>.filled(times, seed).join();

  group('切段', () {
    test('每段记住自己在原文里的起点，空行和缩进都照样计数', () {
      const String text = '第一段。\n\n  第二段。\n第三段。';
      final List<ChapterParagraph> items = splitParagraphs(text);

      expect(items.map((ChapterParagraph p) => p.text).toList(),
          <String>['第一段。', '第二段。', '第三段。']);
      expect(items[0].start, 0);
      // 「第一段。」4 字 + 句号 = 5 个字符，再加两个换行，再加两个空格缩进。
      expect(items[1].start, text.indexOf('第二段。'));
      expect(items[2].start, text.indexOf('第三段。'));
      expect(items.last.end, text.length);
    });

    test('空正文不是一段空的，是零段', () {
      expect(splitParagraphs(''), isEmpty);
      expect(splitParagraphs('\n\n\n'), isEmpty);
    });
  });

  group('测量', () {
    test('总高度只由测量结果决定，和「建出来几段」无关', () {
      final ChapterLayout layout = layoutOf(
        List<String>.generate(30, (int i) => para('字$i', 40)).join('\n\n'),
      );

      double sum = top + bottom;
      for (int i = 0; i < layout.length; i++) {
        sum += layout.extentOf(i);
      }
      expect(layout.contentExtent, closeTo(sum, 0.001));
      // 再量一次得到同一个数：这正是 itemExtentBuilder 能说真话的前提。
      expect(layout.contentExtent, layoutOf(
        List<String>.generate(30, (int i) => para('字$i', 40)).join('\n\n'),
      ).contentExtent);
    });

    test('越界的下标也要给正数行高，否则 sliver 会原地死循环', () {
      final ChapterLayout layout = layoutOf('一段。');
      expect(layout.extentOf(-1), greaterThan(0));
      expect(layout.extentOf(999), greaterThan(0));
    });

    test('一屏装得下的短章节，可滚高度是 0', () {
      final ChapterLayout layout = layoutOf('短。');
      expect(layout.maxScrollFor(800), 0);
    });
  });

  group('字符偏移 ↔ 像素', () {
    test('存了再取回来还是同一个字', () {
      final ChapterLayout layout = layoutOf(
        List<String>.generate(12, (int i) => para('第$i段', 25)).join('\n\n'),
      );

      for (final ChapterParagraph paragraph in layout.paragraphs) {
        for (final int offset in <int>[
          paragraph.start,
          paragraph.start + paragraph.length ~/ 3,
          paragraph.end - 1,
        ]) {
          final double pixels = layout.pixelsFor(offset);
          // 容差 1 个字符：段内按行高插值，落点本来就只精确到行。
          expect(
            layout.charOffsetAt(pixels),
            closeTo(offset, 1),
            reason: '偏移 $offset 换算成 $pixels 之后没回到原处',
          );
        }
      }
    });

    test('一串对话后面跟一长段：比例法会差出十几行，逐段插值不会', () {
      // 对话多的章节就长这样：二十行「四个字」，然后一大段叙述。
      // 四个字的一段照样占满一行 —— 每个字摊到的高度是长段里的十倍，
      // 「字符在章内均匀分布」这个假设就是在这里崩的。
      final List<String> lines = <String>[
        for (int i = 0; i < 20; i++) '「嗯。」',
        para('很长的一段叙述。', 50),
      ];
      final String text = lines.join('\n\n');
      final ChapterLayout layout = layoutOf(text);
      final ChapterParagraph tail = layout.paragraphs.last;

      // 长段的顶边 = 上面二十段的高度之和 + 顶部留白。
      double expected = top;
      for (int i = 0; i < layout.length - 1; i++) {
        expected += layout.extentOf(i);
      }
      expect(layout.pixelsFor(tail.start), closeTo(expected, 0.001));

      // 同一个偏移用比例法算出来的位置。差了几百像素，也就是十几行 ——
      // 「续读跳到了完全不相干的地方」就是这么来的。
      final double naive =
          tail.start / layout.totalChars * layout.contentExtent;
      expect(naive, lessThan(expected * 0.7));
      expect(layout.charOffsetAt(layout.pixelsFor(tail.start)),
          closeTo(tail.start, 1));
    });

    test('偏移单调不减', () {
      final ChapterLayout layout = layoutOf(
        List<String>.generate(8, (int i) => para('段$i', 30)).join('\n\n'),
      );
      double previous = -1;
      for (int offset = 0; offset < layout.totalChars; offset += 7) {
        final double pixels = layout.pixelsFor(offset);
        expect(pixels, greaterThanOrEqualTo(previous));
        previous = pixels;
      }
    });

    test('没读过（0）落在最顶上，读完了（≥ 总字数）落到章尾', () {
      final ChapterLayout layout = layoutOf(
        List<String>.generate(5, (int i) => para('段$i', 20)).join('\n\n'),
      );
      expect(layout.pixelsFor(0), 0);
      expect(layout.pixelsFor(-10), 0);
      expect(layout.pixelsFor(layout.totalChars + 999), layout.contentExtent);
      expect(layout.charOffsetAt(0), 0);
      expect(layout.charOffsetAt(-50), 0);
    });

    test('落在被 trim 掉的空白里时顶到下一段开头，不是上一段末尾', () {
      const String text = '第一段。\n\n第二段。';
      final ChapterLayout layout = layoutOf(text);
      // 两段之间的那个换行符的下标。
      final int gap = layout.paragraphs[0].end;
      expect(layout.pixelsFor(gap), layout.pixelsFor(layout.paragraphs[1].start));
    });

    test('空正文不会炸，也不会换出一个非零偏移', () {
      final ChapterLayout layout = layoutOf('');
      expect(layout.isEmpty, isTrue);
      expect(layout.charOffsetAt(500), 0);
      expect(layout.pixelsFor(500), 0);
      expect(layout.contentExtent, top + bottom);
    });

    test('字号变了，同一个偏移换出来的是不同像素 —— 这正是不存像素的理由', () {
      final List<ChapterParagraph> paragraphs =
          splitParagraphs(List<String>.generate(6, (int i) => para('段$i', 30)).join('\n\n'));
      ChapterLayout measure(double fontSize) => ChapterLayout.measure(
            paragraphs: paragraphs,
            totalChars: 1000,
            style: TextStyle(inherit: false, fontSize: fontSize, height: 1.5),
            maxWidth: width,
            textScaler: TextScaler.noScaling,
            paragraphSpacing: spacing,
            topPadding: top,
            bottomPadding: bottom,
          );

      final ChapterLayout small = measure(16);
      final ChapterLayout large = measure(28);
      final int offset = paragraphs[3].start;

      expect(large.pixelsFor(offset), greaterThan(small.pixelsFor(offset)));
      // 但两边都还认得这个字：换算是按段的，不是按像素的。
      expect(small.charOffsetAt(small.pixelsFor(offset)), closeTo(offset, 1));
      expect(large.charOffsetAt(large.pixelsFor(offset)), closeTo(offset, 1));
    });
  });
}
