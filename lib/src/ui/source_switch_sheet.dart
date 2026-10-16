import 'dart:async';

import 'package:flutter/material.dart';

import '../api/funread_api.dart';
import '../models/models.dart';
import '../state/source_switch_controller.dart';
import 'reader_palette.dart';

/// 换源成功之后交回给调用方的东西。
///
/// 两样都要：[candidate] 是「换到哪个源」（调用方要用它重新打 `/reader/book`），
/// [result] 是「进度落在新源的第几章、怎么定位的」。
@immutable
class SourceSwitchOutcome {
  const SourceSwitchOutcome({required this.candidate, required this.result});

  final SwitchCandidate candidate;
  final SwitchSourceResult result;
}

/// 打开换源面板。用户选中并切换成功时返回 [SourceSwitchOutcome]，
/// 取消或失败返回 `null`。
///
/// 详情页和正文页共用它。正文页要把 `saveProgressFirst` 传进来
/// （见 [SourceSwitchController]）。
Future<SourceSwitchOutcome?> showSourceSwitchSheet(
  BuildContext context, {
  required FunreadApi api,
  required String bookKey,
  required bool onShelf,
  Future<void> Function()? saveProgressFirst,
  ReaderPalette? palette,
}) {
  return showModalBottomSheet<SourceSwitchOutcome>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    // 正文页在夜间模式下弹出一张白纸是会晃眼的，跟着阅读主题走。
    backgroundColor: palette?.background,
    builder: (BuildContext context) => _SourceSwitchSheet(
      api: api,
      bookKey: bookKey,
      onShelf: onShelf,
      saveProgressFirst: saveProgressFirst,
      palette: palette,
    ),
  );
}

class _SourceSwitchSheet extends StatefulWidget {
  const _SourceSwitchSheet({
    required this.api,
    required this.bookKey,
    required this.onShelf,
    required this.saveProgressFirst,
    required this.palette,
  });

  final FunreadApi api;
  final String bookKey;
  final bool onShelf;
  final Future<void> Function()? saveProgressFirst;
  final ReaderPalette? palette;

  @override
  State<_SourceSwitchSheet> createState() => _SourceSwitchSheetState();
}

class _SourceSwitchSheetState extends State<_SourceSwitchSheet> {
  late final SourceSwitchController _controller = SourceSwitchController(
    api: widget.api,
    bookKey: widget.bookKey,
    onShelf: widget.onShelf,
    saveProgressFirst: widget.saveProgressFirst,
  );

  @override
  void initState() {
    super.initState();
    // 每次打开都重搜。这是实时聚合搜索而不是查库 —— 缓存住上一次的结果就是
    // 「源挂了之后换源列表还是那批挂掉的源」。
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color get _text =>
      widget.palette?.text ?? Theme.of(context).colorScheme.onSurface;

  Color get _muted =>
      widget.palette?.muted ?? Theme.of(context).colorScheme.onSurfaceVariant;

  Future<void> _pick(SwitchCandidate candidate) async {
    final SwitchSourceResult? result = await _controller.switchTo(candidate);
    if (!mounted) return;
    // 失败的话原因已经在 _controller.error 里，面板留在原地让用户换一个试，
    // 关掉它等于让人从头再等一次十几秒的搜索。
    if (result == null) return;
    Navigator.of(context).pop(
      SourceSwitchOutcome(candidate: candidate, result: result),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: ListenableBuilder(
        listenable: _controller,
        builder: (BuildContext context, Widget? child) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _header(context),
              if (_controller.switching) _switchingBanner(context),
              Expanded(child: _body(context)),
            ],
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String name = _controller.page?.name ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              name.isEmpty ? '换源' : '换源 · $name',
              style: theme.textTheme.titleMedium?.copyWith(color: _text),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: '重新搜索',
            color: _text,
            onPressed: _controller.loading || _controller.switching
                ? null
                : () => unawaited(_controller.load()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  /// 提交之后那段等待。它同样会抓一次新源的目录，所以也可能要几十秒。
  Widget _switchingBanner(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(
            '正在切换，并把进度重新定位到新源的目录里 —— 这一步要再抓一次目录。',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_controller.loading) return _pending(context);
    final String? error = _controller.error;
    // 不在书架那条也走这里，但它不是「失败」而是前置条件，所以不给「重试」。
    if (error != null) {
      return _message(
        context,
        icon: widget.onShelf
            ? Icons.error_outline
            : Icons.bookmark_add_outlined,
        title: widget.onShelf ? '换源列表取不到' : '这本书还不在书架里',
        detail: error,
        action: widget.onShelf
            ? OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: _text),
                onPressed: () => unawaited(_controller.load()),
                child: const Text('重试'),
              )
            : null,
      );
    }
    final SwitchSourcePage? page = _controller.page;
    if (page == null) return const SizedBox.shrink();
    if (page.items.isEmpty) {
      return _message(
        context,
        icon: Icons.search_off,
        title: '没有找到其它来源',
        detail: page.explainEmpty(),
        action: OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: _text),
          onPressed: () => unawaited(_controller.load()),
          child: const Text('再搜一次'),
        ),
      );
    }
    return _list(context, page);
  }

  /// 等待态。
  ///
  /// 必须报时：这是一次实时聚合搜索，服务端的墙钟预算就是 25 秒，一个不动的
  /// 转圈和「卡死了」在屏幕上没有区别。
  Widget _pending(BuildContext context) {
    final int seconds = _controller.elapsed.inSeconds;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              seconds > 0 ? '正在跨源搜索…已等 $seconds 秒' : '正在跨源搜索…',
              style: TextStyle(color: _text),
            ),
            const SizedBox(height: 8),
            Text(
              '换源列表不是本地缓存，而是一次实时搜索：要逐批去试候选源，'
              '十几秒是正常的，服务端最多搜 25 秒就会收工。',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _message(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String detail,
    Widget? action,
  }) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 36, color: _muted),
            const SizedBox(height: 12),
            Text(title, style: TextStyle(color: _text)),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, fontSize: 12),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: 12),
              action,
            ],
          ],
        ),
      ),
    );
  }

  /// 候选列表。
  ///
  /// `exact` 的排前面（后端已经这么排了），但近似匹配**一条都不过滤**，
  /// 只是单独分一组并说明差异从哪来 —— 见 [SwitchCandidate.exact]。
  Widget _list(BuildContext context, SwitchSourcePage page) {
    final List<SwitchCandidate> exact = page.exactItems;
    final List<SwitchCandidate> loose = page.looseItems;
    return AbsorbPointer(
      // 提交期间别让人再点第二个源：两次换源打架的结果是书架记录和界面对不上。
      absorbing: _controller.switching,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              page.stats.summaryLine(),
              style: TextStyle(color: _muted, fontSize: 12),
            ),
          ),
          if (exact.isNotEmpty) ...<Widget>[
            _groupTitle('书名和作者都对得上（${exact.length} 个）'),
            for (final SwitchCandidate item in exact) _row(context, item),
          ],
          if (loose.isNotEmpty) ...<Widget>[
            _groupTitle(
              '书名相同、作者写法不同的源（${loose.length} 个）。'
              '作者名的差异通常只是源站的录入习惯，而这些源往往恰恰还活着；'
              '但也可能是另一本同名书，选之前看一眼。',
            ),
            for (final SwitchCandidate item in loose) _row(context, item),
          ],
        ],
      ),
    );
  }

  Widget _groupTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(text, style: TextStyle(color: _muted, fontSize: 12)),
    );
  }

  Widget _row(BuildContext context, SwitchCandidate item) {
    final ThemeData theme = Theme.of(context);
    final List<String> meta = <String>[
      item.author.isEmpty ? '作者留空' : item.author,
      if (item.lastChapter.isNotEmpty) '最新：${item.lastChapter}',
    ];
    return ListTile(
      dense: true,
      leading: Icon(
        item.current ? Icons.check_circle : Icons.rss_feed,
        size: 18,
        color: item.current ? theme.colorScheme.primary : _muted,
      ),
      title: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              item.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _text),
            ),
          ),
          if (item.current) ...<Widget>[
            const SizedBox(width: 6),
            Text(
              '当前',
              style: TextStyle(color: theme.colorScheme.primary, fontSize: 11),
            ),
          ],
        ],
      ),
      subtitle: Text(
        meta.join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: _muted, fontSize: 12),
      ),
      trailing: Icon(Icons.chevron_right, size: 18, color: _muted),
      onTap: () => unawaited(_pick(item)),
    );
  }
}
