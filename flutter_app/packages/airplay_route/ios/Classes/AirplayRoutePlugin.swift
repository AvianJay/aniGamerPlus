import AVFoundation
import AVKit
import Flutter
import UIKit

/// AirPlay 兩件事:
///
/// * `agp/airplay-button`: 系統的 AirPlay 按鈕 (AVRoutePickerView). 選裝置的那個
///   面板只有系統畫得出來, App 自己叫不出來, 所以按鈕本身就得是系統的.
/// * `agp/airplay/route`: 現在的輸出是不是 AirPlay、叫什麼名字. 播放器靠它決定要
///   不要換一條電視連得到的網址 —— Apple TV 自己去抓片, 而它拿不到 App 加的
///   Cookie 標頭, 也連不到手機上 127.0.0.1 那台快取.
public class AirplayRoutePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var observer: NSObjectProtocol?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = AirplayRoutePlugin()
    let methods = FlutterMethodChannel(
      name: "agp/airplay", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(
      name: "agp/airplay/route", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    registrar.register(AirplayButtonFactory(), withId: "agp/airplay-button")
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "route":
      result(AirplayRoutePlugin.currentRoute())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func currentRoute() -> [String: Any] {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    if let airplay = outputs.first(where: { $0.portType == .airPlay }) {
      return ["active": true, "name": airplay.portName]
    }
    return ["active": false, "name": ""]
  }

  public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    // 路由變更的通知是在背景執行緒發的, 事件通道要在主執行緒送
    observer = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.sink?(AirplayRoutePlugin.currentRoute())
    }
    events(AirplayRoutePlugin.currentRoute())
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let observer = observer {
      NotificationCenter.default.removeObserver(observer)
    }
    observer = nil
    sink = nil
    return nil
  }
}

class AirplayButtonFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    return AirplayButtonView(frame: frame, arguments: args as? [String: Any])
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

class AirplayButtonView: NSObject, FlutterPlatformView {
  private let picker: AVRoutePickerView

  init(frame: CGRect, arguments: [String: Any]?) {
    // 先在區域變數上設好再交出去: super.init() 之前不能讀自己的屬性
    let view = AVRoutePickerView(frame: frame)
    view.backgroundColor = .clear
    // 清單裡把電視排在喇叭前面: 這是播影片的地方
    view.prioritizesVideoDevices = true
    if let tint = arguments?["tint"] as? NSNumber {
      view.tintColor = UIColor(argb: tint.uint32Value)
    }
    if let active = arguments?["activeTint"] as? NSNumber {
      view.activeTintColor = UIColor(argb: active.uint32Value)
    }
    picker = view
    super.init()
  }

  func view() -> UIView {
    return picker
  }
}

extension UIColor {
  /// Flutter 的 Color.value (0xAARRGGBB)
  convenience init(argb: UInt32) {
    self.init(
      red: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255)
  }
}
