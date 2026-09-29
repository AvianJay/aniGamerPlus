// 下載進度的即時動態: 動態島 (縮起來 / 展開 / 最小) 跟鎖定畫面.
//
// 這個資料夾會被 tool/prepare_platforms.sh 複製成 ios/DownloadActivity/, 並在
// Runner.xcodeproj 裡加一個 widget extension target. DownloadActivityAttributes.swift
// 不在這裡 —— 正本在 packages/background_download/ios/Classes/, 腳本會一起複製過來.

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DownloadActivityBundle: WidgetBundle {
  var body: some Widget {
    DownloadLiveActivity()
  }
}

/// App 的主色 (lib/src/theme.dart 的 accent)
private let accent = Color(red: 0, green: 181 / 255, blue: 212 / 255)

typealias DownloadState = DownloadActivityAttributes.ContentState

struct DownloadLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
      LockScreenView(state: context.state)
        .activitySystemActionForegroundColor(accent)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          StatusIcon(state: context.state)
            .font(.title2)
            .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          PercentText(state: context.state)
            .font(.title3.weight(.semibold))
            .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.state.title)
            .font(.headline)
            .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            DownloadProgressBar(state: context.state)
            DetailText(state: context.state)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .padding(.horizontal, 4)
        }
      } compactLeading: {
        StatusIcon(state: context.state)
      } compactTrailing: {
        CompactTrailing(state: context.state)
      } minimal: {
        ProgressRing(state: context.state)
      }
      .keylineTint(accent)
    }
  }
}

struct LockScreenView: View {
  let state: DownloadState

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      ZStack {
        Circle().fill(accent.opacity(0.18))
        StatusIcon(state: state).font(.title3)
      }
      .frame(width: 44, height: 44)

      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Text(state.title)
            .font(.headline)
            .lineLimit(1)
          Spacer(minLength: 8)
          PercentText(state: state)
            .font(.subheadline.weight(.semibold))
        }
        DownloadProgressBar(state: state)
        DetailText(state: state)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(16)
  }
}

struct StatusIcon: View {
  let state: DownloadState

  var body: some View {
    Image(systemName: state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
      .foregroundStyle(accent)
  }
}

/// App 在前景時是真的百分比; 被暫停之後改顯示預估的剩餘時間.
struct PercentText: View {
  let state: DownloadState

  var body: some View {
    if state.finished {
      Text("完成")
    } else if let end = state.estimatedEnd, end > Date() {
      Text(timerInterval: Date()...end, countsDown: true)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 64, alignment: .trailing)
    } else if state.progress >= 0 {
      Text("\(Int(state.progress * 100))%")
        .monospacedDigit()
    }
  }
}

struct DetailText: View {
  let state: DownloadState

  var body: some View {
    if state.estimatedEnd != nil && !state.finished {
      Text(state.subtitle.isEmpty ? "背景下載中 · 預估" : "\(state.subtitle) · 預估")
    } else {
      Text(state.subtitle)
    }
  }
}

struct DownloadProgressBar: View {
  let state: DownloadState

  var body: some View {
    Group {
      if state.finished {
        ProgressView(value: 1.0)
      } else if let start = state.estimatedStart, let end = state.estimatedEnd, start < end {
        ProgressView(timerInterval: start...end, countsDown: false) {
          EmptyView()
        } currentValueLabel: {
          EmptyView()
        }
      } else {
        ProgressView(value: max(0, min(1, state.progress)))
      }
    }
    .progressViewStyle(.linear)
    .tint(accent)
  }
}

struct ProgressRing: View {
  let state: DownloadState

  var body: some View {
    Group {
      if state.finished {
        Image(systemName: "checkmark")
          .font(.caption2.weight(.bold))
          .foregroundStyle(accent)
      } else if let start = state.estimatedStart, let end = state.estimatedEnd, start < end {
        ProgressView(timerInterval: start...end, countsDown: false) {
          EmptyView()
        } currentValueLabel: {
          EmptyView()
        }
        .progressViewStyle(.circular)
      } else {
        ProgressView(value: max(0, min(1, state.progress)))
          .progressViewStyle(.circular)
      }
    }
    .tint(accent)
  }
}

/// 動態島縮起來時右邊那一格: 有確切的百分比就寫字, 不然畫一圈.
struct CompactTrailing: View {
  let state: DownloadState

  var body: some View {
    if state.finished || state.estimatedEnd != nil || state.shortText.isEmpty {
      ProgressRing(state: state)
    } else {
      Text(state.shortText)
        .font(.caption.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(accent)
    }
  }
}
