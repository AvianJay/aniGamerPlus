import ActivityKit
import Foundation
import UIKit

/// 動態島 / 鎖定畫面的即時動態.
///
/// 內容是 Dart 算好丟過來的 (跟 Android 的通知是同一份), 這裡另外管兩件
/// Dart 做不到的事:
///
/// * App 被系統暫停之後就沒有人更新進度了. 進到背景那一刻用最近的速度推一個
///   預估的時間區間, widget 的進度條照著時間自己走 (ProgressView(timerInterval:)).
/// * 背景下載在沒有 Flutter engine 的時候做完 (系統只在背景把 App 叫醒),
///   由 [backgroundResult] 直接把即時動態改掉.
///
/// 全部只在主執行緒上叫.
final class LiveActivityController {
  static let shared = LiveActivityController()

  private var title = ""
  private var subtitle = ""
  private var progress = -1.0
  private var shortText = ""
  private var samples: [(time: Date, progress: Double)] = []
  /// 使用者把即時動態滑掉了: 這一批就別再冒出來, 等 stop() 才重來
  private var dismissed = false
  /// Activity<DownloadActivityAttributes>, 存成 Any 是因為儲存屬性不能標 @available
  private var current: Any?
  private var observers: [NSObjectProtocol] = []

  private init() {
    let center = NotificationCenter.default
    // 進背景: 換成預估的進度條. 回前景: 拿掉預估, 等 Dart 送真的進度來.
    for name in [UIApplication.didEnterBackgroundNotification,
                 UIApplication.didBecomeActiveNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in self?.push()
      })
    }
  }

  func update(_ args: [String: Any]) {
    title = args["title"] as? String ?? ""
    subtitle = args["text"] as? String ?? ""
    shortText = args["shortText"] as? String ?? ""
    let raw = (args["progress"] as? NSNumber)?.intValue ?? -1
    progress = raw >= 0 ? Double(raw) / 1000 : -1
    record(progress)
    push()
  }

  /// [doneTitle] 不是 nil: 換成完成的樣子, 在鎖定畫面上多留一會兒. 否則直接收掉.
  func stop(doneTitle: String?, doneText: String?) {
    title = ""
    subtitle = ""
    shortText = ""
    progress = -1
    samples.removeAll()
    dismissed = false
    current = nil
    guard #available(iOS 16.2, *) else { return }
    let activities = Activity<DownloadActivityAttributes>.activities
    if let doneTitle = doneTitle {
      let state = DownloadActivityAttributes.ContentState(
        title: doneTitle, subtitle: doneText ?? "", progress: 1, shortText: "",
        estimatedStart: nil, estimatedEnd: nil, finished: true)
      let content = ActivityContent(state: state, staleDate: nil)
      let until = Date().addingTimeInterval(15 * 60)
      for activity in activities {
        Task { await activity.end(content, dismissalPolicy: .after(until)) }
      }
    } else {
      for activity in activities {
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
      }
    }
  }

  /// 背景下載做完了一集, 但 Dart 不在. [remaining] 是 session 裡還在跑的工作數.
  func backgroundResult(label: String, done: Bool, remaining: Int) {
    if remaining == 0 {
      stop(doneTitle: done ? "下載完成" : nil, doneText: done ? label : nil)
      return
    }
    guard done else { return }
    title = "已下載 \(label)"
    subtitle = "還有 \(remaining) 集在背景下載"
    shortText = ""
    progress = -1
    samples.removeAll()
    push()
  }

  private func push() {
    guard #available(iOS 16.2, *) else { return }
    // stop() 之後、下一批開始之前沒有東西可以顯示
    guard !title.isEmpty else { return }
    var state = DownloadActivityAttributes.ContentState(
      title: title, subtitle: subtitle, progress: progress, shortText: shortText,
      estimatedStart: nil, estimatedEnd: nil, finished: false)
    if UIApplication.shared.applicationState == .background,
       progress >= 0, progress < 1, let rate = rate() {
      // 讓「現在」剛好落在 progress 的位置上, 之後照著速度走
      let now = Date()
      state.estimatedStart = now.addingTimeInterval(-progress / rate)
      state.estimatedEnd = now.addingTimeInterval((1 - progress) / rate)
    }
    apply(state)
  }

  @available(iOS 16.2, *)
  private var activity: Activity<DownloadActivityAttributes>? {
    get { current as? Activity<DownloadActivityAttributes> }
    set { current = newValue }
  }

  @available(iOS 16.2, *)
  private func apply(_ state: DownloadActivityAttributes.ContentState) {
    let content = ActivityContent(state: state, staleDate: nil)
    if let activity = activity {
      switch activity.activityState {
      case .active, .stale:
        Task { await activity.update(content) }
      default:
        // 使用者自己把它滑掉了 (或系統收掉了)
        dismissed = true
        self.activity = nil
      }
      return
    }
    if dismissed { return }
    // 上一輪 App 被收掉時留下來的, 接著用
    if let existing = Activity<DownloadActivityAttributes>.activities.first(where: {
      $0.activityState == .active || $0.activityState == .stale
    }) {
      activity = existing
      Task { await existing.update(content) }
      return
    }
    // 新開一個只能在前景
    guard UIApplication.shared.applicationState != .background,
          ActivityAuthorizationInfo().areActivitiesEnabled
    else {
      return
    }
    do {
      activity = try Activity<DownloadActivityAttributes>.request(
        attributes: DownloadActivityAttributes(), content: content, pushType: nil)
    } catch {
      // 使用者關掉了即時動態、或同時開著的太多: 沒有就沒有, 下載照跑
    }
  }

  private func record(_ value: Double) {
    let now = Date()
    guard value >= 0 else {
      samples.removeAll()
      return
    }
    // 倒退表示換了一批 (或有一集被刪掉), 舊的速度不能用
    if let last = samples.last, value < last.progress { samples.removeAll() }
    samples.append((now, value))
    samples.removeAll { now.timeIntervalSince($0.time) > 60 }
  }

  /// 每秒走多少 (0~1). 樣本太短或沒在動就不猜.
  private func rate() -> Double? {
    guard let first = samples.first, let last = samples.last else { return nil }
    let span = last.time.timeIntervalSince(first.time)
    guard span >= 3 else { return nil }
    let value = (last.progress - first.progress) / span
    return value > 0 ? value : nil
  }
}
