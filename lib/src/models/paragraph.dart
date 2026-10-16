/// 正文里的一段，连同它在**原始正文**里的起始字符下标。
///
/// 为什么要记 [start]：进度存的是原始正文里的字符偏移（`char_offset`，
/// 后端和 funread-web 都按这个口径），而屏幕上显示的是 trim 过、按空行切开的
/// 段落。没有这个下标，字符和像素之间就只能靠「字符在章内均匀分布」按整章比例
/// 硬算 —— 对话多的章节里，一段两个字和一段三百字交替出现，那个假设直接崩掉，
/// 表现是「续读跳到了差好几屏的地方」。
class ChapterParagraph {
  const ChapterParagraph({required this.text, required this.start});

  /// 去掉首尾空白之后的段落正文。显示的就是它。
  final String text;

  /// 在原始正文里的起始下标。
  final int start;

  int get length => text.length;

  /// 段尾的下一个字符（不含）。
  int get end => start + text.length;
}

/// 按空行切段，并记住每段在原文里的位置。
///
/// 源站给的正文是纯文本，段落之间可能是一个 `\n` 也可能是连续多个，
/// 统一成「非空行即一段」。被 trim 掉的空白和被 split 吃掉的换行都要照样计进
/// 偏移里，否则从第二段起每一段的 [ChapterParagraph.start] 都是错的。
List<ChapterParagraph> splitParagraphs(String text) {
  if (text.isEmpty) return const <ChapterParagraph>[];
  final List<ChapterParagraph> items = <ChapterParagraph>[];
  int cursor = 0;
  for (final String line in text.split('\n')) {
    final String trimmed = line.trim();
    if (trimmed.isNotEmpty) {
      final int lead = line.length - line.trimLeft().length;
      items.add(ChapterParagraph(text: trimmed, start: cursor + lead));
    }
    // +1 是被 split 吃掉的那个 `\n`。
    cursor += line.length + 1;
  }
  return items;
}
