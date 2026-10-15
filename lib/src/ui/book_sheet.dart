import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';

/// 搜索结果的详情面板。
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
              Text('可用书源（${book.sources.length}）',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              // 同一本书在多个源下都有。哪个能真的读出来，要到目录和正文
              // 那一步才知道 —— 所以这里全列出来，不做任何筛选或排序暗示。
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
                ),
              ),
              const SizedBox(height: 12),
              const _NextPhaseNotice(),
            ],
          ),
        ),
      ),
    );
  }
}

/// 阅读器还没做，这里把边界说清楚，而不是给一个点下去没反应的按钮。
class _NextPhaseNotice extends StatelessWidget {
  const _NextPhaseNotice();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '阅读器（详情 / 目录 / 正文 / 换源 / 进度）在下一阶段实现。\n'
        '这一版只验证搜索链路和接口契约。',
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}
