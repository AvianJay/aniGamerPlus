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

  /// 給手機遙控用的名字: 配對時電視上顯示「誰」想連進來, 手機上列出「哪一台」.
  /// Android 用系統設定裡的裝置名稱 (電視多半是「客廳電視」這種), 沒有就用型號.
  static String name = Platform.isIOS ? 'iPhone' : 'Android 手機';

  /// 問的是 MainActivity 裡那一支 (tool/prepare_platforms.sh 補上的):
  /// UiModeManager 說是電視, 或是有 leanback 這個系統功能.
  static const MethodChannel _channel = MethodChannel('agp/device');

  /// 交給電視系統處理, 保留藍牙與 HDMI 音訊裝置的音量路由.
  static Future<bool> adjustVolume(String command) async {
    if (!const {'volumeUp', 'volumeDown', 'mute'}.contains(command)) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('adjustVolume', command) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> detect() async {
    if (!Platform.isAndroid) return;
    try {
      tv = await _channel.invokeMethod<bool>('isTelevision') ?? false;
    } catch (_) {
      // 舊的平台外殼沒有這支通道: 當成手機, 至少不會更糟
      tv = false;
    }
    try {
      final named = await _channel.invokeMethod<String>('deviceName');
      if (named != null && named.trim().isNotEmpty) name = named.trim();
    } catch (_) {
      if (tv) name = 'Android TV';
    }
  }

  /// Wi-Fi 在省電時會把不是寄給自己的封包 (廣播也算) 濾掉. 電視開著等手機來找
  /// 的時候要拿著這把鎖, 不然手機的廣播收不到.
  static Future<void> holdMulticastLock(bool hold) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('multicastLock', hold);
    } catch (_) {
      // 沒有這支通道就只剩掃描跟手動輸入, 一樣找得到
    }
  }
}
