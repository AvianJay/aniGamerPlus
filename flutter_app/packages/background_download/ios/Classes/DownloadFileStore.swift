import Foundation
import Darwin

/// URLSession 的暫存檔必須在 delegate 回傳前保存到 App 內。
enum DownloadFileStore {
  static func save(_ source: URL, to target: URL, manager: FileManager = .default) throws {
    // 先取得完整的新檔，再替換舊檔；暫存檔搬移失敗時不刪掉現有影片。
    let staging = target.deletingLastPathComponent()
      .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? manager.removeItem(at: staging) }
    do {
      try manager.moveItem(at: source, to: staging)
    } catch {
      let failure = error as NSError
      // 有讀取權限但無法搬動系統暫存檔時，改用複製；原檔由 URLSession 清理。
      // 其他錯誤（例如檔案已不存在、磁碟已滿）保留原始原因。
      guard failure.domain == NSCocoaErrorDomain,
            failure.code == NSFileWriteNoPermissionError || failure.code == NSFileReadNoPermissionError,
            manager.fileExists(atPath: source.path),
            !manager.fileExists(atPath: staging.path)
      else { throw error }
      do {
        try manager.copyItem(at: source, to: staging)
      } catch {
        throw SaveError(message:
          "搬移暫存檔失敗：\n\(downloadErrorDescription(failure))\n\n複製暫存檔失敗：\n\(downloadErrorDescription(error))")
      }
    }
    try promote(staging, to: target, manager: manager)
  }

  /// 這個錯誤是不是「系統交付的暫存檔碰不到」: 重簽過的 App (共用/萬用憑證
  /// 的 sideload) 拿不到 nsurlsessiond 那顆檔案的 sandbox extension, 搬不出
  /// 來也讀不到, 典型是 NSCocoaErrorDomain 513 加上 NSPOSIXErrorDomain 1.
  static func isHandoverDenied(_ error: Error) -> Bool {
    if error is SaveError { return true }
    var current = error as NSError
    for _ in 0..<5 {
      if current.domain == NSCocoaErrorDomain,
         current.code == NSFileWriteNoPermissionError || current.code == NSFileReadNoPermissionError {
        return true
      }
      if current.domain == NSPOSIXErrorDomain,
         current.code == EPERM || current.code == EACCES {
        return true
      }
      guard let next = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
      current = next
    }
    return false
  }

  /// 完整檔案才會進到這裡；替換失敗不能先刪掉舊影片。
  static func promote(_ source: URL, to target: URL, manager: FileManager = .default) throws {
    if manager.fileExists(atPath: target.path) {
      _ = try manager.replaceItemAt(target, withItemAt: source, options: .usingNewMetadataOnly)
    } else {
      try manager.moveItem(at: source, to: target)
    }
  }

  private struct SaveError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }
}

/// 保留可辨識的系統錯誤碼及底層原因，不輸出 userInfo 內的請求或續傳資料。
func downloadErrorDescription(_ error: Error) -> String {
  var current = error as NSError
  var lines = ["\(current.localizedDescription) [\(current.domain) \(current.code)]"]
  for _ in 0..<4 {
    guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
    lines.append("原因：\(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]")
    current = underlying
  }
  return lines.joined(separator: "\n")
}
