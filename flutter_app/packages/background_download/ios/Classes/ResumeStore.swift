import Foundation

/// 續傳資料的落盤格式.
///
/// 舊版 (只有背景 session 的版本) 的 `resume-<name>.json` 根層級就是
/// `TransferMeta`; 現在多包一層 `SavedResume` 記下它是哪一個 session 產生的
/// —— 背景與前景的續傳資料不能互換. 讀的時候兩種都要吃, 不然升級之後暫停中
/// 的下載會接不回去.
enum ResumeStore {
  static func encode(_ meta: TransferMeta, foreground: Bool) -> Data? {
    try? JSONEncoder().encode(SavedResume(meta: meta, foreground: foreground))
  }

  /// 先試新格式; 解不開就當成舊格式 (舊版只有背景 session).
  static func decode(_ raw: Data) -> (meta: TransferMeta, foreground: Bool)? {
    let decoder = JSONDecoder()
    if let saved = try? decoder.decode(SavedResume.self, from: raw) {
      return (saved.meta, saved.foreground)
    }
    guard let meta = try? decoder.decode(TransferMeta.self, from: raw) else { return nil }
    return (meta, false)
  }
}

/// 續傳資料連同它是哪一個 session 產生的 —— 背景與前景的續傳資料不能互換.
struct SavedResume: Codable {
  var meta: TransferMeta
  var foreground: Bool
}

/// 跟著每個工作走的資料, 放在 taskDescription 裡 —— App 被收掉重開之後
/// URLSession 還給我們的工作只剩這個可以認.
struct TransferMeta: Codable {
  var sn: String
  /// 相對於 NSHomeDirectory() 的下載目錄
  var dir: String
  var name: String
  var offset: Int64
  var label: String
  var allowCellular: Bool
}

extension TransferMeta {
  init?(task: URLSessionTask) {
    guard let text = task.taskDescription, let data = text.data(using: .utf8),
          let meta = try? JSONDecoder().decode(TransferMeta.self, from: data)
    else {
      return nil
    }
    self = meta
  }

  var encoded: String {
    guard let data = try? JSONEncoder().encode(self) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }

  var directory: URL {
    if dir.hasPrefix("/") { return URL(fileURLWithPath: dir, isDirectory: true) }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(dir, isDirectory: true)
  }
}
