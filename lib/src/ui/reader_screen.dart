import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../models/models.dart';
import '../state/reader_controller.dart';
import '../state/reader_settings_controller.dart';
import 'chapter_layout.dart';
import 'reader_palette.dart';
import 'reader_settings_sheet.dart';

/// 正文阅读页。滚动式，字号 / 行距 / 页边距 / 主题可调。
///
/// **不做分页排版（模拟翻书）。** 分页要先把渲染后的文本高度测出来再回切，
/// 一旦字号可调就得反复重排；而滚动在触屏上本来就是原生手感，
/// 在桌面上还能用滚轮和键盘。funread-web 也是同一个选择。
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

  /// 当前这一版正文的测量结果，以及它对应的排版参数。
  ChapterLayout? _layout;
  _LayoutKey? _layoutKey;

  /// 最近一次换算出来的字符偏移。重排（转屏 / 改字号）之后靠它重新锚定 ——
  /// 像素值在新版面里没有意义，字符偏移有。
  int _lastCharOffset = 0;

  /// 排版设置。是 [AppScope] 上的长生命周期对象，这里只借用，不负责销毁。
  ReaderSettingsController? _settings;

  /// 正文和设置任何一个变了都要重建。合成一个存着而不是每次 build 现合 ——
  /// 现合的话 `ListenableBuilder` 每一帧都要退订再订阅一遍。
  Listenable? _repaint;

  /// 上下留白不可调：它们是给刘海和手势条让的位置，不是审美。
  static const double _topPadding = 16;
  static const double _bottomPadding = 48;

  /// 一行最多排多少个字（按字号折算宽度）。
  ///
  /// 桌面上窗口有多宽正文就排多宽是不能读的 —— 一行七八十个汉字，
  /// 眼睛跳回行首就找不到下一行。这个上限之外的空间留成两侧留白。
  static const double _maxLineChars = 36;

  /// 边缘翻章的触控带宽度（屏宽占比）。
  static const double _edgeRatio = 0.25;

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
    final ReaderSettingsController settings = AppScope.of(context).readerSettings;
    _reader = reader;
    _settings = settings;
    _repaint = Listenable.merge(<Listenable>[reader, settings]);
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
        // 上一次没问成（那会儿正开着目录或设置面板）就补问一次：
        // 冲突没回答之前进度是停写的，不补问就一直停在那儿。
        _askAboutProgress();
        unawaited(reader.checkRemoteProgress());
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _onScroll() {
    final ReaderController? reader = _reader;
    final ChapterLayout? layout = _layout;
    if (reader == null || layout == null || !_scroll.hasClients) return;
    // 「视口顶端是第几个字」。不是按整章比例估的 —— 比例法假设字符在章内
    // 均匀分布，而对话多的章节里一段两个字、一段三百字是常态。
    _lastCharOffset = layout.charOffsetAt(_scroll.position.pixels);
    reader.onOffsetChanged(_lastCharOffset);
  }

  void _onReaderChanged() {
    final ReaderController reader = _reader!;
    if (reader.conflict != null) {
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
    if (_asking || reader == null || !mounted) return;
    final ProgressConflict? conflict = reader.conflict;
    if (conflict == null) return;
    // 这一页被自己的面板压在下面时不弹：对话框会盖在面板上，
    // 用户根本不知道它在问什么。回前台时会补问（见
    // [didChangeAppLifecycleState]）。
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    _asking = true;
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
    if (reader == null) return;
    _jumpToChar(reader.restoreOffset);
  }

  /// 把第 [charOffset] 个字顶到视口顶端。
  void _jumpToChar(int charOffset) {
    final ChapterLayout? layout = _layout;
    if (layout == null || !mounted || !_scroll.hasClients) return;
    final double max = _scroll.position.maxScrollExtent;
    _scroll.jumpTo(layout.pixelsFor(charOffset).clamp(0.0, max));
    _lastCharOffset = charOffset;
  }

  Future<void> _go(Future<void> Function() move) async {
    final ReaderController reader = _reader!;
    final int before = reader.position;
    await move();
    // 位置没变就别动滚动条：第一章点「上一章」、最后一章点「下一章」（以及
    // 边缘手势误触）都会走到这里，把人弹回章首不是「没反应」，
    // 是把他读到哪给弄丢了。
    if (!mounted || !_scroll.hasClients || reader.position == before) return;
    // 新章从头开始。恢复逻辑会在正文到了之后再把位置摆正（翻章时是 0）。
    _scroll.jumpTo(0);
  }

  void _openToc() {
    final ReaderController reader = _reader!;
    final ReaderPalette palette = ReaderPalette.of(_settings!.value.theme);
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: palette.background,
        builder: (BuildContext context) => _TocSheet(
          chapters: reader.chapters,
          current: reader.position,
          palette: palette,
          onPick: (int position) {
            Navigator.of(context).pop();
            unawaited(_go(() => reader.goTo(position)));
          },
        ),
      ),
    );
  }

  /// 排版设置面板。
  void _openSettings() {
    final ReaderSettingsController settings = _settings!;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        // 面板用当前阅读主题的底色：夜间模式下弹出一张白纸是会晃眼的。
        backgroundColor: ReaderPalette.of(settings.value.theme).background,
        builder: (BuildContext context) =>
            ReaderSettingsSheet(controller: settings),
      ),
    );
  }

  /// 点屏幕左右两条边翻章。**只在触屏上**。
  ///
  /// 桌面上左右各 25% 是一条几百像素宽的死区（2560 的屏一侧就是 640），
  /// 而且鼠标用户会把点击理解成选中文字 —— 想复制一句话结果跳了一章。
  /// 桌面靠方向键和底部那两个按钮，funread-web 在这件事上踩过坑。
  bool _edgeTapEnabled(BuildContext context) {
    switch (Theme.of(context).platform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return true;
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return false;
    }
  }

  void _onTapUp(TapUpDetails details, double width) {
    final ReaderController reader = _reader!;
    final double x = details.localPosition.dx;
    if (x < width * _edgeRatio) {
      unawaited(_go(reader.prev));
      return;
    }
    if (x > width * (1 - _edgeRatio)) {
      unawaited(_go(reader.next));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ReaderController reader = _reader!;
    final ReaderSettingsController settings = _settings!;
    return ListenableBuilder(
      listenable: _repaint!,
      builder: (BuildContext context, Widget? child) {
        final Chapter? chapter = reader.current;
        final ChapterContent? content = reader.content;
        final ReaderSettings style = settings.value;
        final ReaderPalette palette = ReaderPalette.of(style.theme);
        // 标题优先用正文页抓到的那个：目录里的章节名常常带着源站自己的前后缀。
        final String title = content != null && content.title.isNotEmpty
            ? content.title
            : (chapter?.name ?? widget.info.name);
        return CallbackShortcuts(
          // 桌面上这是**主要**翻章方式：那里没有边缘手势。
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                unawaited(_go(reader.prev)),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                unawaited(_go(reader.next)),
            // 上下 / PageUp / PageDown 不拦：滚动式阅读里浏览器和
            // Scrollable 自己的默认行为就是对的。
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: palette.background,
              appBar: AppBar(
                backgroundColor: palette.background,
                foregroundColor: palette.text,
                // 不要 M3 的 scrolledUnder 着色：正文滚到标题栏下面时
                // 染一层主题色，和阅读底色就对不上了。
                scrolledUnderElevation: 0,
                title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                actions: <Widget>[
                  IconButton(
                    tooltip: '排版',
                    onPressed: _openSettings,
                    icon: const Icon(Icons.text_fields),
                  ),
                  IconButton(
                    tooltip: '目录',
                    onPressed: reader.chapters.isEmpty ? null : _openToc,
                    icon: const Icon(Icons.list),
                  ),
                ],
              ),
              body: _body(context, reader, style, palette),
              bottomNavigationBar: _pager(context, reader, palette),
            ),
          ),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    ReaderController reader,
    ReaderSettings settings,
    ReaderPalette palette,
  ) {
    // 提示文字也要跟着阅读主题走：夜间底色配默认的深色字就是「深底深字」。
    if (reader.loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('正在抓取正文…', style: TextStyle(color: palette.muted)),
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
              Icon(Icons.error_outline, size: 36, color: palette.muted),
              const SizedBox(height: 12),
              Text('读不到这一章', style: TextStyle(color: palette.text)),
              const SizedBox(height: 8),
              Text(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: palette.text),
                onPressed: () => unawaited(reader.load()),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final List<ChapterParagraph> paragraphs = reader.paragraphs;
    if (paragraphs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          // 空正文不报错是后端的常态：规则没匹配到就是空串。说清楚，
          // 否则用户以为是客户端没渲染出来。
          child: Text(
            '这一章是空的。\n\n多半是这个源的正文规则没匹配上，而不是章节本身没有内容。'
            '返回详情页换一个源通常能读到。',
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.muted),
          ),
        ),
      );
    }

    return _chapterText(context, paragraphs, settings, palette);
  }

  /// 正文本体。
  ///
  /// `ListView.builder` 而不是 `SingleChildScrollView` 套 `Column`：后者把几千
  /// 个段落一次性建出来，长章节上第一帧就是几百毫秒。
  ///
  /// 但光换成懒构建会把进度换算带坏 —— 没建出来的 item 没有高度，
  /// `maxScrollExtent` 只能估，而估值会随着你往下滚一直变。所以这里**先量后建**：
  /// [ChapterLayout] 把每段高度量出来喂给 `itemExtentBuilder`，
  /// 滚动范围第一帧就是准的，字符 ↔ 像素也改成逐段插值。细节见 [ChapterLayout]。
  Widget _chapterText(
    BuildContext context,
    List<ChapterParagraph> paragraphs,
    ReaderSettings settings,
    ReaderPalette palette,
  ) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextStyle style = _textStyle(settings, palette);
    final double spacing = settings.paragraphSpacing;
    final bool edgeTap = _edgeTapEnabled(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth;
        // 一行排多少字有上限，多出来的宽度摊成两侧留白。页边距是**下限**：
        // 窄屏上它说了算，宽屏上居中的那条正文列说了算。
        final double column = math.min(
          available - settings.pageMargin * 2,
          settings.fontSize * _maxLineChars,
        );
        final double side =
            math.max(settings.pageMargin, (available - column) / 2);
        final double width = math.max(1.0, available - side * 2);
        final ChapterLayout layout = _layoutFor(
          paragraphs: paragraphs,
          style: style,
          width: width,
          spacing: spacing,
          scaler: scaler,
        );
        return GestureDetector(
          // translucent：正文本身不吃点击，但整片区域都要能收到。
          behavior: HitTestBehavior.translucent,
          onTapUp:
              edgeTap ? (TapUpDetails d) => _onTapUp(d, available) : null,
          child: ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(side, _topPadding, side, _bottomPadding),
            itemCount: layout.length,
            // 这一行就是懒构建和进度精度之间的那座桥：每段高度来自实测，
            // 于是 sliver 不必建出 item 也知道整章有多高。
            itemExtentBuilder: (int index, _) => layout.extentOf(index),
            itemBuilder: (BuildContext context, int index) => Padding(
              padding: EdgeInsets.only(bottom: spacing),
              child: Text(
                layout.paragraphs[index].text,
                textAlign: TextAlign.justify,
                // 测量和渲染必须是同一套参数，差一点就会被定死的行高裁掉半行。
                textScaler: scaler,
                textHeightBehavior: const TextHeightBehavior(),
                style: style,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 正文的字体。
  ///
  /// `inherit: false` 是必须的：继承的话实际样式是 `DefaultTextStyle` 合并出来
  /// 的（字体族来自主题），而测量侧拿不到那份合并结果，量出来的高度就会和
  /// 渲染出来的对不上。不继承 = 两边输入完全一样。
  TextStyle _textStyle(ReaderSettings settings, ReaderPalette palette) {
    return TextStyle(
      inherit: false,
      // 不继承就没人给颜色了，这里要自己给。
      color: palette.text,
      fontSize: settings.fontSize,
      height: settings.lineHeight,
    );
  }

  /// 按「这一版正文 + 这套排版参数」缓存测量结果。
  ///
  /// 没有缓存的话每一帧都会把全章重量一遍 —— 那比原来的一次性构建还慢。
  ChapterLayout _layoutFor({
    required List<ChapterParagraph> paragraphs,
    required TextStyle style,
    required double width,
    required double spacing,
    required TextScaler scaler,
  }) {
    final ReaderController reader = _reader!;
    final _LayoutKey key = _LayoutKey(
      revision: reader.revision,
      width: width,
      fontSize: style.fontSize ?? ReaderSettings.defaultFontSize,
      lineHeight: style.height ?? ReaderSettings.defaultLineHeight,
      spacing: spacing,
      scaler: scaler,
    );
    final ChapterLayout? cached = _layout;
    if (cached != null && _layoutKey == key) return cached;
    final ChapterLayout layout = ChapterLayout.measure(
      paragraphs: paragraphs,
      totalChars: reader.totalChars,
      style: style,
      maxWidth: width,
      textScaler: scaler,
      paragraphSpacing: spacing,
      topPadding: _topPadding,
      bottomPadding: _bottomPadding,
    );
    // 同一版正文重排（改了字号 / 行距 / 边距，或者转了屏）：同一段文字换了个
    // 位置，把刚才读到的那个字重新顶回屏幕顶上。不然调一下字号就得重新找
    // 自己读到哪 —— 这是「设置可调」最容易让人恼火的地方。
    final bool reflow = cached != null && _layoutKey?.revision == key.revision;
    _layoutKey = key;
    _layout = layout;
    if (reflow) {
      final int anchor = _lastCharOffset;
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToChar(anchor));
    }
    return layout;
  }

  /// 底部翻章条。
  ///
  /// 桌面上它和方向键是仅有的两个翻章入口（那里没有边缘手势），
  /// 所以它常驻，不随工具栏隐藏。
  Widget _pager(
    BuildContext context,
    ReaderController reader,
    ReaderPalette palette,
  ) {
    final ButtonStyle buttonStyle = TextButton.styleFrom(
      foregroundColor: palette.text,
      disabledForegroundColor: palette.muted.withValues(alpha: 0.5),
    );
    return Material(
      color: palette.background,
      child: SafeArea(
        child: SizedBox(
          height: 48,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              TextButton(
                style: buttonStyle,
                onPressed:
                    reader.hasPrev ? () => unawaited(_go(reader.prev)) : null,
                child: const Text('上一章'),
              ),
              Text(
                '${reader.position + 1} / ${reader.chapters.length}',
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
              TextButton(
                style: buttonStyle,
                onPressed:
                    reader.hasNext ? () => unawaited(_go(reader.next)) : null,
                child: const Text('下一章'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「这份测量结果是为什么条件量的」。
///
/// 任何一项变了都得重量：正文换了（[revision]）、窗口宽了、字号或行距改了、
/// 系统字体缩放变了。少放一项进来的表现是「改完设置版面没动」，
/// 多放一项只是多量一次。
@immutable
class _LayoutKey {
  const _LayoutKey({
    required this.revision,
    required this.width,
    required this.fontSize,
    required this.lineHeight,
    required this.spacing,
    required this.scaler,
  });

  final int revision;
  final double width;
  final double fontSize;
  final double lineHeight;
  final double spacing;
  final TextScaler scaler;

  @override
  bool operator ==(Object other) {
    return other is _LayoutKey &&
        other.revision == revision &&
        other.width == width &&
        other.fontSize == fontSize &&
        other.lineHeight == lineHeight &&
        other.spacing == spacing &&
        other.scaler == scaler;
  }

  @override
  int get hashCode =>
      Object.hash(revision, width, fontSize, lineHeight, spacing, scaler);
}

/// 目录抽屉。
///
/// 打开时直接落在当前章附近 —— 几千章的书里手动翻找「我读到哪了」是没法用的。
class _TocSheet extends StatefulWidget {
  const _TocSheet({
    required this.chapters,
    required this.current,
    required this.palette,
    required this.onPick,
  });

  final List<Chapter> chapters;
  final int current;

  /// 目录也跟着阅读主题走：夜里翻目录弹出一张白纸同样晃眼。
  final ReaderPalette palette;
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
          final ReaderPalette palette = widget.palette;
          return ListTile(
            dense: true,
            leading: Text(
              '${index + 1}',
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
            title: Text(
              widget.chapters[index].name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: reading
                    ? Theme.of(context).colorScheme.primary
                    : palette.text,
              ),
            ),
            trailing: reading
                ? Icon(Icons.play_arrow,
                    size: 16, color: Theme.of(context).colorScheme.primary)
                : null,
            onTap: () => widget.onPick(index),
          );
        },
      ),
    );
  }
}
