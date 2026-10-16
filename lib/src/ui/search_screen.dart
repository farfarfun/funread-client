import 'dart:async';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/models.dart';
import '../state/auth_controller.dart';
import '../state/book_search_controller.dart';
import 'book_cover.dart';
import 'book_sheet.dart';

/// 搜索页：整条阅读链路的入口。
///
/// 点一条结果先弹详情面板（一本书往往有好几个源），在面板里选一个源才进详情页。
/// 不替用户挑源：哪个源真能读出正文，要到目录 / 正文那一步才知道，
/// 自动选第一个就等于把「这个源挂了」说成「这本书读不了」。
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _keyword = TextEditingController();
  BookSearchController? _search;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _search ??= BookSearchController(AppScope.of(context).api);
  }

  @override
  void dispose() {
    _keyword.dispose();
    _search?.dispose();
    super.dispose();
  }

  void _onSearchPressed() {
    final BookSearchController? search = _search;
    if (search == null) return;
    unawaited(search.search(_keyword.text));
  }

  void _onLogoutPressed() {
    unawaited(AppScope.of(context).auth.logout());
  }

  @override
  Widget build(BuildContext context) {
    final AuthController auth = AppScope.of(context).auth;
    final BookSearchController search = _search!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索'),
        actions: <Widget>[
          ListenableBuilder(
            listenable: auth,
            builder: (BuildContext context, Widget? child) => Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  auth.session.displayName,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '退出登录',
            onPressed: _onLogoutPressed,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _keyword,
              textInputAction: TextInputAction.search,
              onSubmitted: (String value) => _onSearchPressed(),
              decoration: InputDecoration(
                hintText: '书名或作者',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: '搜索',
                  onPressed: _onSearchPressed,
                  icon: const Icon(Icons.arrow_forward),
                ),
              ),
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: search,
              builder: (BuildContext context, Widget? child) =>
                  _SearchBody(search: search),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchBody extends StatelessWidget {
  const _SearchBody({required this.search});

  final BookSearchController search;

  @override
  Widget build(BuildContext context) {
    if (search.loading) return const _Searching();
    final String? error = search.error;
    if (error != null) return _Message(icon: Icons.error_outline, text: error);
    final SearchPage? page = search.page;
    if (page == null) {
      return const _Message(
        icon: Icons.menu_book_outlined,
        text: '输入书名或作者开始搜索。\n一次搜索会实时扇出到几十个书源，请耐心等几秒。',
      );
    }
    if (page.items.isEmpty) {
      return _Message(
        icon: Icons.search_off,
        text: '没有结果。\n\n${page.stats.explainEmpty()}',
      );
    }
    return Column(
      children: <Widget>[
        Expanded(
          child: ListView.separated(
            itemCount: page.items.length,
            separatorBuilder: (BuildContext context, int index) =>
                const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) =>
                _BookTile(book: page.items[index]),
          ),
        ),
        _StatsBar(stats: page.stats),
      ],
    );
  }
}

class _Searching extends StatelessWidget {
  const _Searching();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('正在向多个书源并发查询…'),
          SizedBox(height: 4),
          Text(
            '书源池里能跑通的只有个位数百分比，十几秒是正常的',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: Theme.of(context).disabledColor),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// 结果列表底部那行统计。
///
/// 它不是装饰：没有它，「这本书没有」和「这轮试的源全挂了」在界面上
/// 完全一样，而后者才是常态。用户看到「试了 24 个源、2 个答了」才知道
/// 该再搜一次，而不是以为客户端坏了。
class _StatsBar extends StatelessWidget {
  const _StatsBar({required this.stats});

  final SearchStats stats;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          stats.summaryLine(),
          style: theme.textTheme.bodySmall,
        ),
      ),
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({required this.book});

  final SearchBook book;

  @override
  Widget build(BuildContext context) {
    final List<String> meta = <String>[
      if (book.author.isNotEmpty) book.author,
      if (book.kind.isNotEmpty) book.kind,
      if (book.wordCount.isNotEmpty) book.wordCount,
    ];
    return ListTile(
      leading: BookCover(url: book.coverUrl),
      title: Text(book.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (meta.isNotEmpty)
            Text(
              meta.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (book.lastChapter.isNotEmpty)
            Text(
              '最新：${book.lastChapter}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
      isThreeLine: meta.isNotEmpty && book.lastChapter.isNotEmpty,
      trailing: Chip(
        label: Text('${book.sources.length} 源'),
        visualDensity: VisualDensity.compact,
      ),
      onTap: () => showBookSheet(context, book),
    );
  }
}
