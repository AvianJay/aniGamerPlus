import 'dart:ui' show Rect;

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'video_player_pip_method_channel.dart';

abstract class VideoPlayerPipPlatform extends PlatformInterface {
  /// Constructs a VideoPlayerPipPlatform.
  VideoPlayerPipPlatform() : super(token: _token);

  static final Object _token = Object();

  static VideoPlayerPipPlatform _instance = MethodChannelVideoPlayerPip();

  /// The default instance of [VideoPlayerPipPlatform] to use.
  ///
  /// Defaults to [MethodChannelVideoPlayerPip].
  static VideoPlayerPipPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [VideoPlayerPipPlatform] when
  /// they register themselves.
  static set instance(VideoPlayerPipPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Checks if the device supports PiP mode.
  Future<bool> isPipSupported() {
    throw UnimplementedError('isPipSupported() has not been implemented.');
  }

  /// Enters PiP mode for the specified player ID.
  Future<bool> enterPipMode(int playerId, {int? width, int? height}) {
    throw UnimplementedError('enterPipMode() has not been implemented.');
  }

  /// Exits PiP mode.
  Future<bool> exitPipMode() {
    throw UnimplementedError('exitPipMode() has not been implemented.');
  }

  /// Checks if the app is currently in PiP mode.
  Future<bool> isInPipMode() {
    throw UnimplementedError('isInPipMode() has not been implemented.');
  }

  /// 子母畫面的設定: 離開 App 時要不要自動進去、視窗裡的播放鍵畫成哪一個.
  ///
  /// [playerId] 是 null 表示不再有可以進子母畫面的播放器 (離開播放頁).
  /// [width] / [height] 只拿來算比例; [sourceRect] 是播放器在視窗裡的位置
  /// (實體像素), Android 拿它做進出子母畫面的動畫.
  Future<bool> updatePip({
    int? playerId,
    required bool autoEnter,
    required bool playing,
    int? width,
    int? height,
    Rect? sourceRect,
  }) {
    throw UnimplementedError('updatePip() has not been implemented.');
  }
}
