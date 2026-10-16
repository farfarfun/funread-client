import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:funread_client/src/app_scope.dart';
import 'package:funread_client/src/models/models.dart';
import 'package:funread_client/src/state/auth_controller.dart';
import 'package:funread_client/src/ui/book_detail_screen.dart';

import 'support/backend.dart';

/// 长章节的构建方式与恢复精度。
///
/// 这一组盯着三件事，全都是「换成 `ListView.builder` 」带来的：
///  1. 真的是懒构建吗（几百段只建出屏幕上那几段）；
///  2. 滚动范围**不随滚动而变**（懒构建默认是估的，一边滚一边变，
///     而进度换算架在它上面）；
///  3. 续读落点准不准 —— 恢复到某一段，那一段就该在屏幕最上面。
void main() {
  const int paragraphCount = 200;

  /// 每段都带一个唯一前缀，`find.text` 才能精确定位到某一段。
  String paragraphAt(int index) => 'P$index${'文' * 60}';

  final String chapterText =
      List<String>.generate(paragraphCount, paragraphAt).join('\n\n');

  /// 第 [index] 段在原文里的起始字符下标。进度存的就是这个口径。
  int charOffsetOfParagraph(int index) {
    int offset = 0;
    for (int i = 0; i < index; i++) {
      offset += paragraphAt(i).length + 2; // +2 = 段间的两个换行
    }
    return offset;
  }

  const BookRef ref = BookRef(
    bookKey: FakeBackend.bookKey,
    urlId: 7,
    bookUrl: 'http://src.test/b/1',
    name: '书名',
    author: '作者',
  );

  Future<void> drain(WidgetTester tester) async {
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Widget wrap(FakeBackend backend) {
    final AppServices services = AppServices(
      api: backend.api,
      auth: AuthController(api: backend.api),
    );
    addTearDown(services.dispose);
    return AppScope(
      services: services,
      child: const MaterialApp(home: BookDetailScreen(ref: ref)),
    );
  }

  /// 走到正文页：详情 → 「续读」。
  Future<void> openReader(WidgetTester tester, FakeBackend backend) async {
    await tester.pumpWidget(wrap(backend));
    await drain(tester);
    await tester.tap(find.textContaining('续读'));
    await drain(tester);
  }

  Finder bodyParagraphs() => find.byWidgetPredicate(
        (Widget widget) => widget is Text && (widget.data?.startsWith('P') ?? false),
      );

  /// 正文那条滚动轴。按 ListView 往下找，免得摸到压在下面那一页的滚动轴。
  ScrollableState scroller(WidgetTester tester) => tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );

  testWidgets('两百段的章节只建出屏幕上那十几段', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend(text: chapterText);

    await openReader(tester, backend);

    final int built = bodyParagraphs().evaluate().length;
    expect(built, greaterThan(0));
    // 原来的 SingleChildScrollView + Column 会把 200 段全建出来。
    // 这里只该有屏幕上那些加上 cacheExtent 里的几段。
    expect(built, lessThan(40), reason: '建出来 $built 段，没在懒构建');
  });

  testWidgets('滚动范围不随着滚动变 —— 进度换算就架在这个值上', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend(text: chapterText);

    await openReader(tester, backend);

    final double before = scroller(tester).position.maxScrollExtent;
    expect(before, greaterThan(0));

    // 往下滚过几屏。懒构建默认按「已经建出来的那几段」估总高度，
    // 估值会随着你滚一直变；量过一遍之后它是个定值。
    for (int i = 0; i < 5; i++) {
      scroller(tester).position.jumpTo(
            (scroller(tester).position.pixels + 1200)
                .clamp(0.0, scroller(tester).position.maxScrollExtent),
          );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(scroller(tester).position.maxScrollExtent, closeTo(before, 0.001));
  });

  testWidgets('续读落在存进度时的那一段上，而且那一段在屏幕最上面', (WidgetTester tester) async {
    const int target = 40;
    final FakeBackend backend = FakeBackend(text: chapterText);
    // 「上次读到第 40 段」。进度里存的是章内字符偏移，不是像素。
    backend.progressCharOffset = charOffsetOfParagraph(target);

    await openReader(tester, backend);

    final Finder paragraph = find.text(paragraphAt(target));
    expect(paragraph, findsOneWidget);
    expect(
      tester.getTopLeft(paragraph).dy,
      closeTo(tester.getTopLeft(find.byType(ListView)).dy, 1),
      reason: '恢复出来的位置和存进去的字符偏移对不上',
    );
  });

  testWidgets('定死的行高要装得下文字本身，否则最后一行会被裁掉', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend(text: chapterText);

    await openReader(tester, backend);

    // `itemExtentBuilder` 用的是 TextPainter 量出来的高度，而真正渲染的是
    // RenderParagraph。两者只要有一点点出入，被定死高度的那一段就会少半行。
    // 这里拿每段的实际盒子高度和它在同样宽度下的自然高度比。
    for (final Element element in bodyParagraphs().evaluate()) {
      final RenderBox box = element.renderObject! as RenderBox;
      final double natural = box.getMaxIntrinsicHeight(box.size.width);
      expect(
        box.size.height,
        greaterThanOrEqualTo(natural - 0.5),
        reason: '量出来的行高比文字自然高度矮，正文会被裁',
      );
    }
  });
}
