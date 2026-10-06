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
| — | **匯出影片檔** —— 把下載好的集數存到 App 外面 |
| — | **App 偏好設定** —— 這支手機自己的播放/下載/外觀偏好 |
| — | **投放** —— Chromecast (Android / iOS) 與 AirPlay (iOS), 見下面「投放」 |

「伺服器設定」改的是伺服器上的 `config.json`; 「App 偏好設定」只存在這支手機的
`shared_preferences` 裡, 兩者互不影響.

播放器支援 iOS / Android 子母畫面：播放中回到桌面或切到別的 App 會自動縮成小視窗
（設定裡可關，也可以從播放器選單手動開）；Android 的小視窗裡有倒退 / 播放 / 快轉
10 秒，iOS 用系統自己的按鈕。片頭跳過會由手機直接查 Bangumi、AniList、
AniSkip；查不到時依設定使用彈幕建議。

### Discord 播放動態

入口在「我的 → App 偏好設定 → Discord 播放動態」，預設關閉。
手機在 Discord WebView 登入後，播放時由裝置連線，顯示作品、集數、進度與暫停狀態。
封面取得失敗不影響播放；離開播放器會清除動態，連看下一集可沿用連線。
實作參考 [Kizzy](https://github.com/dead8309/Kizzy)，使用自行登入的 Discord 帳號連線；
這是非官方帳號整合，可能受到 Discord 的帳號或介面限制。

有登入 aniGamerPlus 伺服器帳號時，可輸入該帳號的密碼加密同步。
加密在用戶端完成（PBKDF2-SHA256、600,000 次、AES-256-GCM），
伺服器的 `/user/discord` 只保存密文；每個帳號只能讀寫自己的資料。
換裝置時可在設定頁解鎖，也會在輸入伺服器密碼登入時嘗試還原。
裝置上的 Discord 登入保存在系統安全儲存區，伺服器密碼不會被保存。
改密碼或管理員重設密碼會清除舊密文，之後需重新同步。

Android TV 使用手機登入：先在手機連上電視遙控器，再到 Discord 設定選「傳送到電視」。
傳送使用每條配對連線的臨時 X25519 金鑰與 AES-GCM 加密，並拒絕密文重播。
雙方均需使用更新後的 App；不會透過遙控通道傳送明文 Discord 憑證。
未開啟伺服器帳號功能時，仍可在手機使用動態與傳送到電視，但不提供伺服器同步。

### 離線下載怎麼運作

長按片庫卡片或在作品資訊裡選「下載到手機」, 就會排進佇列:

* 每一集是一支對 `/get_video.mp4` 的 Range 請求, 邊下邊寫 `.part`;
  暫停就是把連線切掉, 續傳靠 `.part` 的長度接回去.
* 勾了「一起抓彈幕」的話同時抓一份 `.ass`, 離線播放才有彈幕.
* 下載完的集數, 首頁跟播放頁會自動改讀本機檔 —— 連不到伺服器時照樣點得開.
* 檔案放在 App 自己的沙盒裡 (`path_provider` 的 documents), 移除 App 就一起消失.
* iOS 把整支檔案交給系統的背景 URLSession (`NativeTransfer`), 抓完才叫醒 App 收尾.
  若這個安裝收不到系統交付的暫存檔 (sideload 用共用/萬用憑證重簽時拿不到
  sandbox extension, 會出現 NSCocoaErrorDomain 513), 會自動改用前景 session
  重抓一次, 並記住之後都走前景, 不會再跳錯誤.

### 匯出影片檔

沙盒裡的檔名是 `<sn>-1080p.mp4`, 別的播放器找不到, 移除 App 也會一起不見.
想留下來的集數可以匯出:

* 「離線下載」每一集右邊的匯出鈕、作品資訊長按已下載的集數, 或右上角一次挑好幾集.
* 檔名照伺服器的預設命名: `作品名[集數][1080P].mp4`. 勾「附上彈幕字幕檔」會多一份
  同名的 `.ass`, VLC、mpv 這類播放器會自己當字幕載入.
* 存到哪裡交給系統選 (`packages/file_export`), 所以不必要任何儲存空間權限:
  * Android: 一個檔案開「建立文件」, 可以順便改名; 好幾個檔案請你選一個資料夾.
    Android 11 起不能直接選「Download」本身, 在裡面新增一個資料夾就好.
    複製在背景跑, 會顯示進度, 中途可以取消 (寫到一半的那個檔案會刪掉).
  * iOS: 開「檔案」App 的匯出面板, 存到手機、iCloud 雲碟或其他位置都可以.

### Android TV

同一個 APK 裝到 Android TV / Google TV 上就是電視版 (manifest 宣告了
`LEANBACK_LAUNCHER` 跟桌面橫幅, 觸控標成非必要). 開 App 時問一次系統
(`lib/src/util/device.dart`), 是電視的話:

* 分頁移到左邊 (NavigationRail), 卡片、按鈕被選到時有明顯的框.
* 播放器一進來就全螢幕. 遙控器:
  * 控制列收著時: 左右 = 倒退 / 快進 10 秒 (按住連續跳), OK = 暫停 / 播放,
    上下 = 叫出控制列 (焦點從播放鍵開始, 之後方向鍵在按鈕間移動).
  * 畫面上出現「跳過片頭」、「即將播放下一集」、錯誤的「重試」時, 按 OK 就是那一個.
  * 返回鍵: 播放中先收控制列 / 取消下一集倒數, 再按一次才離開.
  * 遙控器上的播放/暫停、快轉、倒轉、上一首/下一首 (= 上一集/下一集) 鍵不管焦點在哪都有效.

電視會自動使用較低負載的彈幕設定 (`DanmakuOverlay.lowPower`):

Android TV 播放器固定使用 Texture, 不受手機預設開啟的 PiP 設定影響.
Android 9 的 PlatformView hybrid composition 會把每一幀 Flutter 畫面從 GPU
複製到主記憶體再送回 GPU, 即使只有一條移動中的彈幕也可能卡頓. 電視不使用 PiP,
因此不需要這個原生檢視合成路徑; 手機的 PiP 播放器照舊.
電視彈幕以計時器最多每秒要求 30 幀, 不使用一直要求 vsync 的 ticker.
限幀只作用於彈幕, 不更動影片解碼幀率; 彈幕位置仍跟隨播放器時鐘與倍速.
只有固定彈幕時, 電視會休眠到下一條出場或過期, 不持續要求引擎合成影片.

| 彈幕資源 | 一般裝置 | Android TV |
| --- | --- | --- |
| 同時顯示上限 | 160 條 | 48 條 |
| 每幀最多建立貼圖 | 4 張 | 2 張 |
| 活躍貼圖 RGBA 估算預算 | 32 MiB | 8 MiB |
| 貼圖像素比 | 裝置像素比 | 最多 1.5 |
| 文字陰影 | 模糊陰影 | 無模糊陰影 |

同樣文字與顏色的彈幕共用貼圖, 最後一條離場就釋放. 密集留言分幀處理,
超過顯示量、記憶體預算或落後超過 1.5 秒的留言會略過; 超長文字用省略號限制在
2048 像素寬的貼圖內. 只有置頂／置底彈幕時, 時鐘前進不會讓彈幕層重畫.
這些預算讓低階電視保留影片播放所需的資源, 代價是高密度時顯示較少留言,
高 DPI 電視的字緣也會稍柔和.

`flutter test test/danmaku_overlay_test.dart test/watch_page_test.dart` 驗證分幀預算、
共用貼圖回收、跳轉、暫停與電視模式接線. 實機效能需用 `flutter run --profile`
播放相同影片的密集彈幕片段, 在 DevTools Performance 比較 UI／raster frame time
與超時幀; widget test 的軟體繪製時間不能代表 Android TV GPU 效能.
量測方式參考 [Flutter performance profiling](https://docs.flutter.dev/perf/ui-performance).

#### 掃碼設定

用遙控器敲網址跟密碼太痛苦, 所以電視上的「伺服器位址」跟「登入」頁右邊會有一個 QR 碼:

1. 電視在區網上開一台小伺服器 (`lib/src/state/remote_setup.dart`), QR 碼就是它的網址,
   路徑帶一段隨機字串.
2. 手機 (跟電視同一個網路) 用相機掃, 瀏覽器打開一頁表單, 填伺服器位址, 有開帳號系統的話
   順便填帳號密碼. 手機上不需要裝這個 App.
3. 送出後由電視自己去連線、登入驗證; 失敗的原因會顯示在手機上, 改了再送就好.
   成功之後那台小伺服器就收掉, 離開設定頁也會收掉.

跟 App 連自架伺服器一樣是區網 http, 密碼在區網上是明文傳的.

#### 手機遙控 (手機 App ↔ 電視 App)

手機上「我的 → 遙控電視」, 電視上「我的 → 手機遙控」(預設開著).

* **找電視**: 同時走兩條路 —— UDP 廣播 (埠 47810) 跟把同一個 /24 網段逐台敲一遍
  `http://<ip>:47811/remote/info`. iOS 沒有 Apple 另外核發的權限送不出廣播, 靠的是後面那一條.
  都找不到的話可以手動輸入電視上「手機遙控」頁顯示的位址.
* **配對**: 第一次連線電視上會跳出四位數配對碼, 在手機上輸入; 之後憑配對時拿到的 token 直接連.
  配對碼錯三次就斷線, 而且半分鐘內不接受新的配對. 電視上可以把手機移出清單.
  瀏覽器發的連線 (帶 `Origin` 的) 一律擋掉.
* **能做的事**:
  * 方向鍵 / OK / 返回 / 首頁 / 播放暫停, 按住連發. 走的是跟實體遙控器同一條按鍵路徑
    (`lib/src/util/remote_keys.dart`), 所以播放頁的左右跳轉、選單, 通通不必另外接.
  * 打字: 電視上有輸入框在等就填進去, 沒有就直接開搜尋.
  * 電視在播的時候手機上看得到片名跟進度條, 拖了就跳.
  * **把設定傳給電視**: 電視沒設伺服器 (或跟手機不一樣) 時, 一鍵把手機的伺服器位址連同登入狀態交過去 ——
    電視上不必打任何字.
  * **在電視上播放**: 手機播放頁的選單 (全螢幕時是右上角那顆) 把這一集連同看到的那一秒丟到電視上接著播.
* 協定在 `lib/src/state/tv_remote_protocol.dart` 開頭. 一樣是區網上的明文 WebSocket.

電視上的其他優化: 焦點框從第一下按鍵就畫、方向鍵移到的那一格自動捲到畫面中間、
開 App 時焦點先停在左邊分頁列.

## 本機開發

平台目錄 (`android/`, `ios/`) 不進版控 —— 那些是 `flutter create` 的樣板, 留在
repo 裡只會變成沒人維護的死碼. 第一次要先產生一次:

```bash
cd flutter_app
bash tool/prepare_platforms.sh
```

這支會 `flutter create` 一份樣板搬進來, 然後補上這個 App 需要的東西:

* `AndroidManifest.xml`: `INTERNET` 權限、`usesCleartextTraffic`
  (自架伺服器多半是區網 http)、url_launcher 要的 `<queries>`、
  Android TV 的 `LEANBACK_LAUNCHER` 與橫幅 (圖在 `android_extensions/res/`).
* `MainActivity.kt`: `agp/device` 通道 —— 這台是不是電視、裝置名稱 (配對時顯示),
  以及電視等手機廣播時要拿的 Wi-Fi MulticastLock (`CHANGE_WIFI_MULTICAST_STATE`).
* `Info.plist`: ATS 例外、區網存取說明、背景播放聲音、橫向.

然後就是一般的 Flutter 流程:

```bash
flutter run
flutter build apk --release
flutter build appbundle --release --dart-define=APP_UPDATER=false
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
* `android` —— APK + AAB, 用 repository secrets 裡的 release 金鑰簽 (PR 沒有 secrets 時退回 debug 金鑰)。AAB 以 `APP_UPDATER=false` 編譯，不含 App 內更新入口、啟動時檢查、APK 安裝權限與更新用的 FileProvider
* `ios` —— 未簽名的 IPA, 要靠 sideloader 自己簽
* `nightly` —— master 每次推送, 把 APK / AAB / IPA 以固定檔名換進 `nightly` prerelease

都會上傳成 artifact, 發 release 的時候 APK 跟 IPA 會自動附上去.
`Python-build.yml` 也會把伺服器執行檔放進同一個 `nightly` release.

這個 fork (`nka551774-hue/aniGamerPlus`) 自己發 nightly: 未簽名 IPA 在
`releases/download/nightly/aniGamerPlus-nightly-unsigned.ipa`, App 內更新
(`lib/src/state/updater.dart` 的 `kUpdateRepo`) 也指回這一份, 免得一直提示
要裝回上游那一版.

### App 內更新

APK / IPA 提供 App 內更新。AAB 建置時傳入 `--dart-define=APP_UPDATER=false`，
更新功能會在編譯時移除，Android manifest 也會移除 `REQUEST_INSTALL_PACKAGES`
及更新用的 FileProvider；AAB 安裝後的更新交由發佈商店處理。

「我的 → 檢查更新」, 開 App 時也會自己看一次 (「App 偏好設定 → 更新」可關).

* 通道: 正式版 (`releases/latest`) 或 Nightly (`releases/download/nightly/flutter-nightly.json`), 比的是 build number (= CI run number)
* Android: 下載 APK 後交給系統安裝器. 要跟手上那一版同一把金鑰簽才蓋得過去, debug 版裝不了 release 版的更新
* iOS: 自動偵測 TrollStore / SideStore / AltStore / LCSign；LCSign 用 `loadcontroller://import?url=` 匯入 IPA，需在 LCSign 完成簽名與安裝；都沒有就用瀏覽器下載


### 投放 (Chromecast / AirPlay)

播放器上方 (直式時在影片下方那一列) 的兩顆鍵:

* **Chromecast** (Android / iOS): 同一個 Wi-Fi 上找得到 Chromecast 或內建
  Chromecast 的電視時才會出現. 連上之後這一集從手機上的位置交給電視, 手機這邊
  變成遙控器 —— 播放鍵、時間軸、倍速、換集、自動下一集都是在叫電視, 觀看進度
  照樣記. 離開播放頁不會斷, 回到同一集直接接手; 停止投放就在手機上從電視停下
  的地方暫停著接回來. 用的是 Google 的預設媒體接收器, 不必另外註冊.
  投放中手機鎖屏或切到別的 App 也照常運作: 電視播完直接接下一集 (背景裡不等
  8 秒倒數)、進度照記、邊看邊下載照樣等第一片. iOS 會把背景裡沒在出聲的 App
  暫停, 所以這段時間播一段跟別的 App 混音的靜音撐著 (`packages/cast_keepalive`);
  連線暫時掉了 (例如 App 被系統暫停過) 先等 8 秒看會不會接回來, 不會馬上切回
  手機、也不會把電視上那一集重新載入.
* **AirPlay** (iOS): 系統自己的按鈕. 選了 Apple TV 之後影片由 iOS 送過去, 控制
  照舊在手機上.

電視那一頭拿不到 App 的登入 cookie, 也連不到手機上的本機快取, 所以投放前 App
會先跟伺服器換一張**投放票** (`/cast/ticket`), 寫在影片網址上 (`?ct=...`):

* 只認那一集, 12 小時後過期; 用帳號自己的 token 簽, 帳號刪掉或 token 換掉就一起
  作廢. 票本身不含 token.
* `/get_video.mp4`、`/hls/*`、`/stream/*` 都認這張票. HLS 清單裡的分片與金鑰
  網址會帶著同一張票, 而且只有帶票的請求會拿到 CORS 標頭 (Chromecast 的接收器
  用 XHR 抓 HLS).
* 伺服器的位址要是電視連得到的 (區網 IP 或網域, 不能是 `localhost`). 舊版伺服器
  沒有這條路由的話, 片庫不必登入時照樣投得出去 (HLS 可能缺 CORS); 要登入就投不了.

限制: 彈幕不會出現在電視上 (預設接收器畫不了 ASS); 只下載在手機裡、伺服器片庫
沒有的集數投不出去; 邊看邊下載的集數要等伺服器有第一片才會交給電視.

平台設定都在 `tool/prepare_platforms.sh`: Android 的 `CastOptionsProvider`
(App 自己的, 不用外掛那個要等 Dart 初始化的版本)、媒體通知的前景服務; iOS 的
`NSBonjourServices`. AirPlay 按鈕是 `packages/airplay_route` (AVRoutePickerView).

iOS 為了繼續支援 iOS 15, Google Cast SDK 釘在 4.8.4 (4.8.6 起最低要 iOS 16):
`pubspec.yaml` 關掉了 Swift Package Manager, 改走 CocoaPods, 由
`prepare_platforms.sh` 在 Podfile 裡釘版本. Flutter 之後會不再允許關掉 SPM,
到時候只能把最低版本拉到 iOS 16.

### 播放器操作與快取

- 右上角可直接選擇 0.25–2 倍速與片源提供的畫質；右下角為倒退／快進 10 秒及播放鍵。
- 左半邊上下滑調整影片亮度，右半邊上下滑調整播放音量，控制列顯示時也能使用。亮度調整作用於影片畫面。
- 拖曳到尚未緩衝的位置時，進度停留在目標並等待原生播放器確認；連續拖曳以最後一次為準。邊下載邊播放會等待伺服器產生目標片段。
- 海報與縮圖共用磁碟快取，重新開啟 App 可重用；過期後依伺服器快取標頭更新。不同伺服器／登入憑證的快取分開。
- `flutter test` 覆蓋延遲跳轉、連續拖曳、手勢、窄螢幕與橫向佈局，GitHub Actions 會在 Android／iOS 建置前執行。

- 中央三分之一區域雙擊播放／暫停，左右兩側雙擊倒退／快進 10 秒。長按的「2x 倍速中」提示持續到放開，離開 App 時會取消長按倍速。
- 底部按鈕使用至少 52×52 的觸控區域；畫面拉伸只在全螢幕顯示與套用。寬螢幕平板以左側播放器／選集、右側作品資訊排列。
- App 切到背景會暫停並保留播放器，回到前景同步原生位置、恢復先前播放狀態，不因生命週期切換主動重建或跳轉。自動子母畫面開著的時候先等它開起來，沒開起來才暫停；投放中則不暫停任何東西，這一頁繼續跟著電視走。

### 觀看進度與「繼續觀看」

進度有兩份，寫下來的節奏刻意不同：

- **本機那份**每 3 秒記一次。首頁的「繼續觀看」、觀看紀錄、所有動畫的卡片、作品資訊的
  「看到第幾集」讀的都是它。
- **伺服器那份**每 10 秒送一次（`/watch/time`）。暫停、跳轉、播完、切到背景、離開播放頁
  都會立刻補一筆，所以看幾秒就退出去也留得住。
- 換集會把這兩個節奏歸零，新的一集從第一秒就開始記，不會被上一集的時間窗吃掉開頭。

「繼續觀看」與作品資訊都認得**片庫裡沒有的集數**：播放頁一拿到官方集數表，就把整份
`sn → 作品名／集數／封面` 寫進一份共用的名稱表（`history-names`），所以線上看過、還沒
下載的作品也會出現，點下去是開作品資訊（那裡才有「邊看邊下載」），而不是一個播不出來
的播放頁。這份表在紀錄頁與作品資訊兩邊共用，也會落盤。
