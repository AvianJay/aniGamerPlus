import Foundation
import UIKit

/// 影片檔交給系統的背景 URLSession 抓.
///
/// App 被暫停、甚至被系統收掉之後, 傳輸是 nsurlsessiond 在做的; 做完時系統把
/// App 在背景叫醒, 呼叫 AppDelegate 的 handleEventsForBackgroundURLSession, 這裡
/// 接回同一個 session 收結果. 那時候不一定有 Flutter engine (背景啟動不會連上
/// scene), 所以:
///
/// * 把檔案搬到位是這裡自己做的, 不等 Dart;
/// * 結果先落盤 (results.json), Dart 下次起來用 snapshot 拿, 處理完再 ack;
/// * 沒有 Dart 接著的時候, 即時動態由這裡直接改 (LiveActivityController.backgroundResult).
///
/// 續傳沿用 Dart 的 `.part`: 起點是 `.part` 的長度, 送 Range, 抓完把剩下的接在
/// `.part` 後面再改名. 暫停時另外留 URLSession 自己的續傳資料, 下次從停下來的
/// 那個位元組接著抓, 不必退回 `.part` 的尾巴.
public final class BackgroundDownloadSession: NSObject {
  public static let shared = BackgroundDownloadSession()

  static var identifier: String {
    (Bundle.main.bundleIdentifier ?? "agp") + ".downloads"
  }

  /// Dart 接著的話由它轉送事件. 背景啟動、沒有 engine 的時候是 nil.
  weak var listener: BackgroundDownloadPlugin?

  /// 所有狀態都在這條佇列上動, URLSession 的 delegate 也跑在這上面
  private let state = DispatchQueue(label: "tw.avianjay.background_download")
  private var session: URLSession!
  private var eventsCompletion: (() -> Void)?
  private var eventsFinished = false
  /// didFinishDownloadingTo 的結果, 留給接著來的 didCompleteWithError 一起送
  private var outcomes: [Int: Outcome] = [:]
  private var lastProgress: [Int: TimeInterval] = [:]

  private lazy var storage: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("background_download", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  private override init() {
    super.init()
    let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.underlyingQueue = state
    session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
  }

  /// App 一啟動就叫: 背景 session 要早點接回來, 上一輪沒送到的事件才收得到.
  public func activate() {
    _ = session
  }

  /// 給 AppDelegate 的 handleEventsForBackgroundURLSession 用. 不是這個 session 的回 false.
  @discardableResult
  public func handleEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
    guard identifier == Self.identifier else { return false }
    state.async {
      if self.eventsFinished {
        self.eventsFinished = false
        Self.finishEvents(completionHandler)
      } else {
        self.eventsCompletion = completionHandler
      }
    }
    return true
  }

  // MARK: - Dart 叫的

  func start(_ args: [String: Any], done: @escaping (String?) -> Void) {
    guard let sn = args["sn"] as? String, !sn.isEmpty,
          let urlText = args["url"] as? String, let url = URL(string: urlText),
          let directory = args["directory"] as? String,
          let name = args["name"] as? String, !name.isEmpty
    else {
      done("參數不完整")
      return
    }
    let headers = args["headers"] as? [String: String] ?? [:]
    let offset = (args["offset"] as? NSNumber)?.int64Value ?? 0
    let allowCellular = args["allowCellular"] as? Bool ?? true
    let meta = TransferMeta(
      sn: sn, dir: Self.homeRelative(directory), name: name, offset: offset,
      label: args["label"] as? String ?? sn, allowCellular: allowCellular)

    session.getAllTasks { tasks in
      self.state.async {
        let busy = tasks.contains { task in
          TransferMeta(task: task)?.sn == sn && (task.state == .running || task.state == .suspended)
        }
        if busy {
          DispatchQueue.main.async { done(nil) }
          return
        }
        let task: URLSessionDownloadTask
        // 續傳資料裡夾著當初那一個請求 (含 allowsCellularAccess). 起點或行動網路
        // 設定不一樣了就不能用, 從 .part 的尾巴重新要.
        if let saved = self.loadResume(name: name),
           saved.meta.offset == offset, saved.meta.allowCellular == allowCellular {
          task = self.session.downloadTask(withResumeData: saved.data)
        } else {
          var request = URLRequest(url: url)
          for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
          }
          if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
          }
          request.allowsCellularAccess = allowCellular
          task = self.session.downloadTask(with: request)
        }
        self.dropResume(name: name)
        task.taskDescription = meta.encoded
        task.resume()
        DispatchQueue.main.async { done(nil) }
      }
    }
  }

  /// 叫停並留下續傳資料. 真的有停到東西才回 true.
  func cancel(sn: String, done: @escaping (Bool) -> Void) {
    session.getAllTasks { tasks in
      let matching = tasks.filter { task in
        TransferMeta(task: task)?.sn == sn && (task.state == .running || task.state == .suspended)
      }
      if matching.isEmpty {
        DispatchQueue.main.async { done(false) }
        return
      }
      let group = DispatchGroup()
      for task in matching {
        guard let download = task as? URLSessionDownloadTask, let meta = TransferMeta(task: task) else {
          task.cancel()
          continue
        }
        group.enter()
        download.cancel(byProducingResumeData: { data in
          self.state.async {
            if let data = data { self.saveResume(meta, data) }
            group.leave()
          }
        })
      }
      group.notify(queue: .main) { done(true) }
    }
  }

  func discard(name: String) {
    guard !name.isEmpty else { return }
    state.async { self.dropResume(name: name) }
  }

  func snapshot(_ done: @escaping ([String: Any]) -> Void) {
    session.getAllTasks { tasks in
      self.state.async {
        var running: [[String: Any]] = []
        for task in tasks where task.state == .running || task.state == .suspended {
          guard let meta = TransferMeta(task: task) else { continue }
          let expected = task.countOfBytesExpectedToReceive
          running.append([
            "sn": meta.sn,
            "name": meta.name,
            "received": meta.offset + task.countOfBytesReceived,
            "total": expected > 0 ? meta.offset + expected : 0,
          ])
        }
        let results = Array(self.loadResults().values)
        DispatchQueue.main.async { done(["running": running, "results": results]) }
      }
    }
  }

  func ack(sn: String) {
    state.async {
      var results = self.loadResults()
      if results.removeValue(forKey: sn) != nil { self.saveResults(results) }
    }
  }

  // MARK: - 收尾

  private enum Outcome {
    case done(Int64)
    case notFound
    case failed(String)
  }

  private struct TransferError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// 在 didFinishDownloadingTo 裡同步做完: 回傳之後系統就把暫存檔刪了.
  private func finish(_ meta: TransferMeta, response: HTTPURLResponse?, location: URL) -> Outcome {
    let manager = FileManager.default
    let dir = meta.directory
    let part = dir.appendingPathComponent(meta.name + ".part")
    let target = dir.appendingPathComponent(meta.name)
    let status = response?.statusCode ?? 0
    do {
      try manager.createDirectory(at: dir, withIntermediateDirectories: true)
      switch status {
      case 200, 206 where meta.offset == 0:
        // 從頭抓的, 或伺服器不吃 Range 回了整支
        if status == 206, let start = Self.rangeStart(response), start != 0 {
          throw TransferError(message: "續傳位置對不上")
        }
        try? manager.removeItem(at: part)
        try? manager.removeItem(at: target)
        try manager.moveItem(at: location, to: target)
      case 206:
        guard Self.rangeStart(response) == meta.offset,
              Self.size(of: part) == meta.offset
        else {
          throw TransferError(message: "續傳位置對不上")
        }
        try Self.append(location, to: part)
        try? manager.removeItem(at: target)
        try manager.moveItem(at: part, to: target)
      case 416:
        // 其實已經抓完了, 只是上次沒改名
        guard manager.fileExists(atPath: part.path) else {
          throw TransferError(message: "伺服器回應 416")
        }
        try? manager.removeItem(at: target)
        try manager.moveItem(at: part, to: target)
      case 404:
        return .notFound
      default:
        throw TransferError(message: "伺服器回應 \(status)")
      }
      dropResume(name: meta.name)
      return .done(Self.size(of: target) ?? 0)
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  private static func finishEvents(_ handler: @escaping () -> Void) {
    // 讓即時動態那邊的 async 更新有機會送出去, 再讓系統把 App 收回去
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: handler)
  }

  // MARK: - 落盤

  private func loadResults() -> [String: [String: Any]] {
    let file = storage.appendingPathComponent("results.json")
    guard let data = try? Data(contentsOf: file),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
    else {
      return [:]
    }
    return raw
  }

  private func saveResults(_ results: [String: [String: Any]]) {
    let file = storage.appendingPathComponent("results.json")
    guard let data = try? JSONSerialization.data(withJSONObject: results) else { return }
    try? data.write(to: file, options: .atomic)
  }

  private func resumeFiles(name: String) -> (data: URL, meta: URL) {
    (storage.appendingPathComponent("resume-\(name).data"),
     storage.appendingPathComponent("resume-\(name).json"))
  }

  private func saveResume(_ meta: TransferMeta, _ data: Data) {
    let files = resumeFiles(name: meta.name)
    guard let encoded = try? JSONEncoder().encode(meta) else { return }
    try? data.write(to: files.data, options: .atomic)
    try? encoded.write(to: files.meta, options: .atomic)
  }

  private func loadResume(name: String) -> (meta: TransferMeta, data: Data)? {
    let files = resumeFiles(name: name)
    guard let data = try? Data(contentsOf: files.data),
          let raw = try? Data(contentsOf: files.meta),
          let meta = try? JSONDecoder().decode(TransferMeta.self, from: raw)
    else {
      return nil
    }
    return (meta, data)
  }

  private func dropResume(name: String) {
    let files = resumeFiles(name: name)
    try? FileManager.default.removeItem(at: files.data)
    try? FileManager.default.removeItem(at: files.meta)
  }

  // MARK: - 小工具

  /// App 的沙盒路徑在更新之後會換, 所以只記相對於 home 的那一段.
  static func homeRelative(_ path: String) -> String {
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
    let full = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let prefix = home.hasSuffix("/") ? home : home + "/"
    return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
  }

  /// `Content-Range: bytes 100-999/1000` 的 100
  static func rangeStart(_ response: HTTPURLResponse?) -> Int64? {
    guard let value = response?.value(forHTTPHeaderField: "Content-Range") else { return nil }
    let text = value.trimmingCharacters(in: .whitespaces)
    guard text.lowercased().hasPrefix("bytes ") else { return nil }
    let rest = text.dropFirst(6)
    guard let dash = rest.firstIndex(of: "-") else { return nil }
    return Int64(rest[rest.startIndex..<dash].trimmingCharacters(in: .whitespaces))
  }

  static func size(of url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return nil
    }
    return (attributes[.size] as? NSNumber)?.int64Value
  }

  static func append(_ source: URL, to destination: URL) throws {
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    try output.seekToEnd()
    while true {
      let chunk = try input.read(upToCount: 4 << 20) ?? Data()
      if chunk.isEmpty { break }
      try output.write(contentsOf: chunk)
    }
  }
}

extension BackgroundDownloadSession: URLSessionDownloadDelegate {
  public func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let now = Date().timeIntervalSince1970
    if let last = lastProgress[downloadTask.taskIdentifier], now - last < 0.5 { return }
    lastProgress[downloadTask.taskIdentifier] = now
    guard let meta = TransferMeta(task: downloadTask) else { return }
    // 伺服器不吃 Range 的話回的是整支 (200), 起點就不是 offset 了
    let partial = (downloadTask.response as? HTTPURLResponse)?.statusCode == 206
    let base = partial ? meta.offset : 0
    let payload: [String: Any] = [
      "sn": meta.sn,
      "received": base + totalBytesWritten,
      "total": totalBytesExpectedToWrite > 0 ? base + totalBytesExpectedToWrite : 0,
    ]
    DispatchQueue.main.async { self.listener?.send("download.progress", payload) }
  }

  public func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let meta = TransferMeta(task: downloadTask) else { return }
    outcomes[downloadTask.taskIdentifier] = finish(
      meta, response: downloadTask.response as? HTTPURLResponse, location: location)
  }

  public func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    lastProgress[task.taskIdentifier] = nil
    let outcome = outcomes.removeValue(forKey: task.taskIdentifier)
    guard let meta = TransferMeta(task: task) else { return }

    var result: [String: Any] = ["sn": meta.sn, "name": meta.name]
    switch outcome {
    case .done(let size)?:
      result["status"] = "done"
      result["received"] = size
      result["total"] = size
    case .notFound?:
      result["status"] = "notFound"
    case .failed(let message)?:
      result["status"] = "failed"
      result["error"] = message
    case nil:
      result["received"] = meta.offset + task.countOfBytesReceived
      if let error = error as? URLError {
        if let data = error.downloadTaskResumeData { saveResume(meta, data) }
        if error.code == .cancelled {
          result["status"] = "cancelled"
        } else {
          result["status"] = "failed"
          result["error"] = error.localizedDescription
        }
      } else {
        result["status"] = "failed"
        result["error"] = error?.localizedDescription ?? "下載中斷"
      }
    }

    let status = result["status"] as? String ?? ""
    // 叫停的不必留: 那是 Dart 自己要的, 或是 App 被滑掉 —— 下次起來本來就是暫停
    if status != "cancelled" {
      var stored = loadResults()
      stored[meta.sn] = result
      saveResults(stored)
    }

    let payload = result
    let label = meta.label
    let finished = task.taskIdentifier
    session.getAllTasks { tasks in
      let remaining = tasks.filter { other in
        other.taskIdentifier != finished && (other.state == .running || other.state == .suspended)
      }.count
      DispatchQueue.main.async {
        if let listener = self.listener {
          listener.send("download.result", payload)
        } else if status != "cancelled" {
          LiveActivityController.shared.backgroundResult(
            label: label, done: status == "done", remaining: remaining)
        }
      }
    }
  }

  public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    guard let handler = eventsCompletion else {
      // AppDelegate 還沒把 completion handler 交過來, 等它來了直接叫
      eventsFinished = true
      return
    }
    eventsCompletion = nil
    Self.finishEvents(handler)
  }
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
