// 即時動態的資料格式. App 跟 widget extension 各編一份, ActivityKit 靠型別
// 名字把兩邊對起來 —— 所以這個檔案是唯一的正本, tool/prepare_platforms.sh
// 會把它原封不動複製進 ios/DownloadActivity/. 改欄位只改這裡.

import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct DownloadActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var title: String
    var subtitle: String
    /// 整批的進度 0~1; 小於 0 表示還不知道 (只有排隊 / 等伺服器的)
    var progress: Double
    /// 動態島縮起來時右邊那一小格, 例如「42%」
    var shortText: String
    /// App 被系統暫停之後就沒辦法再更新進度, 改給一段預估的時間區間,
    /// 讓進度條自己照著時間往前走. 回到前景就拿掉.
    var estimatedStart: Date?
    var estimatedEnd: Date?
    var finished: Bool
  }
}
