# Discord 語音頻道一起看

Discord Activity 使用現有 Dashboard 的影片與播放器。大家在同一個 Activity 中觀看同一集，主辦人可以選片、播放、暫停、跳轉及調整播放速度，也可以逐一授權同房的訪客觀看目前這一集。音量、靜音、字幕與畫質由各自調整。

這個功能需要你自己的 Discord Application，以及 Discord 能連線的 Dashboard HTTPS 網址。本機程式碼安裝完成後，仍須完成下列 Discord 設定。

## 1. 準備 Dashboard

- 開啟 `dashboard.online_watch`。
- 若要登入網站帳號或綁定 Discord，開啟 `dashboard.user_control.enabled`。
- 若平常觀看需要網站帳號，開啟 `dashboard.online_watch_requires_login`，並同時開啟帳號系統。觀眾可以登入自己的網站帳號、使用已綁定的 Discord 身分，或由已登入的主辦人授權觀看目前這一集；未經授權的訪客只會進入等候區。
- 將 Dashboard 提供於公開 HTTPS 網址，或使用 HTTPS 開發通道轉送到本機。例如 Dashboard 在 5000 埠時，可使用 `cloudflared tunnel --url http://localhost:5000`。正式部署使用固定網域。

網址需能傳輸影片及 HTTP Range 請求。反向代理不要移除 `Range`、`Content-Range`、`Set-Cookie`，也不要快取登入及 Activity 房間 API。Activity 需要允許 Discord 嵌入，請勿額外加上會封鎖 Discord 的 `X-Frame-Options: DENY` 或 `frame-ancestors 'none'`。

Discord 官方建議透過實際 Activity Proxy 測試，確認路徑與正式環境一致；臨時通道關閉後應移除對應的 URL Mapping。[本機開發說明](https://github.com/discord/discord-api-docs/blob/main/developers/activities/development-guides/local-development.mdx)

## 2. 建立 Discord Application

在 [Discord Developer Portal](https://discord.com/developers/applications) 建立一個 Application：

1. 在 General Information 取得 Application ID，這也是 OAuth Client ID。
2. 在 OAuth2 取得 Client Secret。
3. 在 OAuth2 → Redirects 至少新增一個 Redirect URI。Activity 使用 SDK 內的授權流程，依官方教學可填 `https://127.0.0.1`；SDK 會將授權結果交回 Activity，不需要另外建立網站回呼頁。
4. 在 Bot 建立或取得這個 Application 的 Bot Token。Bot Token 用來查驗目前 Activity 的成員；不需要為同步播放啟動另一個機器人程序。
5. 在 Activities → Settings 開啟 **Enable Activities**，並勾選要支援的平台。
6. 在 Activities → URL Mappings 設定以下根路徑對應。

| PREFIX | TARGET |
| --- | --- |
| `/` | `你的-dashboard-網域` |

TARGET 只填主機名稱，不含 `https://`。例如 `anime.example.com`；使用臨時通道時填通道分配的主機名稱。此對應需涵蓋首頁、`/discord/activity`、`/static`、觀看 API 和影片路徑，請不要只把根路徑對應到 Activity 子目錄。

Discord 會在開啟 Activity 時傳入自己的實例參數；保留這些參數，讓同一頻道的參與者進入同一房間。Activity 入口頁為 `/discord/activity`，從 Discord 根路徑啟動時也會直接顯示相同介面，保留原本的 SDK 啟動網址。

開啟 Activities 後 Discord 會建立預設 Launch 入口指令。由開發者／測試者先在語音頻道的 App Launcher 啟動測試，再讓其他人加入同一個 Activity。[官方建立教學](https://github.com/discord/discord-api-docs/blob/main/developers/activities/building-an-activity.mdx)

開發中的 Application 先由擁有者或開發團隊成員測試，並在 Discord 使用者設定開啟 Developer Mode。未公開發行的 Activity 不保證所有伺服器成員都能看見；雙人測試時也要讓第二個帳號具有測試存取權。

## 3. 設定 config.json

在 `config.json` 的 `dashboard` 底下填入 `discord_activity`，然後重新啟動 Dashboard：

```json
"discord_activity": {
    "client_id": "你的 Application ID",
    "client_secret": "你的 OAuth2 Client Secret",
    "bot_token": "你的 Bot Token"
}
```

| 欄位 | 內容 | 可否公開 |
| --- | --- | --- |
| `dashboard.discord_activity.client_id` | 上述 Application ID | 可以 |
| `dashboard.discord_activity.client_secret` | 同一個 Application 的 OAuth2 Client Secret | 保密 |
| `dashboard.discord_activity.bot_token` | 同一個 Application 的 Bot Token | 保密 |

這三個欄位只從 `config.json` 讀取，不使用環境變數。舊版設定升級時會自動補上空白欄位；範例見 `config-sample.json`。Docker 沿用既有的 `config.json` 掛載，不需要另外傳入環境變數。Client Secret 與 Bot Token 只供伺服器使用，不會回傳到 Activity 前端；請勿將填有憑證的設定檔放進版本庫或分享。

OAuth 授權碼由伺服器交換並向 Discord 查驗使用者。Bot Token 查詢實際 Activity Instance 的成員名單，避免只憑網址上的房間 ID 就加入房間。[Discord 多人與實例驗證說明](https://github.com/discord/discord-api-docs/blob/main/developers/activities/development-guides/multiplayer-experience.mdx)

## 4. 登入、綁定與觀看

1. 在 Discord 語音頻道啟動這個 Activity。首次 OAuth 授權會一併要求身分與播放動態權限（`rpc.activities.write`）。若不授予播放動態權限，仍可透過基本身分授權加入房間。
2. 可以在 Activity 右上角的帳號入口輸入網站帳號及密碼；不用離開 Activity 登入。若網站要求登入，未登入的觀眾也可以先加入等候，請主辦人授權觀看。
3. 登入時預設勾選「綁定目前的 Discord 帳號」，登入成功就會同時綁定，之後以相同 Discord 帳號開啟 Activity 會自動登入。取消勾選則只登入這一次，之後仍可在帳號區手動綁定。每個 Discord 身分只能綁定一個網站帳號；若已綁定其他帳號，會照常登入並顯示未能綁定的原因。帳號區也可解除綁定。
4. 第一位符合觀看與主控資格的人選擇影片並控制播放。啟用「必須登入才能觀看」時，未登入的等候者不會取得主控權；第一位登入網站帳號的人可以擔任主辦人。
5. 已登入網站帳號的主辦人選片後，可以在成員清單逐一「授權觀看本集」，也可以撤銷授權。訪客取得授權後會自動進入目前影片，不需要登入網站帳號。
6. 主辦人離開或連續約 20 秒沒有回報連線狀態後，由仍在線上、最早加入且有主控資格的人接手。訪客授權只提供觀看權，不會讓訪客取得主控或轉授權的資格。

### 自動授權訪客

已登入網站帳號的主辦人可以開啟成員清單上的「自動授權訪客」。開啟後，現有與之後加入的訪客會自動取得目前影片的觀看授權；換片時會為新影片換發 token，舊影片的 token 仍會立即失效。

開關預設關閉，只對目前主辦人的這個房間有效。關閉時會撤銷自動簽發的授權，手動授權仍保留；開啟期間若對某位訪客手動撤銷，該觀眾在目前這集不會被自動重新授權，換片後才重新套用。主辦人離開、接棒、登出或登入憑證失效時，自動授權也會關閉。

### 播放器鋪滿畫面

Activity 內的放大按鈕會將播放器鋪滿 Discord 活動區域，保留同一個播放器與播放進度。可按播放器的縮小按鈕、右上角的離開按鈕或 `Esc` 返回片單；一般網站播放器仍保留原本的全螢幕行為。

手機把活動縮成小視窗或方形預覽時，會自動收起標頭與片單，只顯示影片及精簡控制列，避免整個網頁被縮在方塊裡。放大回活動頁後恢復完整介面，切換過程不會重載影片或重設進度；尚未取得觀看授權的訪客仍只會看到等候訊息。

手機版會避開 Discord 提供的安全邊界，讓右上角帳號入口與登入表單不被 Discord 的控制列蓋住。等候畫面中央也有「登入網站帳號」入口；鍵盤開啟時表單仍可捲動，不會被切成小視窗播放器版面。[Discord 手機安全邊界說明](https://github.com/discord/discord-api-docs/blob/main/developers/activities/development-guides/mobile.mdx#mobile-safe-areas)

### Discord 播放動態

「顯示播放動態」預設開啟。Discord 授權成功後，開始觀看就會顯示作品名稱、集數、播放時間及可取得的封面；暫停時會標示「已暫停」。如果 Discord 沒有授予播放動態權限，開關會保持關閉；按一下即可重新要求權限，不會重設房間或訪客授權。

停止觀看、失去觀看授權或手動關閉頂端的「顯示播放動態」時，會清除自訂動態。手動關閉後，同一個用戶端會記住選擇，下次啟動只要求基本權限。若用戶端封鎖本機儲存，這個選擇只保留到離開頁面為止。

Discord 顯示的應用程式名稱由 Developer Portal 的 Application 名稱決定，請將它設為想顯示的 `aniGamerPlus` 名稱；內容模板與 Flutter 相同。[Discord Activity 播放動態說明](https://github.com/discord/discord-api-docs/blob/main/developers/rich-presence/using-with-the-embedded-app-sdk.mdx)

沒有開啟「必須登入才能觀看」時，通過 Discord 驗證的訪客可以加入，原本第一位加入者主控的規則不變，訪客也可以擔任主控；簽發訪客授權則仍須主控方登入網站帳號。綁定網站帳號仍是可選操作。網站帳號被刪除或登入憑證失效後，Activity 必須重新登入。解除綁定後，該 Discord 身分不再能自動登入網站帳號。

### 訪客授權與影片 token

每張訪客 token 都只對授權當下的影片、Activity 房間、Discord 觀眾及其已加入的工作階段有效。伺服器會在影片、HLS 播放清單、解密金鑰與每個分片請求上重新核對；更改影片編號、轉貼給其他人或帶到其他房間都不能使用。訪客看不到完整片庫，也不能修改網站觀看紀錄或使用主辦人的帳號權限。

主辦人換片（包括重新選擇同一集）、撤銷授權、離開、主控接棒，或主辦人的網站登入／綁定失效時，舊 token 即失效。訪客離開、連線逾時或不再是 Discord 房間成員也會失效。重新加入、換集後都需要新的授權；若主辦人已開啟自動授權，則由伺服器重新簽發，否則需手動授權。授權最長兩小時，且不會超過主辦人的 Discord 工作階段期限。

瀏覽器若阻擋自動播放，先在播放器按一次播放。這是各自裝置的播放許可；觀眾仍會跟隨主控方的房間狀態。

影片來源載入失敗時，播放器會自動重載一次；仍然失敗時會停止自動重試，並在活動頁顯示原因。`NotSupportedError` 不一定代表缺少解碼器，影片請求被拒絕、檔案不存在或代理回傳 HTML 也可能導致來源無法播放；活動頁會另外檢查影片端點的 HTTP 狀態。若來源正常但只有特定用戶端無法解碼，可確認該用戶端的 Discord 版本及硬體加速設定。按播放可以重新嘗試，恢復播放後會清除錯誤並跟上房間進度。

## 部署與測試範圍

- 房間、線上狀態及短期 Activity 工作階段保存在單一 Dashboard 程序記憶體。請以單一 worker 執行；多台副本或多 worker 尚未共用房間狀態。重新啟動後，使用者需重新加入並重新驗證 Discord，帳號綁定仍會保留。工作階段最長 6 小時，若 Discord 授權提早到期則以該期限為準。
- 同步透過伺服器房間狀態進行，個別影片緩衝或網路延遲可能造成短暫差距，播放器會校正進度。這不是螢幕分享，每個人都向 Dashboard 取得自己的影音串流。
- Activity 使用自己的 `HttpOnly`、`Secure`、`SameSite=None`、`Partitioned` cookie。經 Discord Proxy 取得的工作階段與一般網站登入分開；若用瀏覽器直接開啟本機 HTTP 網址，不能取代 Discord 內的完整測試。[官方 Cookie 與網路說明](https://github.com/discord/discord-api-docs/blob/main/developers/activities/development-guides/networking.mdx)
- 自動測試使用模擬 Discord 回覆檢查登入限制、綁定、房間成員、主控權限與訪客 token 的影片限制及撤銷。實際 OAuth、Discord Proxy、語音頻道啟動、影音傳輸和雙人同步仍需用你自己的 Application 與兩個 Discord 帳號完成驗收。

建議實際驗收：兩個 Discord 帳號加入同一 Activity，只讓主辦人登入網站；確認訪客授權前無法播放，授權後可觀看該集但不能換片或跳轉；手動更改影片 URL 的編號確認被拒絕；主辦人撤銷、換片或離開後確認舊 token 不能繼續取得影音；另以兩位已登入的使用者測試主控接棒，以及綁定／解除綁定後的重新登入。

## 維護前端 SDK

已附上 Discord Embedded App SDK 2.5.0 的本機打包檔與授權，正常啟動 Dashboard 不需要 Node.js 或外部 CDN。更新 SDK 時，在 `tools/discord-sdk` 調整版本後執行 `npm install` 與 `npm run build`，並一併提交依賴鎖定檔和 `Dashboard/static/js/vendor` 的輸出。
