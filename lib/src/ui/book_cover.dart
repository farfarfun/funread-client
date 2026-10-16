import 'package:flutter/material.dart';

/// 封面图。
///
/// **errorBuilder 是必需的，不是防御性编程。** 大量源的封面地址会 404、要
/// Referer、或者干脆是 http 混在 https 页面里被浏览器拦掉。没有它，搜索结果
/// 和详情页上会出现一片红色的异常块；加载失败退化成一个图标，不影响读书。
class BookCover extends StatelessWidget {
  const BookCover({
    required this.url,
    this.width = 40,
    this.height = 56,
    super.key,
  });

  final String url;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return _placeholder(context);
    return SizedBox(
      width: width,
      height: height,
      child: Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
            _placeholder(context),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: width,
      height: height,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.book_outlined,
        size: width * 0.5,
        color: theme.disabledColor,
      ),
    );
  }
}
