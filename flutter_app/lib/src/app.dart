import 'dart:async';

import 'package:flutter/material.dart';

import 'pages/root_page.dart';
import 'pages/setup_page.dart';
import 'pages/tv_remote_actions.dart';
import 'pages/update_dialog.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'util/device.dart';

class AgpApp extends StatefulWidget {
  const AgpApp({super.key, required this.state});

  final AppState state;

  @override
  State<AgpApp> createState() => _AgpAppState();
}

/// 最外層. MaterialApp 本身只在換主題的時候重建.
///
/// 以前整個 MaterialApp 包在 AppState 的 ListenableBuilder 裡, 看起來只是
/// 「狀態變了畫面跟著變」, 實際上代價大得多: MaterialApp 一重建, Navigator
/// 就對「每一個」開著的頁面呼叫 changedExternalState(), 每一頁都從 builder
/// 整個重建 —— 正在播的那一頁、壓在底下的五個分頁、開著的作品資訊, 全部.
/// AppState 在播放中每十秒就通知一次.
///
/// 現在只有首頁那一格 (RootPage / SetupPage) 跟著 AppState 走; 疊在上面的頁面
/// 要用到 AppState 的, 各自聽.
class _AgpAppState extends State<AgpApp> {
  final _navigator = GlobalKey<NavigatorState>();
  Timer? _updateTimer;

  // 兩份主題各建一次就好. 每次都 buildTheme() 一份新的話, 內容一樣卻比不出
  // 相等, Theme 就會通知底下每一個用到它的 widget.
  final ThemeData _light =
      buildTheme(brightness: Brightness.light, tv: Device.tv);
  final ThemeData _dark =
      buildTheme(brightness: Brightness.dark, tv: Device.tv);
  late ThemeMode _themeMode = widget.state.themeMode;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    // 先把畫面畫出來再連線, 伺服器沒開的時候才不會卡在白畫面
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.state.hasServer) {
        widget.state.refreshAll();
      } else {
        widget.state.finishBoot();
      }
      // 電視: 開一台讓手機連進來遙控的伺服器
      if (Device.tv) {
        unawaited(TvRemoteService.start(widget.state, _navigator));
      }
      // 讓首頁先把片庫拉起來, 別一開 App 就被對話框擋住
      if (widget.state.prefs.updateAutoCheck) {
        _updateTimer = Timer(const Duration(seconds: 2), _checkForUpdates);
      }
    });
  }

  /// 開 App 時靜靜地看一眼有沒有新版; 對話框要掛在 MaterialApp 底下的 context 上
  Future<void> _checkForUpdates() async {
    final context = _navigator.currentState?.overlay?.context;
    if (context == null || !context.mounted) return;
    await checkForUpdates(context, widget.state.prefs, silent: true);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _updateTimer?.cancel();
    if (Device.tv) unawaited(TvRemoteService.stop());
    super.dispose();
  }

  void _onState() {
    final mode = widget.state.themeMode;
    if (mode != _themeMode) setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigator,
      title: 'aniGamerPlus',
      debugShowCheckedModeBanner: false,
      theme: _light,
      darkTheme: _dark,
      themeMode: _themeMode,
      builder: Device.tv
          ? (context, child) => FocusTraversalGroup(
                policy: ReadingOrderTraversalPolicy(
                    requestFocusCallback: _centerFocus),
                child: child!,
              )
          : null,
      home: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) => widget.state.hasServer
            ? RootPage(state: widget.state)
            : SetupPage(state: widget.state),
      ),
    );
  }
}

/// 電視上用方向鍵移到的那一格, 捲到可捲區域的正中間.
///
/// 預設是「剛好露出來就停」, 焦點永遠貼在畫面邊上, 看不到下一格是什麼, 一排
/// 卡片按到底之前都不知道還有沒有. 片單、設定清單都一樣.
void _centerFocus(
  FocusNode node, {
  ScrollPositionAlignmentPolicy? alignmentPolicy,
  double? alignment,
  Duration? duration,
  Curve? curve,
}) {
  node.requestFocus();
  final context = node.context;
  if (context == null) return;
  unawaited(Scrollable.ensureVisible(
    context,
    alignment: 0.5,
    duration: const Duration(milliseconds: 180),
    curve: Curves.easeOutCubic,
  ));
}
