/// 把手機送來的按鍵、文字「按」進電視上的畫面.
///
/// 按鍵走的路跟實體遙控器一模一樣: 從拿著焦點的那一個開始, 一路往上問每一層的
/// onKeyEvent, 有人處理就停 (FocusManager 收到真的按鍵時也是這樣走的). 所以
/// 預設的方向鍵移動、確認鍵按下, 還有播放頁自己攔的左右跳轉, 都不必另外接.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/tv_remote_protocol.dart';

class RemoteKeys {
  RemoteKeys._();

  static const Map<RemoteKey, (LogicalKeyboardKey, PhysicalKeyboardKey)> _keys =
      {
    RemoteKey.up: (LogicalKeyboardKey.arrowUp, PhysicalKeyboardKey.arrowUp),
    RemoteKey.down: (
      LogicalKeyboardKey.arrowDown,
      PhysicalKeyboardKey.arrowDown
    ),
    RemoteKey.left: (
      LogicalKeyboardKey.arrowLeft,
      PhysicalKeyboardKey.arrowLeft
    ),
    RemoteKey.right: (
      LogicalKeyboardKey.arrowRight,
      PhysicalKeyboardKey.arrowRight
    ),
    // 遙控器中間那顆 (DPAD_CENTER) 在 Flutter 裡就是 select
    RemoteKey.ok: (LogicalKeyboardKey.select, PhysicalKeyboardKey.select),
    RemoteKey.playPause: (
      LogicalKeyboardKey.mediaPlayPause,
      PhysicalKeyboardKey.mediaPlayPause
    ),
    RemoteKey.fastForward: (
      LogicalKeyboardKey.mediaFastForward,
      PhysicalKeyboardKey.mediaFastForward
    ),
    RemoteKey.rewind: (
      LogicalKeyboardKey.mediaRewind,
      PhysicalKeyboardKey.mediaRewind
    ),
    RemoteKey.next: (
      LogicalKeyboardKey.mediaTrackNext,
      PhysicalKeyboardKey.mediaTrackNext
    ),
    RemoteKey.previous: (
      LogicalKeyboardKey.mediaTrackPrevious,
      PhysicalKeyboardKey.mediaTrackPrevious
    ),
  };

  /// 按一下 (按下 + 放開). 返回鍵、首頁不是按鍵事件, 由呼叫的人自己處理.
  /// 回傳有沒有人接.
  static bool press(RemoteKey key) {
    final pair = _keys[key];
    if (pair == null) return false;
    final (logical, physical) = pair;
    final handled = _dispatch(KeyDownEvent(
        logicalKey: logical, physicalKey: physical, timeStamp: _now()));
    _dispatch(KeyUpEvent(
        logicalKey: logical, physicalKey: physical, timeStamp: _now()));
    return handled;
  }

  static Duration _now() =>
      Duration(microseconds: DateTime.now().microsecondsSinceEpoch);

  static bool _dispatch(KeyEvent event) {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return false;
    for (final node in [primary, ...primary.ancestors]) {
      final handler = node.onKeyEvent;
      if (handler == null) continue;
      switch (handler(node, event)) {
        case KeyEventResult.handled:
          return true;
        case KeyEventResult.skipRemainingHandlers:
          return false;
        case KeyEventResult.ignored:
          continue;
      }
    }
    return false;
  }

  /// 電視上現在有輸入框拿著焦點的話, 換成 [text] (跟在那個框裡打字一樣會觸發
  /// onChanged), [submit] 的話再按一下鍵盤上的完成. 沒有輸入框就回 false.
  static bool type(String text, {bool submit = false}) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    final editable =
        context is StatefulElement && context.state is EditableTextState
            ? context.state as EditableTextState
            : context.findAncestorStateOfType<EditableTextState>();
    if (editable == null || editable.widget.readOnly) return false;
    editable.userUpdateTextEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
      SelectionChangedCause.keyboard,
    );
    if (submit) {
      editable.performAction(
          editable.widget.textInputAction ?? TextInputAction.done);
    }
    return true;
  }
}
