import Flutter
import UIKit

/// 把 App 沙盒裡的檔案交給檔案 App 的匯出面板, 由使用者決定存去哪.
///
/// 面板存出去的檔名就是來源檔名, 所以先在暫存目錄裡用要給使用者看的名字
/// 排一份. 同一個磁區上用硬連結, 幾百 MB 的影片不必真的多複製一次.
public class FileExportPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private var pending: FlutterResult?
  private var staging: URL?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "file_export", binaryMessenger: registrar.messenger())
    let instance = FileExportPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "save":
      save(call.arguments, result: result)
    case "cancel":
      // 複製是面板自己做的, 這裡沒有可以中途叫停的東西
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func save(_ arguments: Any?, result: @escaping FlutterResult) {
    if pending != nil {
      result(FlutterError(code: "busy", message: "上一個匯出還沒結束", details: nil))
      return
    }
    guard let args = arguments as? [String: Any],
          let files = args["files"] as? [[String: Any]],
          !files.isEmpty else {
      result(FlutterError(code: "bad_args", message: "沒有要匯出的檔案", details: nil))
      return
    }
    guard let presenter = topViewController() else {
      result(FlutterError(code: "no_activity", message: "找不到可以開啟選擇器的畫面", details: nil))
      return
    }

    let manager = FileManager.default
    let folder = manager.temporaryDirectory
      .appendingPathComponent("file_export", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    var urls: [URL] = []
    do {
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
      for file in files {
        guard let path = file["path"] as? String, let name = file["name"] as? String else {
          continue
        }
        let source = URL(fileURLWithPath: path)
        guard manager.fileExists(atPath: source.path) else {
          throw NSError(domain: "file_export", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "找不到 \(name)"])
        }
        let target = folder.appendingPathComponent(name, isDirectory: false)
        do {
          try manager.linkItem(at: source, to: target)
        } catch {
          try manager.copyItem(at: source, to: target)
        }
        urls.append(target)
      }
      if urls.isEmpty {
        throw NSError(domain: "file_export", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "沒有要匯出的檔案"])
      }
    } catch {
      try? manager.removeItem(at: folder)
      result(FlutterError(code: "missing", message: error.localizedDescription, details: nil))
      return
    }

    staging = folder
    pending = result
    let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    picker.delegate = self
    picker.modalPresentationStyle = .formSheet
    presenter.present(picker, animated: true)
  }

  public func documentPicker(_ controller: UIDocumentPickerViewController,
                             didPickDocumentsAt urls: [URL]) {
    finish(saved: urls.count, cancelled: false)
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(saved: 0, cancelled: true)
  }

  private func finish(saved: Int, cancelled: Bool) {
    if let folder = staging {
      try? FileManager.default.removeItem(at: folder)
    }
    staging = nil
    let result = pending
    pending = nil
    result?(["saved": saved, "cancelled": cancelled])
  }

  private func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
