/// AAB builds disable the sideload updater at compile time. APK and IPA builds
/// keep it unless explicitly disabled with --dart-define=APP_UPDATER=false.
const bool kAppUpdaterEnabled =
    bool.fromEnvironment('APP_UPDATER', defaultValue: true);
