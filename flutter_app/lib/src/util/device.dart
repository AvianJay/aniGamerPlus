/// 這支 App 跑在哪一種裝置上. 目前只分「電視」跟「其他」.
///
/// 電視沒有觸控, 只有遙控器的方向鍵跟確認鍵; 播放器要一開就全螢幕, 設定伺服器
/// 也得改成拿手機掃碼 —— 用遙控器一格一格敲網址太折磨人.
library;

import 'dart:io';

import 'package:flutter/services.dart';

class Device {
  Device._();

  /// 在 main() 裡、runApp 之前問一次, 之後整支 App 同步讀.
  /// 測試裡可以直接改.
  static bool tv = false;

  /// 問的是 MainActivity 裡那一支 (tool/prepare_platforms.sh 補上的):
  /// UiModeManager 說是電視, 或是有 leanback 這個系統功能.
  static const MethodChannel _channel = MethodChannel('agp/device');

  static Future<void> detect() async {
    if (!Platform.isAndroid) return;
    try {
      tv = await _channel.invokeMethod<bool>('isTelevision') ?? false;
    } catch (_) {
      // 舊的平台外殼沒有這支通道: 當成手機, 至少不會更糟
      tv = false;
    }
  }
}
