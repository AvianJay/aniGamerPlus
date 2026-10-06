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
  /// 前景 session: 系統交付的暫存檔碰不到時 (sideload 重簽拿不到 sandbox
  /// extension) 改用它重抓. 前景下載在行程內做, 暫存檔在 App 自己的 tmp.
  private var foregroundSession: URLSession!
  /// 已經確定這個安裝的背景交付不能用, 之後的下載直接走前景
  private var foregroundOnly = false
  /// 前景重抓的 task, 不讓它再觸發一次重抓
  private var retriedTasks: Set<String> = []
  private var eventsCompletion: (() -> Void)?
  private var eventsFinished = false
  /// didFinishDownloadingTo 的結果, 留給接著來的 didCompleteWithError 一起送.
  /// taskIdentifier 只在各自的 session 內唯一, 所以 key 帶上 session.
  private var outcomes: [String: Outcome] = [:]
  private var lastProgress: [String: TimeInterval] = [:]

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

    let foregroundConfig = URLSessionConfiguration.default
    foregroundConfig.urlCache = nil
    foregroundConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
    let foregroundQueue = OperationQueue()
    foregroundQueue.maxConcurrentOperationCount = 1
    foregroundQueue.underlyingQueue = state
    foregroundSession = URLSession(
      configuration: foregroundConfig, delegate: self, delegateQueue: foregroundQueue)

    foregroundOnly = FileManager.default.fileExists(
      atPath: storage.appendingPathComponent("foreground-only").path)
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

    allTasks { tasks in
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
        if !self.foregroundOnly,
           let saved = self.loadResume(name: name),
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
          let target = self.foregroundOnly ? self.foregroundSession! : self.session!
          task = target.downloadTask(with: request)
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
    allTasks { tasks in
      let matching = tasks.filter { task in
        TransferMeta(task: task)?.sn == sn && (task.state == .running || task.state == .suspended)
      }
      if matching.isEmpty {
        DispatchQueue.main.async { done(false) }
        return
      }
      let group = DispatchGroup()
      for task in matching {
        // 前景的沒有系統續傳資料可言, 直接停; 背景的留續傳資料給下一次.
        guard task.session === self.session,
              let download = task as? URLSessionDownloadTask,
              let meta = TransferMeta(task: task) else {
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

  /// 兩個 session 的任務都要看: 背景的在系統手上, 前景的是重抓.
  /// taskIdentifier 只在各自的 session 內唯一, 兩個 session 可能撞號.
  private func taskKey(_ task: URLSessionTask) -> String {
    "\((task.session === session ? "b" : "f"))-\(task.taskIdentifier)"
  }

  private func allTasks(_ done: @escaping ([URLSessionTask]) -> Void) {
    let group = DispatchGroup()
    var tasks: [URLSessionTask] = []
    for target in [session!, foregroundSession!] {
      group.enter()
      target.getAllTasks { result in
        tasks.append(contentsOf: result)
        group.leave()
      }
    }
    group.notify(queue: state) { done(tasks) }
  }

  func snapshot(_ done: @escaping ([String: Any]) -> Void) {
    allTasks { tasks in
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
    /// 系統交付的檔案碰不到, 已經改用前景 session 重抓
    case retrying
  }

  private struct TransferError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// 在 didFinishDownloadingTo 裡同步做完: 回傳之後系統就把暫存檔刪了.
  private func finish(_ meta: TransferMeta, task: URLSessionDownloadTask, location: URL) -> Outcome {
    let manager = FileManager.default
    let dir = meta.directory
    let part = dir.appendingPathComponent(meta.name + ".part")
    let target = dir.appendingPathComponent(meta.name)
    let response = task.response as? HTTPURLResponse
    let status = response?.statusCode ?? 0
    var operation = "建立下載目錄"
    do {
      try manager.createDirectory(at: dir, withIntermediateDirectories: true)
      operation = "檢查伺服器回應"
      switch status {
      case 200, 206 where meta.offset == 0:
        // 從頭抓的, 或伺服器不吃 Range 回了整支
        if status == 206, let start = Self.rangeStart(response), start != 0 {
          throw TransferError(message: "續傳位置對不上")
        }
        operation = "保存下載影片"
        try DownloadFileStore.save(location, to: target)
        try? manager.removeItem(at: part)
      case 206:
        guard Self.rangeStart(response) == meta.offset,
              Self.size(of: part) == meta.offset
        else {
          throw TransferError(message: "續傳位置對不上")
        }
        operation = "合併續傳影片"
        try Self.append(location, to: part)
        operation = "保存續傳影片"
        try DownloadFileStore.promote(part, to: target)
      case 416:
        // 其實已經抓完了, 只是上次沒改名
        guard manager.fileExists(atPath: part.path) else {
          throw TransferError(message: "伺服器回應 416")
        }
        operation = "保存續傳影片"
        try DownloadFileStore.promote(part, to: target)
      case 404:
        return .notFound
      default:
        throw TransferError(message: "伺服器回應 \(status)")
      }
      dropResume(name: meta.name)
      return .done(Self.size(of: target) ?? 0)
    } catch {
      // sideload 重簽的 App 拿不到系統暫存檔的 sandbox extension, 檔案永遠
      // 搬不進 App 內. 改用前景 session 重抓一次, 之後直接走前景.
      if DownloadFileStore.isHandoverDenied(error), retryInForeground(meta, task: task) {
        return .retrying
      }
      return .failed("\(operation)失敗（HTTP \(status)）：\n\(downloadErrorDescription(error))")
    }
  }

  /// 同一支 URL 再抓一次, 這次是行程內下載, 暫存檔在 App 自己的 tmp,
  /// 不經 nsurlsessiond, 不受重簽的 sandbox 問題影響.
  private func retryInForeground(_ meta: TransferMeta, task: URLSessionDownloadTask) -> Bool {
    guard !retriedTasks.contains(taskKey(task)),
          let original = task.originalRequest ?? task.currentRequest, original.url != nil
    else { return false }
    var request = original
    request.allowsCellularAccess = meta.allowCellular
    let retry = foregroundSession.downloadTask(with: request)
    retry.taskDescription = meta.encoded
    retriedTasks.insert(taskKey(retry))
    rememberForegroundOnly()
    retry.resume()
    return true
  }

  /// 記住這個安裝的背景交付不能用; 之後的下載直接走前景, 不用先白抓一次.
  private func rememberForegroundOnly() {
    guard !foregroundOnly else { return }
    foregroundOnly = true
    let marker = storage.appendingPathComponent("foreground-only")
    try? Data().write(to: marker, options: .atomic)
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
    let key = taskKey(downloadTask)
    if let last = lastProgress[key], now - last < 0.5 { return }
    lastProgress[key] = now
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
    outcomes[taskKey(downloadTask)] = finish(meta, task: downloadTask, location: location)
  }

  public func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    lastProgress[taskKey(task)] = nil
    let outcome = outcomes.removeValue(forKey: taskKey(task))
    retriedTasks.remove(taskKey(task))
    guard let meta = TransferMeta(task: task) else { return }

    var result: [String: Any] = ["sn": meta.sn, "name": meta.name]
    switch outcome {
    case .retrying?:
      // 前景重抓接手了, 這一輪不報結果
      return
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
          result["error"] = downloadErrorDescription(error)
        }
      } else {
        result["status"] = "failed"
        result["error"] = error.map { downloadErrorDescription($0) } ?? "下載中斷"
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
    let finished = taskKey(task)
    allTasks { tasks in
      let remaining = tasks.filter { other in
        self.taskKey(other) != finished && (other.state == .running || other.state == .suspended)
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
