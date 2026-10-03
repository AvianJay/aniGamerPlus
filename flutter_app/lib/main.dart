import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';

import 'src/app.dart';
import 'src/state/app_state.dart';
import 'src/util/device.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterCryptography.enable();
  await Device.detect();
  // 電視沒有手指, 從第一下按鍵起就一直是「用按鍵操作」: 焦點框一開始就要畫
  if (Device.tv) {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  }
  // 電視只有橫的; 要它直立的話 Android 會把整個畫面縮成中間一條
  if (!Device.tv) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }
  final state = await AppState.boot();
  runApp(AgpApp(state: state));
}
