import 'dart:async';
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

  static final VideoPlayerPipPlatform _platform =
      VideoPlayerPipPlatform.instance;

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
    return _platform.isInPipMode();
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

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'pipModeChanged':
        final bool isInPipMode = call.arguments['isInPipMode'] as bool;
        _onPipModeChangedController.add(isInPipMode);
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
    _channel.setMethodCallHandler(null);
  }
}
