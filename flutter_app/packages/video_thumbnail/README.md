# video_thumbnail compatibility copy

Based on the MIT-licensed `video_thumbnail` 0.5.6 release from
https://github.com/justsoft/video_thumbnail. The original license is retained.

The Dart API and Android/iOS decoder sources are unchanged. This small local
copy makes Android builds reproducible with the current Flutter toolchain:

- Replace the removed `jcenter()` repository with Maven Central.
- Use a current Android Gradle plugin, compile SDK 35, and minimum SDK 21.
- Keep the Android namespace in Gradle instead of the source manifest.
- Declare the Dart 3 SDK range used by the application.

No files in the user's shared Pub cache are patched. The iOS podspec and
decoder remain identical to the upstream version already verified by CI.
This package can be replaced by an upstream release once these Android fixes
are published.
