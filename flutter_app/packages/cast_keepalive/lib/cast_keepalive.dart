/// 投放中 App 退到背景時, 別讓 iOS 把它暫停.
///
/// iOS 會把退到背景、又沒有在出聲的 App 整個停下來: Dart 不跑了, 跟 Chromecast
/// 的連線也斷了 —— 電視播完那一集就停在那裡, 不會接下一集, 進度也不會記.
/// 本機播放器的聲音本來就讓 App 留著 (UIBackgroundModes 的 audio), 投放時手機
/// 自己沒有聲音, 所以借一段靜音撐著, 跟別的 App 的聲音混著放, 不會打斷它們.
///
/// Android 不需要: 投放中 Cast SDK 自己的媒體通知就是一個前景服務.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class CastKeepAlive {
  CastKeepAlive._();

  static const MethodChannel _channel = MethodChannel('agp/cast_keepalive');

  /// 只有 iOS 需要. 測試裡可以直接改.
  static bool supported = !kIsWeb && Platform.isIOS;

  /// 開 / 關. 重複叫同一個值沒有關係.
  static Future<void> hold(bool on) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('hold', on);
    } catch (_) {
      // 撐不住就是回到原本的樣子: 退到背景後 iOS 照常把 App 暫停
    }
  }
}
