import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'src/video_player_controller.dart';
import 'video_player_pip_platform_interface.dart';

/// A Flutter plugin that adds Picture-in-Picture (PiP) functionality to the video_player package.
///
/// This plugin provides methods to enter and exit PiP mode, check if PiP is supported
/// on the current device, and monitor PiP state changes.
class VideoPlayerPip {
  static const MethodChannel _channel = MethodChannel('video_player_pip');

  static VideoPlayerPipPlatform get _platform => VideoPlayerPipPlatform.instance;

  /// 只有手機有系統的子母畫面. 測試裡可以直接改.
  static bool supported = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Checks if the device supports PiP mode
  ///
  /// Returns `true` if PiP is supported, otherwise `false`.
  ///
  /// For Android, this requires API level 26 (Android 8.0) or higher.
  /// For iOS, this requires iOS 14.0 or higher.
  static Future<bool> isPipSupported() {
    return _platform.isPipSupported();
  }

  /// Enters Picture-in-Picture mode for the given video player controller.
  ///
  /// Returns a [Future] that completes with `true` if PiP mode was entered successfully,
  /// or `false` otherwise.
  ///
  /// Optional parameters:
  /// - [width]: Desired width of the PiP window (in pixels)
  /// - [height]: Desired height of the PiP window (in pixels)
  ///
  /// Note: The controller must be initialized and should preferably be using
  /// [VideoViewType.platformView] for PiP to work correctly.
  ///
  /// Example:
  /// ```dart
  /// final controller = VideoPlayerController.network(
  ///   'https://example.com/video.mp4',
  ///   videoViewType: VideoViewType.platformView,
  /// );
  /// await controller.initialize();
  /// await VideoPlayerPip.enterPipMode(controller, width: 300, height: 200);
  /// ```
  static Future<bool> enterPipMode(
    VideoPlayerController controller, {
    int? width,
    int? height,
  }) {
    // ignore: invalid_use_of_visible_for_testing_member
    if (controller.textureId == VideoPlayerController.kUninitializedTextureId) {
      debugPrint(
        'VideoPlayerPip: Cannot enter PiP mode with uninitialized controller',
      );
      return Future.value(false);
    }

    // iOS implementation uses native PiP
    return _platform.enterPipMode(
      // ignore: invalid_use_of_visible_for_testing_member
      controller.textureId,
      width: width,
      height: height,
    );
  }

  /// Exits Picture-in-Picture mode if currently active.
  ///
  /// Returns `true` if PiP mode was exited successfully, or `false` otherwise.
  static Future<bool> exitPipMode() {
    return _platform.exitPipMode();
  }

  /// Checks if the app is currently in PiP mode.
  ///
  /// Returns `true` if in PiP mode, or `false` otherwise.
  static Future<bool> isInPipMode() {
    if (!supported) return Future.value(false);
    return _platform.isInPipMode();
  }

  /// 子母畫面的設定, 見 [VideoPlayerPipPlatform.updatePip].
  ///
  /// [autoEnter] 為 true 時, 使用者回到桌面 (Android 的 Home / 最近使用,
  /// iOS 往上滑) 系統會自動把 [playerId] 那一個播放器收進子母畫面.
  /// [playing] 決定 Android 子母畫面視窗裡畫播放鍵還是暫停鍵.
  static Future<bool> updatePip({
    int? playerId,
    required bool autoEnter,
    required bool playing,
    int? width,
    int? height,
    Rect? sourceRect,
  }) {
    if (!supported) return Future.value(false);
    return _platform.updatePip(
      playerId: playerId,
      autoEnter: autoEnter,
      playing: playing,
      width: width,
      height: height,
      sourceRect: sourceRect,
    );
  }

  /// Stream of PiP mode state changes.
  ///
  /// You can listen to this stream to be notified when the app enters or exits PiP mode.
  /// The stream emits `true` when entering PiP mode and `false` when exiting PiP mode.
  ///
  /// Example:
  /// ```dart
  /// VideoPlayerPip.instance.onPipModeChanged.listen((isInPipMode) {
  ///   print('Is in PiP mode: $isInPipMode');
  /// });
  /// ```
  Stream<bool> get onPipModeChanged {
    return _onPipModeChangedController.stream;
  }

  /// Android 子母畫面視窗裡按下的按鈕: `play`、`pause`、`rewind`、`forward`.
  ///
  /// iOS 的子母畫面用的是系統自己的按鈕, 直接操作播放器, 不會送到這裡.
  Stream<String> get onPipAction {
    return _onPipActionController.stream;
  }

  /// Toggles Picture-in-Picture mode.
  ///
  /// If currently in PiP mode, it will exit. If not in PiP mode, it will
  /// enter PiP mode with the provided controller.
  ///
  /// Optional parameters:
  /// - [width]: Desired width of the PiP window (in pixels)
  /// - [height]: Desired height of the PiP window (in pixels)
  ///
  /// Returns `true` if the operation was successful, or `false` otherwise.
  Future<bool> togglePipMode(
    VideoPlayerController controller, {
    int? width,
    int? height,
  }) async {
    final bool isInPip = await isInPipMode();

    if (isInPip) {
      return await exitPipMode();
    } else {
      return await enterPipMode(controller, width: width, height: height);
    }
  }

  // Singleton instance
  static final VideoPlayerPip _instance = VideoPlayerPip._();

  /// The shared instance of [VideoPlayerPip].
  static VideoPlayerPip get instance => _instance;

  VideoPlayerPip._() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  final _onPipModeChangedController = StreamController<bool>.broadcast();
  final _onPipActionController = StreamController<String>.broadcast();

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'pipModeChanged':
        final bool isInPipMode = call.arguments['isInPipMode'] as bool;
        _onPipModeChangedController.add(isInPipMode);
        break;
      case 'pipAction':
        final Object? action = call.arguments['action'];
        if (action is String) _onPipActionController.add(action);
        break;
      case 'pipError':
        final String errorMessage = call.arguments['error'] as String;
        debugPrint('PiP Error: $errorMessage');
        break;
      default:
        debugPrint('Unhandled method ${call.method}');
    }
  }

  /// Disposes resources used by the plugin.
  ///
  /// Call this when you're done using PiP to free up resources.
  /// Typically called in the `dispose` method of your StatefulWidget.
  void dispose() {
    if (!_onPipModeChangedController.isClosed) {
      _onPipModeChangedController.close();
    }
    if (!_onPipActionController.isClosed) {
      _onPipActionController.close();
    }
    _channel.setMethodCallHandler(null);
  }
}
