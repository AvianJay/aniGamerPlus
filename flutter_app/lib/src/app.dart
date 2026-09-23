import 'package:flutter/material.dart';

import 'pages/root_page.dart';
import 'pages/setup_page.dart';
import 'pages/update_dialog.dart';
import 'state/app_state.dart';
import 'theme.dart';

class AgpApp extends StatefulWidget {
  const AgpApp({super.key, required this.state});

  final AppState state;

  @override
  State<AgpApp> createState() => _AgpAppState();
}

class _AgpAppState extends State<AgpApp> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // 先把畫面畫出來再連線, 伺服器沒開的時候才不會卡在白畫面
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.state.hasServer) {
        widget.state.refreshAll();
      } else {
        widget.state.finishBoot();
      }
      _checkForUpdates();
    });
  }

  /// 開 App 時靜靜地看一眼有沒有新版; 對話框要掛在 MaterialApp 底下的 context 上
  Future<void> _checkForUpdates() async {
    if (!widget.state.prefs.updateAutoCheck) return;
    // 讓首頁先把片庫拉起來, 別一開 App 就被對話框擋住
    await Future<void>.delayed(const Duration(seconds: 2));
    final context = _navigator.currentState?.overlay?.context;
    if (context == null || !context.mounted) return;
    await checkForUpdates(context, widget.state.prefs, silent: true);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        return MaterialApp(
          navigatorKey: _navigator,
          title: 'aniGamerPlus',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(brightness: Brightness.light),
          darkTheme: buildTheme(brightness: Brightness.dark),
          themeMode: widget.state.themeMode,
          home: widget.state.hasServer
              ? RootPage(state: widget.state)
              : SetupPage(state: widget.state),
        );
      },
    );
  }
}
