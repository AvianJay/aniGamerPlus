Source: `video_player_pip` 0.0.10 from pub.dev, MIT licensed.

This local copy changes `android/build.gradle` to compile against Android API
36, as required by the current `video_player_android` dependency. It also
suppresses two analyzer warnings in the upstream legacy controller wrapper.
The app calls the plugin's platform interface with its current video player ID.

Additions on top of upstream:

- `updatePip` (Dart → native): arms automatic PiP when the user leaves the app
  (Android 12+ `setAutoEnterEnabled`, older Android `onUserLeaveHint`, iOS
  `canStartPictureInPictureAutomaticallyFromInline` on a controller created in
  advance), and passes the aspect ratio, the player's rect in the window
  (Android `sourceRectHint`) and the playing state.
- Android PiP window actions (rewind / play-pause / forward) sent back to Dart
  as `pipAction`, exposed as `VideoPlayerPip.instance.onPipAction`.
- Android PiP state is re-checked on the activity's pause / resume / stop, not
  only on configuration changes, and `isInPipMode` reads the live value. The
  view-hierarchy search for the video `SurfaceView` is gone: the rect comes from
  Dart.
- `VideoPlayerPip.supported` gates every call outside Android / iOS (and lets
  widget tests opt in).
