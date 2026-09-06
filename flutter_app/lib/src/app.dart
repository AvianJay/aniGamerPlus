import 'package:flutter/material.dart';

import 'pages/root_page.dart';
import 'pages/setup_page.dart';
import 'state/app_state.dart';
import 'theme.dart';

class AgpApp extends StatefulWidget {
  const AgpApp({super.key, required this.state});

  final AppState state;

  @override
  State<AgpApp> createState() => _AgpAppState();
}

class _AgpAppState extends State<AgpApp> {
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
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        return MaterialApp(
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
