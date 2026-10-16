import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import 'book_detail_screen.dart';

/// 搜索结果的详情面板，同时也是**选源**的地方。
void showBookSheet(BuildContext context, SearchBook book) {
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => _BookSheet(book: book),
    ),
  );
}

class _BookSheet extends StatelessWidget {
  const _BookSheet({required this.book});

  final SearchBook book;

  /// 选定一个源：先关面板再进详情页。
  ///
  /// 两件事都走同一个 Navigator（模态底部面板不另起导航器），所以要先把
  /// NavigatorState 取出来再 pop —— pop 之后这个 context 就失效了。
  void _open(BuildContext context, SourceRef source) {
    final NavigatorState navigator = Navigator.of(context);
    navigator.pop();
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              BookDetailScreen(ref: BookRef.fromSearch(book, source)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(book.name, style: theme.textTheme.titleLarge),
              if (book.author.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(book.author, style: theme.textTheme.bodyMedium),
              ],
              if (book.lastChapter.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text('最新章节：${book.lastChapter}',
                    style: theme.textTheme.bodySmall),
              ],
              if (book.intro.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(book.intro, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 16),
              Text('选一个源打开（${book.sources.length}）',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                '哪个源能真的读出目录和正文，要点进去才知道 —— 这一个读不出来就回来换下一个。',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              // 全列出来，不做任何筛选或排序暗示。
              ...book.sources.map(
                (SourceRef ref) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.rss_feed, size: 18),
                  title: Text(
                    ref.sourceName.isEmpty ? '源 #${ref.urlId}' : ref.sourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    ref.bookUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => _open(context, ref),
                ),
              ),
              if (book.sources.isEmpty)
                Text(
                  '这条结果没有带任何源，打不开。再搜一次通常会换一批源。',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
