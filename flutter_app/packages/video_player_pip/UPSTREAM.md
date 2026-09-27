Source: `video_player_pip` 0.0.10 from pub.dev, MIT licensed.

This local copy changes `android/build.gradle` to compile against Android API
36, as required by the current `video_player_android` dependency. It also
suppresses two analyzer warnings in the upstream legacy controller wrapper.
The app calls the plugin's platform interface with its current video player ID.
