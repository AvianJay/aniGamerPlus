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

1. 在 Discord 語音頻道啟動這個 Activity，允許 Discord 的身分授權。
2. 可以在 Activity 的帳號區輸入網站帳號及密碼；不用離開 Activity 登入。若網站要求登入，未登入的觀眾也可以先加入等候，請主辦人授權觀看。
3. 選擇綁定目前 Discord 身分後，之後以相同 Discord 帳號加入即可使用該網站帳號。每個 Discord 身分只能綁定一個網站帳號；帳號區也可解除綁定。
4. 第一位符合觀看與主控資格的人選擇影片並控制播放。啟用「必須登入才能觀看」時，未登入的等候者不會取得主控權；第一位登入網站帳號的人可以擔任主辦人。
5. 已登入網站帳號的主辦人選片後，可以在成員清單逐一「授權觀看本集」，也可以撤銷授權。訪客取得授權後會自動進入目前影片，不需要登入網站帳號。
6. 主辦人離開或連續約 20 秒沒有回報連線狀態後，由仍在線上、最早加入且有主控資格的人接手。訪客授權只提供觀看權，不會讓訪客取得主控或轉授權的資格。

沒有開啟「必須登入才能觀看」時，通過 Discord 驗證的訪客可以加入，原本第一位加入者主控的規則不變，訪客也可以擔任主控；簽發訪客授權則仍須主控方登入網站帳號。綁定網站帳號仍是可選操作。網站帳號被刪除或登入憑證失效後，Activity 必須重新登入。解除綁定後，該 Discord 身分不再能自動登入網站帳號。

### 訪客授權與影片 token

每張訪客 token 都只對授權當下的影片、Activity 房間、Discord 觀眾及其已加入的工作階段有效。伺服器會在影片、HLS 播放清單、解密金鑰與每個分片請求上重新核對；更改影片編號、轉貼給其他人或帶到其他房間都不能使用。訪客看不到完整片庫，也不能修改網站觀看紀錄或使用主辦人的帳號權限。

主辦人換片（包括重新選擇同一集）、撤銷授權、離開、主控接棒，或主辦人的網站登入／綁定失效時，舊 token 即失效。訪客離開、連線逾時或不再是 Discord 房間成員也會失效。重新加入、換集後都需要重新授權；再次授權會換發 token。授權最長兩小時，且不會超過主辦人的 Discord 工作階段期限。

瀏覽器若阻擋自動播放，先在播放器按一次播放。這是各自裝置的播放許可；觀眾仍會跟隨主控方的房間狀態。

## 部署與測試範圍

- 房間、線上狀態及短期 Activity 工作階段保存在單一 Dashboard 程序記憶體。請以單一 worker 執行；多台副本或多 worker 尚未共用房間狀態。重新啟動後，使用者需重新加入並重新驗證 Discord，帳號綁定仍會保留。工作階段最長 6 小時，若 Discord 授權提早到期則以該期限為準。
- 同步透過伺服器房間狀態進行，個別影片緩衝或網路延遲可能造成短暫差距，播放器會校正進度。這不是螢幕分享，每個人都向 Dashboard 取得自己的影音串流。
- Activity 使用自己的 `HttpOnly`、`Secure`、`SameSite=None`、`Partitioned` cookie。經 Discord Proxy 取得的工作階段與一般網站登入分開；若用瀏覽器直接開啟本機 HTTP 網址，不能取代 Discord 內的完整測試。[官方 Cookie 與網路說明](https://github.com/discord/discord-api-docs/blob/main/developers/activities/development-guides/networking.mdx)
- 自動測試使用模擬 Discord 回覆檢查登入限制、綁定、房間成員、主控權限與訪客 token 的影片限制及撤銷。實際 OAuth、Discord Proxy、語音頻道啟動、影音傳輸和雙人同步仍需用你自己的 Application 與兩個 Discord 帳號完成驗收。

建議實際驗收：兩個 Discord 帳號加入同一 Activity，只讓主辦人登入網站；確認訪客授權前無法播放，授權後可觀看該集但不能換片或跳轉；手動更改影片 URL 的編號確認被拒絕；主辦人撤銷、換片或離開後確認舊 token 不能繼續取得影音；另以兩位已登入的使用者測試主控接棒，以及綁定／解除綁定後的重新登入。

## 維護前端 SDK

已附上 Discord Embedded App SDK 2.5.0 的本機打包檔與授權，正常啟動 Dashboard 不需要 Node.js 或外部 CDN。更新 SDK 時，在 `tools/discord-sdk` 調整版本後執行 `npm install` 與 `npm run build`，並一併提交依賴鎖定檔和 `Dashboard/static/js/vendor` 的輸出。
