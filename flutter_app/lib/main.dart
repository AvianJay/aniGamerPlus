import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app.dart';
import 'src/state/app_state.dart';
import 'src/util/device.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Device.detect();
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
