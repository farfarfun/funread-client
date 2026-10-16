import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/models.dart';
import '../state/reader_controller.dart';

/// 正文阅读页。
///
/// 这一版是**可滚动的纯文本**，刻意不做分页排版、字号行距设置、夜间模式和
/// 翻页手势。分页要先测量渲染后的文本高度，一旦字号可调就得反复重排，
/// 那是另一个量级的工作量；先把「搜索 → 详情 → 目录 → 正文 → 进度」整条链
/// 跑通，排版单独做。
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    required this.bookRef,
    required this.info,
    required this.chapters,
    required this.position,
    this.charOffset = 0,
    this.onShelf = false,
    super.key,
  });

  final BookRef bookRef;

  /// 详情页取回来的那一份，原样带着 `variables` 往下传。
  final BookInfo info;
  final List<Chapter> chapters;

  /// 目录里的下标（不是 `Chapter.index`）。
  final int position;

  /// 章内字符偏移。只有「续读」时才非零。
  final int charOffset;
  final bool onShelf;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  final ScrollController _scroll = ScrollController();
  ReaderController? _reader;

  /// 已经为哪一版正文恢复过滚动位置。防止每次 notify 都重新跳一遍 ——
  /// 那会把用户自己滚到的位置拽回去。
  int _restoredRevision = 0;

  /// 进度冲突的弹窗已经在屏幕上了。没有它的话，弹窗期间的任何一次 notify
  /// 都会再叠一个一模一样的对话框上去。
  bool _asking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reader != null) return;
    final ReaderController reader = ReaderController(
      api: AppScope.of(context).api,
      ref: widget.bookRef,
      info: widget.info,
      chapters: widget.chapters,
      position: widget.position,
      charOffset: widget.charOffset,
      onShelf: widget.onShelf,
    );
    _reader = reader;
    reader.addListener(_onReaderChanged);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
    unawaited(reader.load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    _reader?.removeListener(_onReaderChanged);
    // 控制器的 dispose 里会补写最后一次进度，所以顺序上要在 scroll 之后 ——
    // 它读的是已经记下来的 pendingOffset，不再碰 ScrollController。
    _reader?.dispose();
    super.dispose();
  }

  /// 前后台切换。
  ///
  /// `paused` 补一次写：手机上「切走就再也不回来」是常态，进程被系统回收时
  /// `dispose` 不一定跑得到，只靠它会丢掉最后那一段。
  ///
  /// `resumed` 问一次服务端有没有更新的进度 —— 这一页可能已经在后台停了几天，
  /// 期间别的设备一直在读。**只问不跳**，见
  /// [ReaderController.checkRemoteProgress]。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final ReaderController? reader = _reader;
    if (reader == null) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(reader.flush());
      case AppLifecycleState.resumed:
        unawaited(reader.checkRemoteProgress());
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _onScroll() {
    final ReaderController? reader = _reader;
    if (reader == null || !_scroll.hasClients) return;
    reader.onOffsetChanged(
      ReadingPosition.offsetOf(
        pixels: _scroll.position.pixels,
        maxExtent: _scroll.position.maxScrollExtent,
        totalChars: reader.totalChars,
      ),
    );
  }

  void _onReaderChanged() {
    final ReaderController reader = _reader!;
    if (reader.conflict != null && !_asking) {
      _asking = true;
      // 不在 notify 的同步路径里弹窗：这一下可能正发生在 build 过程中。
      WidgetsBinding.instance.addPostFrameCallback((_) => _askAboutProgress());
    }
    if (reader.revision == _restoredRevision) return;
    _restoredRevision = reader.revision;
    // 正文刚进 state，还没布局，此刻 maxScrollExtent 是 0。等这一帧画完再跳。
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreOffset());
  }

  /// 弹「别处读到了新进度」。
  ///
  /// 两个选项，**没有默认动作**：点叉、按返回键都算「留在这里」。
  /// 这是故意的 —— 悄悄跳走比不跳糟糕得多，而「留在这里」最坏的后果只是
  /// 下一次回写把远端的位置覆盖掉，那本来就是用户选的。
  void _askAboutProgress() {
    final ReaderController? reader = _reader;
    if (reader == null || !mounted) {
      _asking = false;
      return;
    }
    final ProgressConflict? conflict = reader.conflict;
    // 这一页被别的页面压在下面时不弹：对话框会盖在那一页上，
    // 用户根本不知道它在问哪本书。下次回前台会再问。
    if (conflict == null || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      _asking = false;
      return;
    }
    unawaited(_showProgressDialog(reader, conflict));
  }

  Future<void> _showProgressDialog(
    ReaderController reader,
    ProgressConflict conflict,
  ) async {
    final bool? jump = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('别处读到了新进度'),
        content: Text(
          '另一台设备读到「${conflict.chapterName}」'
          '（第 ${conflict.position + 1} 章），'
          '这一页停在第 ${conflict.localPosition + 1} 章。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('留在这里'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('跳过去'),
          ),
        ],
      ),
    );
    _asking = false;
    if (!mounted) return;
    if (jump ?? false) {
      await _go(reader.acceptRemoteProgress);
      return;
    }
    reader.keepLocalProgress();
  }

  void _restoreOffset() {
    final ReaderController? reader = _reader;
    if (reader == null || !mounted || !_scroll.hasClients) return;
    final double max = _scroll.position.maxScrollExtent;
    final double target = ReadingPosition.pixelsOf(
      charOffset: reader.restoreOffset,
      totalChars: reader.totalChars,
      maxExtent: max,
    );
    _scroll.jumpTo(target > max ? max : target);
  }

  Future<void> _go(Future<void> Function() move) async {
    await move();
    if (!mounted || !_scroll.hasClients) return;
    // 新章从头开始。恢复逻辑会在正文到了之后再把位置摆正（翻章时是 0）。
    _scroll.jumpTo(0);
  }

  void _openToc() {
    final ReaderController reader = _reader!;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (BuildContext context) => _TocSheet(
          chapters: reader.chapters,
          current: reader.position,
          onPick: (int position) {
            Navigator.of(context).pop();
            unawaited(_go(() => reader.goTo(position)));
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ReaderController reader = _reader!;
    return ListenableBuilder(
      listenable: reader,
      builder: (BuildContext context, Widget? child) {
        final Chapter? chapter = reader.current;
        final ChapterContent? content = reader.content;
        // 标题优先用正文页抓到的那个：目录里的章节名常常带着源站自己的前后缀。
        final String title = content != null && content.title.isNotEmpty
            ? content.title
            : (chapter?.name ?? widget.info.name);
        return Scaffold(
          appBar: AppBar(
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: <Widget>[
              IconButton(
                tooltip: '目录',
                onPressed: reader.chapters.isEmpty ? null : _openToc,
                icon: const Icon(Icons.list),
              ),
            ],
          ),
          body: _body(context, reader),
          bottomNavigationBar: _pager(context, reader),
        );
      },
    );
  }

  Widget _body(BuildContext context, ReaderController reader) {
    if (reader.loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在抓取正文…'),
          ],
        ),
      );
    }
    final String? error = reader.error;
    if (error != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline,
                  size: 36, color: Theme.of(context).disabledColor),
              const SizedBox(height: 12),
              const Text('读不到这一章'),
              const SizedBox(height: 8),
              Text(
                error,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => unawaited(reader.load()),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final List<String> paragraphs = reader.paragraphs;
    if (paragraphs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          // 空正文不报错是后端的常态：规则没匹配到就是空串。说清楚，
          // 否则用户以为是客户端没渲染出来。
          child: Text(
            '这一章是空的。\n\n多半是这个源的正文规则没匹配上，而不是章节本身没有内容。'
            '返回详情页换一个源通常能读到。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final String line in paragraphs)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                line,
                textAlign: TextAlign.justify,
                style: const TextStyle(fontSize: 17, height: 1.7),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pager(BuildContext context, ReaderController reader) {
    return SafeArea(
      child: SizedBox(
        height: 48,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            TextButton(
              onPressed: reader.hasPrev ? () => unawaited(_go(reader.prev)) : null,
              child: const Text('上一章'),
            ),
            Text(
              '${reader.position + 1} / ${reader.chapters.length}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextButton(
              onPressed: reader.hasNext ? () => unawaited(_go(reader.next)) : null,
              child: const Text('下一章'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 目录抽屉。
///
/// 打开时直接落在当前章附近 —— 几千章的书里手动翻找「我读到哪了」是没法用的。
class _TocSheet extends StatefulWidget {
  const _TocSheet({
    required this.chapters,
    required this.current,
    required this.onPick,
  });

  final List<Chapter> chapters;
  final int current;
  final ValueChanged<int> onPick;

  @override
  State<_TocSheet> createState() => _TocSheetState();
}

class _TocSheetState extends State<_TocSheet> {
  /// 固定行高，所以初始位置能直接算出来，不必等布局完再 scrollTo。
  static const double _itemExtent = 48;

  late final ScrollController _scroll = ScrollController(
    // 当前章摆在可视区域靠上的位置。没必要精确居中，差几行不影响
    // 「一眼找到自己在哪」。
    initialScrollOffset: math.max(0.0, (widget.current - 2) * _itemExtent),
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: ListView.builder(
        controller: _scroll,
        itemExtent: _itemExtent,
        itemCount: widget.chapters.length,
        itemBuilder: (BuildContext context, int index) {
          final bool reading = index == widget.current;
          return ListTile(
            dense: true,
            leading:
                Text('${index + 1}', style: Theme.of(context).textTheme.bodySmall),
            title: Text(
              widget.chapters[index].name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: reading
                  ? TextStyle(color: Theme.of(context).colorScheme.primary)
                  : null,
            ),
            trailing: reading ? const Icon(Icons.play_arrow, size: 16) : null,
            onTap: () => widget.onPick(index),
          );
        },
      ),
    );
  }
}
