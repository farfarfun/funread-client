import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/reader_settings_controller.dart';
import 'reader_palette.dart';

/// 排版设置面板。从正文页的「Aa」拉起来。
///
/// 三个滑块 + 一行主题。刻意**不做实时预览窗**：面板只占屏幕下半截，
/// 上半截就是真正的正文，拖滑块时它当场重排 —— 这比任何预览都准。
class ReaderSettingsSheet extends StatelessWidget {
  const ReaderSettingsSheet({required this.controller, super.key});

  final ReaderSettingsController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? child) {
        final ReaderSettings value = controller.value;
        final ReaderPalette palette = ReaderPalette.of(value.theme);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            // 可滚：小屏 + 大号系统字体下这几行会超过弹层的高度上限，
            // 溢出的表现是一条黄黑警示带，而不是「挤一挤」。
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _themeRow(context, value, palette),
                const SizedBox(height: 8),
                _slider(
                  palette: palette,
                  label: '字号',
                  value: value.fontSize,
                  min: ReaderSettings.minFontSize,
                  max: ReaderSettings.maxFontSize,
                  // 一格一像素。半像素的字号没有意义，还会让滑块手感发虚。
                  divisions:
                      (ReaderSettings.maxFontSize - ReaderSettings.minFontSize)
                          .round(),
                  display: value.fontSize.round().toString(),
                  onChanged: (double next) =>
                      controller.update(value.copyWith(fontSize: next)),
                ),
                _slider(
                  palette: palette,
                  label: '行距',
                  value: value.lineHeight,
                  min: ReaderSettings.minLineHeight,
                  max: ReaderSettings.maxLineHeight,
                  divisions: 12,
                  display: value.lineHeight.toStringAsFixed(1),
                  onChanged: (double next) =>
                      controller.update(value.copyWith(lineHeight: next)),
                ),
                _slider(
                  palette: palette,
                  label: '页边距',
                  value: value.pageMargin,
                  min: ReaderSettings.minPageMargin,
                  max: ReaderSettings.maxPageMargin,
                  divisions: 10,
                  display: value.pageMargin.round().toString(),
                  onChanged: (double next) =>
                      controller.update(value.copyWith(pageMargin: next)),
                ),
                Text(
                  '排版只存在这台设备上，不会同步 —— 手机和桌面的合适字号本来就不一样。',
                  style: TextStyle(color: palette.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _themeRow(
    BuildContext context,
    ReaderSettings value,
    ReaderPalette palette,
  ) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 56,
          child: Text('主题', style: TextStyle(color: palette.text)),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<ReaderThemeId>(
              showSelectedIcon: false,
              segments: <ButtonSegment<ReaderThemeId>>[
                for (final ReaderThemeId id in ReaderThemeId.values)
                  ButtonSegment<ReaderThemeId>(value: id, label: Text(id.label)),
              ],
              selected: <ReaderThemeId>{value.theme},
              // 切主题是一次性动作，直接落盘；滑块那种连续的才等松手。
              onSelectionChanged: (Set<ReaderThemeId> picked) => unawaited(
                controller.commit(value.copyWith(theme: picked.first)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _slider({
    required ReaderPalette palette,
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 56,
          child: Text(label, style: TextStyle(color: palette.text)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            onChanged: onChanged,
            // 拖的过程中只改内存（正文跟着重排），松手才写偏好。
            // 不这么分的话一次拖动要写几十遍。
            onChangeEnd: (double _) => unawaited(controller.persist()),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            display,
            textAlign: TextAlign.end,
            style: TextStyle(color: palette.muted, fontSize: 12),
          ),
        ),
      ],
    );
  }
}
