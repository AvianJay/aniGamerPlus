import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../util/device.dart';

/// 設定用一維清單: 上下依項目順序走, 不讓捲動區或 Switch 搶方向鍵.
class TvSettingsList extends StatefulWidget {
  const TvSettingsList({super.key, required this.child});

  final Widget child;

  @override
  State<TvSettingsList> createState() => _TvSettingsListState();
}

class _TvSettingsListState extends State<TvSettingsList> {
  final _scope =
      FocusScopeNode(traversalEdgeBehavior: TraversalEdgeBehavior.stop);

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Device.tv) return widget.child;
    return FocusScope(
      node: _scope,
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: widget.child,
      ),
    );
  }
}

class TvSettingsTile extends StatefulWidget {
  const TvSettingsTile({
    super.key,
    required this.label,
    required this.onActivate,
    required this.child,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onActivate;
  final Widget child;
  final bool autofocus;

  @override
  State<TvSettingsTile> createState() => _TvSettingsTileState();
}

class _TvSettingsTileState extends State<TvSettingsTile> {
  late final _focus = FocusNode(debugLabel: 'settings-${widget.label}');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _focusChanged(bool focused) {
    setState(() {});
    if (!focused) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focus.hasFocus) return;
      unawaited(Scrollable.ensureVisible(context, alignment: 0.5));
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      node.nextFocus();
    } else if (key == LogicalKeyboardKey.arrowUp) {
      node.previousFocus();
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      // 清單只有一欄; 左右不離開選單也不調整底下的播放進度.
    } else if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (event is! KeyRepeatEvent) widget.onActivate();
    } else if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack) {
      if (event is! KeyRepeatEvent) unawaited(Navigator.of(context).maybePop());
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (!Device.tv) return widget.child;
    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onFocusChange: _focusChanged,
      onKeyEvent: _onKey,
      child: Material(
        color:
            _focus.hasFocus ? Theme.of(context).focusColor : Colors.transparent,
        shape: RoundedRectangleBorder(
          side: BorderSide(
            color: _focus.hasFocus ? AgpColors.focusRing : Colors.transparent,
            width: 3,
          ),
        ),
        child: ExcludeFocus(child: widget.child),
      ),
    );
  }
}
