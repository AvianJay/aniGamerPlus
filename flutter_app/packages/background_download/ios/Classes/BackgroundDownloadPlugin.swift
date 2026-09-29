import Flutter
import UIKit

/// Dart 那邊的入口. 真正做事的是 [BackgroundDownloadSession] (抓檔) 跟
/// [LiveActivityController] (即時動態), 這裡只負責轉手.
public class BackgroundDownloadPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "background_download", binaryMessenger: registrar.messenger())
    let instance = BackgroundDownloadPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    BackgroundDownloadSession.shared.listener = instance
    BackgroundDownloadSession.shared.activate()
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    if BackgroundDownloadSession.shared.listener === self {
      BackgroundDownloadSession.shared.listener = nil
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let session = BackgroundDownloadSession.shared
    switch call.method {
    case "update":
      LiveActivityController.shared.update(args)
      result(nil)
    case "stop":
      LiveActivityController.shared.stop(
        doneTitle: args["doneTitle"] as? String, doneText: args["doneText"] as? String)
      result(nil)
    case "download.start":
      session.start(args) { error in
        if let error = error {
          result(FlutterError(code: "start_failed", message: error, details: nil))
        } else {
          result(nil)
        }
      }
    case "download.cancel":
      session.cancel(sn: args["sn"] as? String ?? "") { found in result(found) }
    case "download.discard":
      session.discard(name: args["name"] as? String ?? "")
      result(nil)
    case "download.snapshot":
      session.snapshot { snapshot in result(snapshot) }
    case "download.ack":
      session.ack(sn: args["sn"] as? String ?? "")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 只在主執行緒上叫
  func send(_ method: String, _ payload: [String: Any]) {
    channel.invokeMethod(method, arguments: payload)
  }
}
