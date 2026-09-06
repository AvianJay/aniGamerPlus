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
