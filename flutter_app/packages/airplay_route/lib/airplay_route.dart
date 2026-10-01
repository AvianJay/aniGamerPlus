/// iOS 的 AirPlay: 系統按鈕, 跟「現在是不是在 AirPlay 上」.
///
/// 選裝置的面板只有系統畫得出來, 所以 [AirPlayButton] 是一個原生的
/// AVRoutePickerView. 其他平台什麼都不畫, [AirPlay.routes] 也不會有事件.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 目前的輸出.
@immutable
class AirPlayRoute {
  const AirPlayRoute({required this.active, this.name = ''});

  static const AirPlayRoute none = AirPlayRoute(active: false);

  /// 聲音 (跟影片) 正送往一台 AirPlay 裝置
  final bool active;

  /// 裝置名稱, 例如「客廳」. 系統沒給就是空字串.
  final String name;

  factory AirPlayRoute.fromMap(Object? raw) {
    if (raw is! Map) return none;
    return AirPlayRoute(
      active: raw['active'] == true,
      name: raw['name']?.toString() ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AirPlayRoute && other.active == active && other.name == name;

  @override
  int get hashCode => Object.hash(active, name);
}

class AirPlay {
  AirPlay._();

  static const EventChannel _events = EventChannel('agp/airplay/route');
  static const MethodChannel _methods = MethodChannel('agp/airplay');

  /// 只有 iOS 有 AirPlay 按鈕可以放. 測試裡可以直接改.
  static bool supported = !kIsWeb && Platform.isIOS;

  /// 路由一變就送一次; 一訂閱就先送現在的狀態.
  static Stream<AirPlayRoute> routes() {
    if (!supported) return const Stream<AirPlayRoute>.empty();
    return _events
        .receiveBroadcastStream()
        .map(AirPlayRoute.fromMap)
        .handleError((Object _) {});
  }

  static Future<AirPlayRoute> current() async {
    if (!supported) return AirPlayRoute.none;
    try {
      return AirPlayRoute.fromMap(await _methods.invokeMethod<Object>('route'));
    } catch (_) {
      return AirPlayRoute.none;
    }
  }
}

/// 系統的 AirPlay 按鈕. 點下去是系統自己的裝置清單.
class AirPlayButton extends StatelessWidget {
  const AirPlayButton({
    super.key,
    this.size = 48,
    this.color = const Color(0xFFFFFFFF),
    this.activeColor = const Color(0xFF00B4D8),
  });

  final double size;
  final Color color;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    if (!AirPlay.supported) return const SizedBox.shrink();
    return SizedBox(
      width: size,
      height: size,
      child: UiKitView(
        viewType: 'agp/airplay-button',
        creationParams: <String, Object>{
          'tint': color.toARGB32(),
          'activeTint': activeColor.toARGB32(),
        },
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );
  }
}
