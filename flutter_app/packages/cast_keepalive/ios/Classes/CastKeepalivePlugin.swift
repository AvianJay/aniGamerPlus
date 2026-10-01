import AVFoundation
import Flutter
import UIKit

/// 投放中 App 退到背景時, 放一段靜音讓 iOS 別把它暫停. 見 lib/cast_keepalive.dart.
///
/// 音訊工作階段改成跟別的 App 混著放 (mixWithOthers): 不會打斷使用者正在聽的
/// 音樂, 也不會出現在鎖定畫面的「正在播放」. 停下來時把原本的設定還回去, 免得
/// 之後手機自己播影片時變成混音模式.
public class CastKeepalivePlugin: NSObject, FlutterPlugin {
  private var player: AVAudioPlayer?
  private var saved: (category: AVAudioSession.Category, mode: AVAudioSession.Mode,
    options: AVAudioSession.CategoryOptions)?
  private var interruption: NSObjectProtocol?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = CastKeepalivePlugin()
    let channel = FlutterMethodChannel(
      name: "agp/cast_keepalive", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "hold":
      if call.arguments as? Bool == true {
        start()
      } else {
        stop()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start() {
    if player != nil { return }
    let session = AVAudioSession.sharedInstance()
    saved = (session.category, session.mode, session.categoryOptions)
    do {
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
      let player = try AVAudioPlayer(data: CastKeepalivePlugin.silence())
      player.numberOfLoops = -1
      player.prepareToPlay()
      player.play()
      self.player = player
    } catch {
      NSLog("CastKeepalive: start failed: \(error)")
      restore()
      return
    }
    // 來電之類的中斷會把播放器停掉; 結束之後接著放, 不然 App 一樣會被暫停
    interruption = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        AVAudioSession.InterruptionType(rawValue: raw) == .ended
      else { return }
      try? AVAudioSession.sharedInstance().setActive(true)
      self?.player?.play()
    }
  }

  private func stop() {
    if let observer = interruption {
      NotificationCenter.default.removeObserver(observer)
    }
    interruption = nil
    guard let player = player else { return }
    player.stop()
    self.player = nil
    restore()
  }

  private func restore() {
    guard let saved = saved else { return }
    self.saved = nil
    try? AVAudioSession.sharedInstance().setCategory(
      saved.category, mode: saved.mode, options: saved.options)
  }

  /// 一秒的 16-bit 單聲道 8 kHz 靜音 WAV, 不必另外放一個音檔進來
  static func silence() -> Data {
    let rate: UInt32 = 8000
    let bytes = rate * 2
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36) + bytes)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    append(UInt32(16))  // fmt 區塊長度
    append(UInt16(1))  // PCM
    append(UInt16(1))  // 單聲道
    append(rate)
    append(rate * 2)  // 每秒位元組數
    append(UInt16(2))  // 每個取樣幾個位元組
    append(UInt16(16))  // 位元深度
    data.append(contentsOf: Array("data".utf8))
    append(bytes)
    data.append(Data(count: Int(bytes)))
    return data
  }
}
