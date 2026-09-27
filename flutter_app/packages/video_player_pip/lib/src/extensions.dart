import '../video_player_pip.dart';
import 'video_player_controller.dart';

extension VideoPlayerControllerExtension on VideoPlayerController {
  /// Checks if the device supports PiP mode.
  Future<bool> isPipSupported() {
    return VideoPlayerPip.isPipSupported();
  }

  /// Enters PiP mode for the specified player ID.
  Future<bool> enterPipMode({int? width, int? height}) {
    return VideoPlayerPip.enterPipMode(this, width: width, height: height);
  }

  /// Exits PiP mode.
  Future<bool> exitPipMode() {
    return VideoPlayerPip.exitPipMode();
  }

  /// Checks if the app is currently in PiP mode.
  Future<bool> isInPipMode() {
    return VideoPlayerPip.isInPipMode();
  }

  /// Stream of PiP mode state changes.
  Stream<bool> get onPipModeChanged {
    return VideoPlayerPip.instance.onPipModeChanged;
  }
}
