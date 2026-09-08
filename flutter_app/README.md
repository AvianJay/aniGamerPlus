# aniGamerPlus 行動版

`Dashboard/` 那個網頁介面的 iOS / Android 原生版本, 用 Flutter 寫的.

它**不是**一個把網頁包起來的殼 (那個是 repo 根目錄的 `ios/`), 而是直接打
Dashboard 的 HTTP API, 所以多了一件網頁做不到的事: **把整集下載到手機裡, 沒網路
也能看**.

---

## 需要什麼

* 一台跑著 aniGamerPlus 的機器, `config.json` 裡 `use_dashboard: true`,
  而且 `dashboard.host` 不能是 `127.0.0.1` —— 手機連不到別人的 localhost.
  區網的話填 `0.0.0.0`, 手機那邊再輸入電腦的區網 IP.
* 想在手機上看串流的話, `dashboard.online_watch` 要打開.
* 有開帳號系統 (`dashboard.user_control.enabled`) 就用帳號登入; 沒開的話
  App 會把每個人都當成管理員, 跟網頁版的判斷一樣.

第一次開 App 會問伺服器位址, 例如 `http://192.168.1.10:5000`.

## 有哪些功能

跟網頁版一對一, 少數幾個地方為了手機重新排過:

| 網頁 | App |
| --- | --- |
| 首頁 (最近更新 / 繼續看 / 收藏 / 每日更新) | 底部五個分頁: 首頁・所有動畫・收藏・紀錄・我的 |
| `watch.html` 播放器 | 播放頁: 彈幕、倍速、畫面比例、亮度/音量手勢、自動下一集、選集 |
| 邊看邊下載 | 一樣 —— 排一個 single 任務, 然後讀伺服器的 HLS EVENT 播放清單 |
| 片庫搜尋 / 作品資訊 | 所有動畫分頁 + 作品資訊 sheet |
| `control.html` 主控台 | 「我的」→ 伺服器設定 (同樣 30 個欄位, 分區重排) |
| sn_list 編輯 | 「我的」→ sn_list, 多了「貼連結加一行」 |
| 手動添加任務 | 「我的」→ 手動添加任務 |
| 網頁控制台 | 「我的」→ 網頁控制台 |
| `monitor.html` | 「我的」→ 任務監控 (同一支 WebSocket) |
| 登入 / 註冊 / 個人資料 / 用戶管理 | 都有 |
| — | **下載到手機 + 離線播放** (網頁版沒有) |
| — | **App 偏好設定** —— 這支手機自己的播放/下載/外觀偏好 |

「伺服器設定」改的是伺服器上的 `config.json`; 「App 偏好設定」只存在這支手機的
`shared_preferences` 裡, 兩者互不影響.

只有一個網頁有、App 沒有的東西: 播放器的**子母畫面**. iOS 跟 Android 的 PiP 各自
要寫原生層, 這一版先跳過, 其餘都在.

### 離線下載怎麼運作

長按片庫卡片或在作品資訊裡選「下載到手機」, 就會排進佇列:

* 每一集是一支對 `/get_video.mp4` 的 Range 請求, 邊下邊寫 `.part`;
  暫停就是把連線切掉, 續傳靠 `.part` 的長度接回去.
* 勾了「一起抓彈幕」的話同時抓一份 `.ass`, 離線播放才有彈幕.
* 下載完的集數, 首頁跟播放頁會自動改讀本機檔 —— 連不到伺服器時照樣點得開.
* 檔案放在 App 自己的沙盒裡 (`path_provider` 的 documents), 移除 App 就一起消失.

## 本機開發

平台目錄 (`android/`, `ios/`) 不進版控 —— 那些是 `flutter create` 的樣板, 留在
repo 裡只會變成沒人維護的死碼. 第一次要先產生一次:

```bash
cd flutter_app
bash tool/prepare_platforms.sh
```

這支會 `flutter create` 一份樣板搬進來, 然後補上這個 App 需要的東西:

* `AndroidManifest.xml`: `INTERNET` 權限、`usesCleartextTraffic`
  (自架伺服器多半是區網 http)、url_launcher 要的 `<queries>`.
* `Info.plist`: ATS 例外、區網存取說明、背景播放聲音、橫向.

然後就是一般的 Flutter 流程:

```bash
flutter run
flutter build apk --release
flutter build ios --release --no-codesign
```

程式碼長這樣:

```
lib/
  main.dart              進入點
  src/
    api/                 HTTP 客戶端 + 資料模型 (對應 Dashboard/Server.py 的路由)
    danmaku/             .ass 解析與彈幕層 (取代網頁的 ass.global.min.js)
    pages/               每一頁, 檔名對得上網頁的 template
    state/               AppState / 下載佇列 / 偏好設定 (ChangeNotifier, 沒用套件)
    util/                格式化
    widgets/             共用零件
```

## CI

`.github/workflows/Flutter-build.yml`:

* `analyze` —— `flutter analyze`
* `android` —— APK + AAB, 用 Flutter 的 debug 金鑰簽 (裝得起來, 上不了商店)
* `ios` —— 未簽名的 IPA, 跟 `iOS-build.yml` 一樣要靠 sideloader 自己簽

三個都會上傳成 artifact, 發 release 的時候 APK 跟 IPA 會自動附上去.


### 播放器操作與快取

- 右上角可直接選擇 0.25–2 倍速與片源提供的畫質；右下角為倒退／快進 10 秒及播放鍵。
- 左半邊上下滑調整影片亮度，右半邊上下滑調整播放音量，控制列顯示時也能使用。亮度調整作用於影片畫面。
- 拖曳到尚未緩衝的位置時，進度停留在目標並等待原生播放器確認；連續拖曳以最後一次為準。邊下載邊播放會等待伺服器產生目標片段。
- 海報與縮圖共用磁碟快取，重新開啟 App 可重用；過期後依伺服器快取標頭更新。不同伺服器／登入憑證的快取分開。
- `flutter test` 覆蓋延遲跳轉、連續拖曳、手勢、窄螢幕與橫向佈局，GitHub Actions 會在 Android／iOS 建置前執行。

- 中央三分之一區域雙擊播放／暫停，左右兩側雙擊倒退／快進 10 秒。長按的「2x 倍速中」提示持續到放開，離開 App 時會取消長按倍速。
- 底部按鈕使用至少 52×52 的觸控區域；畫面拉伸只在全螢幕顯示與套用。寬螢幕平板以左側播放器／選集、右側作品資訊排列。
- App 切到背景會暫停並保留播放器，回到前景同步原生位置、恢復先前播放狀態，不因生命週期切換主動重建或跳轉。
