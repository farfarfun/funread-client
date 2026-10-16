import 'dart:async';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/models.dart';
import '../state/book_detail_controller.dart';
import 'book_cover.dart';
import 'reader_screen.dart';

/// 书籍详情页：书名 / 作者 / 简介 / 封面 + 目录。
///
/// 用 `Navigator.push` 进来，不走路由表。`AuthGate` 那套状态驱动的互斥关系只
/// 适合「登录页 ↔ 主界面」，而详情 / 正文和搜索页是**栈**关系：读完要能回到
/// 原来那次搜索的结果上。引路由库的话这里还要把 BookRef 序列化进 URL，
/// 而对象导航正好让 `variables` 这类不该暴露给用户的字段留在内存里。
class BookDetailScreen extends StatefulWidget {
  const BookDetailScreen({required this.ref, super.key});

  final BookRef ref;

  @override
  State<BookDetailScreen> createState() => _BookDetailScreenState();
}

class _BookDetailScreenState extends State<BookDetailScreen> {
  BookDetailController? _detail;
  bool _introExpanded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_detail != null) return;
    final BookDetailController detail = BookDetailController(
      api: AppScope.of(context).api,
      ref: widget.ref,
    );
    _detail = detail;
    unawaited(detail.load());
  }

  @override
  void dispose() {
    _detail?.dispose();
    super.dispose();
  }

  void _say(String message) {
    if (message.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _onShelfPressed() {
    final BookDetailController detail = _detail!;
    return detail.onShelf ? _removeFromShelf() : _addToShelf();
  }

  Future<void> _addToShelf() async {
    final String message = await _detail!.addToShelf();
    if (!mounted) return;
    _say(message);
  }

  Future<void> _removeFromShelf() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('移出书架'),
        // 说清代价：后端删的是整条书架记录，进度跟着没了。
        content: const Text('移出书架会同时删掉阅读进度，确定吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final String message = await _detail!.removeFromShelf();
    if (!mounted) return;
    _say(message);
  }

  void _read(int position) {
    final BookDetailController detail = _detail!;
    final BookInfo? info = detail.info;
    if (info == null || detail.chapters.isEmpty) return;
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => ReaderScreen(
            // ref 取控制器上那份，不是 widget.ref —— 加入书架之后 book_key
            // 以后端返回的为准，用旧的那个存进度会写进另一本书。
            bookRef: detail.ref,
            // 详情和目录整个传过去。正文页不再重抓：那两步各自都可能失败，
            // 而且 BookInfo.variables 原样带在对象上，结构上就丢不掉。
            info: info,
            chapters: detail.chapters,
            position: position,
            // 只有落在「上次读到的那一章」才恢复章内偏移。跳到别的章节
            // 还按那个偏移滚，会落在一个和内容毫无关系的位置上。
            charOffset:
                position == detail.progressPosition ? detail.progressOffset : 0,
            onShelf: detail.onShelf,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final BookDetailController detail = _detail!;
    return ListenableBuilder(
      listenable: detail,
      builder: (BuildContext context, Widget? child) {
        final BookInfo? info = detail.info;
        final String title =
            info != null && info.name.isNotEmpty ? info.name : widget.ref.name;
        return Scaffold(
          appBar: AppBar(
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          body: _body(context, detail),
          bottomNavigationBar: info == null ? null : _dock(detail),
        );
      },
    );
  }

  Widget _body(BuildContext context, BookDetailController detail) {
    if (detail.loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在向源站取详情…'),
          ],
        ),
      );
    }
    final String? error = detail.error;
    if (error != null) {
      return Center(
        child: SingleChildScrollView(
          child: _Failure(
            title: '打不开这本书',
            detail: error,
            onRetry: () => unawaited(detail.load()),
          ),
        ),
      );
    }
    final BookInfo? info = detail.info;
    if (info == null) return const SizedBox.shrink();

    final String? tocError = detail.tocError;
    // 目录可能有几千章，必须按需构建 —— 一次性建完会在长书上卡住首帧。
    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(child: _header(context, detail, info)),
        SliverToBoxAdapter(child: _tocHeader(context, detail)),
        if (detail.tocLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (tocError != null)
          SliverToBoxAdapter(
            child: _Failure(
              title: '目录读不出来',
              detail: tocError,
              onRetry: () => unawaited(detail.loadToc()),
            ),
          )
        else
          SliverList.builder(
            itemCount: detail.chapters.length,
            itemBuilder: (BuildContext context, int index) {
              final Chapter chapter = detail.chapters[index];
              final bool reading = index == detail.progressPosition;
              return ListTile(
                dense: true,
                title: Text(
                  chapter.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: reading
                      ? TextStyle(color: Theme.of(context).colorScheme.primary)
                      : null,
                ),
                leading: Text('${index + 1}',
                    style: Theme.of(context).textTheme.bodySmall),
                trailing: reading ? const Icon(Icons.bookmark, size: 16) : null,
                onTap: () => _read(index),
              );
            },
          ),
      ],
    );
  }

  Widget _header(BuildContext context, BookDetailController detail, BookInfo info) {
    final ThemeData theme = Theme.of(context);
    final List<String> tags = <String>[
      if (info.kind.isNotEmpty) info.kind,
      if (info.wordCount.isNotEmpty) info.wordCount,
    ];
    final String source = info.sourceName.isEmpty
        ? '源 #${detail.ref.urlId}'
        : info.sourceName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              BookCover(url: info.coverUrl, width: 84, height: 116),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      info.name.isEmpty ? widget.ref.name : info.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      info.author.isEmpty ? '未知作者' : info.author,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (tags.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(tags.join(' · '), style: theme.textTheme.bodySmall),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      '来源：$source',
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (info.lastChapter.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              '最新：${info.lastChapter}',
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (info.intro.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              info.intro,
              style: theme.textTheme.bodyMedium,
              maxLines: _introExpanded ? null : 3,
              overflow: _introExpanded ? null : TextOverflow.ellipsis,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => _introExpanded = !_introExpanded),
                child: Text(_introExpanded ? '收起' : '展开'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _tocHeader(BuildContext context, BookDetailController detail) {
    final ThemeData theme = Theme.of(context);
    final String count =
        detail.chapters.isEmpty ? '' : '（共 ${detail.chapters.length} 章）';
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text('目录$count', style: theme.textTheme.titleSmall),
      ),
    );
  }

  /// 底部操作栏：不管滚到目录哪一行都能直接开始读。
  Widget _dock(BookDetailController detail) {
    final int resume = detail.progressPosition;
    final bool canRead = detail.chapters.isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: <Widget>[
            TextButton(
              onPressed:
                  detail.shelfBusy ? null : () => unawaited(_onShelfPressed()),
              child: Text(detail.onShelf ? '移出书架' : '加入书架'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: canRead ? () => _read(resume < 0 ? 0 : resume) : null,
                child: Text(resume < 0 ? '开始阅读' : '续读第 ${resume + 1} 章'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 失败态。
///
/// 一定要把后端那句 `detail` 原样显示出来：源站超时、规则没匹配到、书源被禁用
/// 是三件事，只说「加载失败」的话用户只能重试到放弃。
class _Failure extends StatelessWidget {
  const _Failure({
    required this.title,
    required this.detail,
    required this.onRetry,
  });

  final String title;
  final String detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.error_outline, size: 36, color: theme.disabledColor),
          const SizedBox(height: 12),
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          const SizedBox(height: 4),
          Text(
            '一直失败就返回换一个源 —— 同一本书在不同源下的存活率差很多。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
